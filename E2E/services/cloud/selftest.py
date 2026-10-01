#!/usr/bin/env python3
"""Drives every endpoint the Hamasen cloud clients use against a running
cloud mock, printing PASS or FAIL for each check.

    python3 selftest.py http://127.0.0.1:8090

Exits 1 when any check fails. It resets the mock first, so never point it
at a mock a test run is using. Checks that wait for time to pass (access
token expiry, the end of a rotated refresh token's grace period) run only
when the mock's TOKEN_LIFETIME or ROTATION_GRACE is at most a few seconds,
and print SKIP otherwise.
"""

import hashlib
import http.client
import json
import os
import sys
import threading
import time
from urllib.parse import quote, unquote, urlencode, urlsplit

TOKEN_URLS = {
    "dropbox": "https://api.dropboxapi.com/oauth2/token",
    "microsoft": "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    "google": "https://oauth2.googleapis.com/token",
}
DROPBOX_BLOCK = 4 * 1024 * 1024
GRAPH_FRAGMENT = 320 * 1024
SHORT_WAIT_LIMIT = 5
failures = []


def check(name, condition, detail=""):
    print(f"{'PASS' if condition else 'FAIL'} {name}" + ("" if condition or detail == "" else f": {detail}"),
          flush=True)
    if not condition:
        failures.append(name)
    return condition


def skip(name, reason):
    print(f"SKIP {name}: {reason}", flush=True)


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        try:
            return json.loads(self.body)
        except ValueError:
            return None

    def field(self, *keys):
        """A nested value of the JSON body, or None."""
        value = self.json()
        for key in keys:
            if isinstance(value, dict):
                value = value.get(key)
            elif isinstance(value, list) and isinstance(key, int) and key < len(value):
                value = value[key]
            else:
                return None
        return value

    def header(self, name):
        return self.headers.get(name.lower())

    def __repr__(self):
        return f"HTTP {self.status} {self.body[:300]!r}"


class Mock:
    def __init__(self, base):
        parts = urlsplit(base)
        self.host, self.port = parts.hostname, parts.port or 80

    def send(self, method, target, headers=None, body=None, chunked=False):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=120)
        try:
            payload = iter(body) if chunked else body
            connection.request(method, target, body=payload, headers=headers or {}, encode_chunked=chunked)
            response = connection.getresponse()
            return Response(response.status, {k.lower(): v for k, v in response.getheaders()}, response.read())
        finally:
            connection.close()

    def call(self, method, url, headers=None, body=None, chunked=False):
        """Sends https://<host>/<path> the way the harness rewrites it."""
        parts = urlsplit(url)
        target = f"/{parts.netloc}{parts.path or '/'}" + (f"?{parts.query}" if parts.query else "")
        return self.send(method, target, headers, body, chunked)

    def admin(self, action, **body):
        if action == "stats":
            return self.send("GET", "/__admin/stats").json()
        response = self.send("POST", f"/__admin/{action}", {"Content-Type": "application/json"},
                             json.dumps(body).encode())
        if response.status != 200:
            raise RuntimeError(f"admin {action}: {response}")
        return response.json()


def refresh(mock, provider, token):
    form = urlencode({"grant_type": "refresh_token", "refresh_token": token, "client_id": "hamasen-e2e"})
    return mock.call("POST", TOKEN_URLS[provider],
                     {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
                     form.encode())


class Account:
    """One provider's token pair, renewed once on a 401 as CloudHTTPClient does."""

    def __init__(self, mock, provider):
        self.mock = mock
        self.provider = provider
        pair = mock.admin("token", provider=provider)
        self.access, self.refresh = pair["access_token"], pair["refresh_token"]

    def call(self, method, url, headers=None, body=None, chunked=False):
        for attempt in (1, 2):
            sent = dict(headers or {})
            sent["Authorization"] = f"Bearer {self.access}"
            response = self.mock.call(method, url, sent, body, chunked)
            if response.status != 401 or attempt == 2:
                return response
            renewed = refresh(self.mock, self.provider, self.refresh).json()
            self.access = renewed["access_token"]
            self.refresh = renewed.get("refresh_token", self.refresh)


def dropbox_hash(data):
    blocks = [hashlib.sha256(data[i:i + DROPBOX_BLOCK]).digest() for i in range(0, len(data), DROPBOX_BLOCK)]
    return hashlib.sha256(b"".join(blocks)).hexdigest()


# MARK: - Dropbox

def test_dropbox(mock):
    account = Account(mock, "dropbox")

    def rpc(route, args):
        return account.call("POST", f"https://api.dropboxapi.com/2/{route}",
                            {"Content-Type": "application/json"}, json.dumps(args).encode())

    def content(route, args, data=b"", chunked=False):
        headers = {"Content-Type": "application/octet-stream", "Dropbox-API-Arg": json.dumps(args)}
        if chunked:
            headers["Transfer-Encoding"] = "chunked"
        return account.call("POST", f"https://content.dropboxapi.com/2/{route}", headers, data, chunked)

    def upload(path, data, mode="overwrite"):
        return content("files/upload", {"path": path, "mode": mode, "autorename": False, "mute": True}, data)

    def download(path, byte_range=None):
        headers = {"Dropbox-API-Arg": json.dumps({"path": path})}
        if byte_range:
            headers["Range"] = byte_range
        return account.call("POST", "https://content.dropboxapi.com/2/files/download", headers)

    r = rpc("users/get_current_account", None)
    check("dropbox: users/get_current_account answers with the email", r.status == 200 and r.field("email"), r)
    r = mock.call("POST", "https://api.dropboxapi.com/2/users/get_current_account",
                  {"Content-Type": "application/json"}, b"null")
    check("dropbox: no token is 401 invalid_access_token",
          r.status == 401 and r.field("error", ".tag") == "invalid_access_token", r)
    r = mock.call("POST", "https://api.dropboxapi.com/2/users/get_current_account",
                  {"Content-Type": "application/json", "Authorization": "Bearer nonsense"}, b"null")
    check("dropbox: an unknown token is 401", r.status == 401 and "error_summary" in (r.json() or {}), r)
    r = rpc("files/list_folder", {"path": "/"})
    check('dropbox: the root named "/" is a 400', r.status == 400, r)
    r = account.call("POST", "https://api.dropboxapi.com/2/files/list_folder",
                     {"Content-Type": "application/x-www-form-urlencoded"}, b'{"path": ""}')
    check("dropbox: an RPC with the wrong Content-Type is a 400", r.status == 400, r)

    r = rpc("files/create_folder_v2", {"path": "/E2E Test", "autorename": False})
    check("dropbox: create_folder_v2 creates", r.status == 200 and r.field("metadata", ".tag") == "folder", r)
    r = rpc("files/create_folder_v2", {"path": "/e2e test", "autorename": False})
    check("dropbox: create_folder_v2 on a taken name, any case, is 409 path/conflict/folder",
          r.status == 409 and str(r.field("error_summary")).startswith("path/conflict/folder/")
          and r.field("error", "path", "conflict", ".tag") == "folder", r)

    small = os.urandom(10_000)
    name = "/E2E Test/報告 😀.pdf"
    r = upload(name, small)
    check("dropbox: files/upload with an escaped Dropbox-API-Arg keeps the name",
          r.status == 200 and r.field("path_display") == name and r.field("size") == len(small), r)
    check("dropbox: content_hash is Dropbox's block hash", r.field("content_hash") == dropbox_hash(small), r)
    rev = r.field("rev")
    r = account.call("POST", "https://content.dropboxapi.com/2/files/upload",
                     {"Content-Type": "application/octet-stream",
                      "Dropbox-API-Arg": json.dumps({"path": "/E2E Test/報.txt"}, ensure_ascii=False).encode()},
                     b"x")
    check("dropbox: a non-ASCII Dropbox-API-Arg is a 400", r.status == 400, r)
    r = content("files/upload", {"path": "/E2E Test/y.txt"}, b"y")
    r2 = account.call("POST", "https://content.dropboxapi.com/2/files/upload",
                      {"Content-Type": "application/json", "Dropbox-API-Arg": json.dumps({"path": "/E2E Test/z"})}, b"z")
    check("dropbox: an upload must be application/octet-stream", r.status == 200 and r2.status == 400, r2)

    r = download(name)
    result = json.loads(r.header("Dropbox-API-Result") or "{}")
    check("dropbox: files/download returns the bytes and Dropbox-API-Result",
          r.status == 200 and r.body == small and result.get("path_display") == name, r)
    r = download(name, "bytes=100-149")
    check("dropbox: a range is a 206 with those bytes",
          r.status == 206 and r.body == small[100:150] and r.header("Content-Range") == "bytes 100-149/10000", r)
    r = download(name, "bytes=9990-10100")
    check("dropbox: a range past the end is cut at the end", r.status == 206 and r.body == small[9990:], r)
    r = download(name, "bytes=10000-10010")
    check("dropbox: a range starting past the end is 416", r.status == 416, r)
    r = download("/E2E Test")
    check("dropbox: downloading a folder is 409 path/not_file", r.status == 409 and "not_file" in str(r.field("error_summary")), r)

    r = rpc("files/get_metadata", {"path": "/e2e test/報告 😀.PDF"})
    check("dropbox: get_metadata ignores case and keeps the stored case",
          r.status == 200 and r.field("path_display") == name and r.field("rev") == rev, r)
    r = rpc("files/get_metadata", {"path": "/E2E Test/missing.txt"})
    check("dropbox: a missing item is 409 path/not_found",
          r.status == 409 and str(r.field("error_summary")).startswith("path/not_found/"), r)

    many = [f"file-{i}.txt" for i in range(5)]
    for item in many:
        upload(f"/E2E Test/many/{item}", item.encode())
    r = rpc("files/list_folder", {"path": "/E2E Test/many", "limit": 2, "include_deleted": False})
    pages, listed = 1, [e["name"] for e in r.field("entries") or []]
    while r.field("has_more"):
        r = rpc("files/list_folder/continue", {"cursor": r.field("cursor")})
        pages += 1
        listed += [e["name"] for e in r.field("entries") or []]
    check("dropbox: list_folder pages through list_folder/continue (and upload made the parent)",
          listed == many and pages == 3, f"{pages} pages, {listed}")
    r = rpc("files/list_folder/continue", {"cursor": "garbage"})
    check("dropbox: a malformed cursor is a 400", r.status == 400, r)
    r = rpc("files/list_folder", {"path": ""})
    check("dropbox: the root is listed as \"\"",
          r.status == 200 and [e["name"] for e in r.field("entries") or []] == ["E2E Test"], r)

    first, second, last = os.urandom(1 << 20), os.urandom(1 << 20), os.urandom(1000)
    r = content("files/upload_session/start", {"close": False}, first)
    session = r.field("session_id")
    check("dropbox: upload_session/start returns a session_id", r.status == 200 and session, r)
    r = content("files/upload_session/append_v2", {"cursor": {"session_id": session, "offset": 5}, "close": False}, second)
    check("dropbox: append_v2 at the wrong offset is 409 incorrect_offset with the correct one",
          r.status == 409 and r.field("error", "correct_offset") == len(first), r)
    r = content("files/upload_session/append_v2", {"cursor": {"session_id": session, "offset": len(first)}, "close": False},
                second)
    check("dropbox: append_v2 accepts the next chunk", r.status == 200 and r.body == b"null", r)
    commit = {"path": "/E2E Test/big.bin", "mode": "overwrite", "autorename": False, "mute": True}
    r = content("files/upload_session/finish",
                {"cursor": {"session_id": session, "offset": len(first) + len(second)}, "commit": commit}, last)
    whole = first + second + last
    check("dropbox: upload_session/finish commits every chunk",
          r.status == 200 and r.field("size") == len(whole) and r.field("content_hash") == dropbox_hash(whole), r)
    check("dropbox: the session's file downloads intact", download("/E2E Test/big.bin").body == whole)
    r = content("files/upload_session/finish",
                {"cursor": {"session_id": session, "offset": len(whole)}, "commit": commit}, b"")
    check("dropbox: a finished session is gone", r.status == 409 and "lookup_failed/not_found" in str(r.field("error_summary")), r)
    r = content("files/upload_session/start", {"close": False}, b"only chunk")
    r = content("files/upload_session/finish",
                {"cursor": {"session_id": r.field("session_id"), "offset": 10},
                 "commit": dict(commit, path="/E2E Test/one-chunk.bin")}, b"")
    check("dropbox: a one-chunk session is finished with an empty body", r.status == 200 and r.field("size") == 10, r)
    chunks = [os.urandom(70_000) for _ in range(3)]
    r = content("files/upload", {"path": "/E2E Test/chunked.bin", "mode": "overwrite"}, chunks, chunked=True)
    check("dropbox: a chunked request body is read whole",
          r.status == 200 and download("/E2E Test/chunked.bin").body == b"".join(chunks), r)

    r = upload(name, b"different", mode="add")
    check("dropbox: mode add onto a different file is 409 path/conflict/file",
          r.status == 409 and str(r.field("error_summary")).startswith("path/conflict/file/"), r)
    r = upload(name, small, mode="add")
    check("dropbox: mode add with identical content is no conflict and no new rev",
          r.status == 200 and r.field("rev") == rev, r)
    r = upload("/E2E Test", b"x")
    check("dropbox: an upload onto a folder is a conflict", r.status == 409 and "conflict" in str(r.field("error_summary")), r)

    upload("/E2E Test/moves/a.txt", b"a")
    upload("/E2E Test/moves/b.txt", b"b")
    r = rpc("files/move_v2", {"from_path": "/E2E Test/moves/a.txt", "to_path": "/E2E Test/moves/B.TXT",
                              "autorename": False, "allow_ownership_transfer": False})
    check("dropbox: move_v2 onto a taken name is 409 to/conflict/file",
          r.status == 409 and str(r.field("error_summary")).startswith("to/conflict/file/"), r)
    r = rpc("files/move_v2", {"from_path": "/E2E Test/moves/none.txt", "to_path": "/E2E Test/moves/c.txt"})
    check("dropbox: move_v2 of a missing item is 409 from_lookup/not_found",
          r.status == 409 and str(r.field("error_summary")).startswith("from_lookup/not_found/"), r)
    r = rpc("files/move_v2", {"from_path": "/E2E Test/moves/a.txt", "to_path": "/E2E Test/moves/sub/a.txt"})
    check("dropbox: move_v2 moves, creating the destination folder",
          r.status == 200 and r.field("metadata", "path_display") == "/E2E Test/moves/sub/a.txt", r)
    r = rpc("files/move_v2", {"from_path": "/E2E Test/moves/sub/a.txt", "to_path": "/E2E Test/moves/sub/A.txt"})
    check("dropbox: a case-only rename works", r.status == 200 and r.field("metadata", "name") == "A.txt", r)
    r = rpc("files/move_v2", {"from_path": "/E2E Test/moves", "to_path": "/E2E Test/moves/sub/inner"})
    check("dropbox: moving a folder into itself is refused",
          r.status == 409 and "cant_move_folder_into_itself" in str(r.field("error_summary")), r)

    upload("/E2E Test/deep/quarterly-budget.xlsx", b"x")
    upload("/notes-budget-outside.txt", b"y")
    r = rpc("files/search_v2", {"query": "budget", "options": {"path": "/E2E Test", "max_results": 10,
                                                               "filename_only": True}})
    found = [m["metadata"]["metadata"]["path_display"] for m in r.field("matches") or []]
    check("dropbox: search_v2 finds names under the path", r.status == 200
          and found == ["/E2E Test/deep/quarterly-budget.xlsx"], r)

    r = rpc("files/delete_v2", {"path": "/E2E Test/moves"})
    check("dropbox: delete_v2 deletes a folder", r.status == 200 and r.field("metadata", ".tag") == "folder", r)
    r = rpc("files/get_metadata", {"path": "/E2E Test/moves/b.txt"})
    check("dropbox: delete_v2 took the folder's contents", r.status == 409, r)
    r = rpc("files/delete_v2", {"path": "/E2E Test/moves"})
    check("dropbox: delete_v2 of a missing item is 409 path_lookup/not_found",
          r.status == 409 and str(r.field("error_summary")).startswith("path_lookup/not_found/"), r)

    mock.admin("throttle", provider="dropbox", count=2)
    statuses = [rpc("users/get_current_account", None) for _ in range(3)]
    check("dropbox: throttling answers 429 with Retry-After: 1, then recovers",
          [s.status for s in statuses] == [429, 429, 200] and statuses[0].header("Retry-After") == "1"
          and str(statuses[0].field("error_summary")).startswith("too_many_requests/"), statuses)


# MARK: - Microsoft Graph

GRAPH_DRIVE = "https://graph.microsoft.com/v1.0/me/drive"
GRAPH_FIELDS = "id,name,size,file,folder,package,lastModifiedDateTime,createdDateTime,cTag,eTag,parentReference"


def graph_url(path, suffix=""):
    """The client's addressing: /root for the top, /root:/a/b: below it, every segment encoded."""
    if path == "/":
        return f"{GRAPH_DRIVE}/root{suffix}"
    encoded = "/".join(quote(segment, safe="") for segment in path.strip("/").split("/"))
    return f"{GRAPH_DRIVE}/root:/{encoded}:{suffix}"


def test_graph(mock):
    account = Account(mock, "microsoft")
    r = account.call("GET", "https://graph.microsoft.com/v1.0/me?$select=userPrincipalName,mail")
    check("graph: /me with $select answers only those fields",
          r.status == 200 and set(r.json()) == {"userPrincipalName", "mail"}, r)
    r = mock.call("GET", "https://graph.microsoft.com/v1.0/me")
    check("graph: no token is 401 InvalidAuthenticationToken with WWW-Authenticate",
          r.status == 401 and r.field("error", "code") == "InvalidAuthenticationToken"
          and r.header("WWW-Authenticate"), r)
    r = account.call("GET", graph_url("/", f"?$select={GRAPH_FIELDS}"))
    check("graph: the root item", r.status == 200 and "folder" in r.json() and "id" in r.json(), r)

    folder = "文件"
    body = {"name": folder, "folder": {}, "@microsoft.graph.conflictBehavior": "fail"}
    r = account.call("POST", graph_url("/", "/children"), {"Content-Type": "application/json"}, json.dumps(body).encode())
    check("graph: POST children creates a folder", r.status == 201 and r.field("name") == folder, r)
    r = account.call("POST", graph_url("/", "/children"), {"Content-Type": "application/json"}, json.dumps(body).encode())
    check("graph: the same name again is 409 nameAlreadyExists",
          r.status == 409 and r.field("error", "code") == "nameAlreadyExists", r)

    names = ["a #1.txt", "b%c&d=e+f.txt", "c.txt", "d.txt", "emoji 😀.txt"]
    for item in names:
        r = account.call("PUT", graph_url(f"/{folder}/{item}", "/content"),
                         {"Content-Type": "application/octet-stream"}, item.encode())
    check("graph: PUT content creates a file at an encoded path", r.status == 201 and r.field("name") == names[-1], r)
    r = account.call("PUT", graph_url(f"/{folder}/bad?.txt", "/content"), {}, b"x")
    check("graph: a name with a character OneDrive forbids is a 400", r.status == 400, r)
    before = account.call("GET", graph_url(f"/{folder}/c.txt", f"?$select={GRAPH_FIELDS}")).field("cTag")
    r = account.call("PUT", graph_url(f"/{folder}/c.txt", "/content"), {}, b"changed")
    check("graph: replacing content is 200 with a new cTag",
          r.status == 200 and r.field("cTag") and r.field("cTag") != before, r)

    url, listed, pages, paths = graph_url(f"/{folder}", f"/children?$top=2&$select={GRAPH_FIELDS}"), [], 0, set()
    while url:
        r = account.call("GET", url)
        pages += 1
        listed += [v["name"] for v in r.field("value") or []]
        paths |= {unquote(v["parentReference"]["path"]) for v in r.field("value") or []}
        url = r.field("@odata.nextLink")
        if url and not url.startswith("https://graph.microsoft.com/"):
            check("graph: @odata.nextLink is on graph.microsoft.com", False, url)
            break
    check("graph: children page through @odata.nextLink", listed == sorted(names, key=str.lower) and pages == 3,
          f"{pages} pages, {listed}")
    check("graph: parentReference.path names the folder", paths == {f"/drive/root:/{folder}"}, paths)
    r = account.call("GET", graph_url(f"/{folder}/c.txt", "?$select=id"))
    check("graph: $select=id answers only the id", r.status == 200 and set(r.json()) == {"id"}, r)
    r = account.call("GET", graph_url(f"/{folder}/missing.txt"))
    check("graph: a missing item is 404 itemNotFound", r.status == 404 and r.field("error", "code") == "itemNotFound", r)

    data = os.urandom(5000)
    account.call("PUT", graph_url("/v.mov", "/content"), {}, data)
    r = account.call("GET", graph_url("/v.mov", "/content"))
    location = r.header("Location") or ""
    check("graph: /content redirects to a pre-signed URL on graph-content.mock",
          r.status == 302 and location.startswith("https://graph-content.mock/"), r)
    r = mock.call("GET", location)
    check("graph: the pre-signed URL serves the bytes without a token", r.status == 200 and r.body == data, r)
    r = mock.call("GET", location, {"Range": "bytes=4990-5089"})
    check("graph: the pre-signed URL serves ranges", r.status == 206 and r.body == data[4990:], r)
    r = mock.call("GET", location, {"Authorization": f"Bearer {account.access}"})
    check("graph: the pre-signed URL refuses the account's token", r.status == 401, r)
    r = mock.call("GET", location.replace("sig=", "sig=0"))
    check("graph: a tampered pre-signed URL is refused", r.status == 401, r)

    large = os.urandom(2 * GRAPH_FRAGMENT * 2 + 777)
    r = account.call("POST", graph_url(f"/{folder}/large.bin", "/createUploadSession"), {"Content-Type": "application/json"},
                     json.dumps({"item": {"@microsoft.graph.conflictBehavior": "replace"}}).encode())
    upload_url = r.field("uploadUrl") or ""
    check("graph: createUploadSession hands out a URL on graph-upload.mock",
          r.status == 200 and upload_url.startswith("https://graph-upload.mock/"), r)

    def fragment(start, end, headers=None):
        sent = dict(headers or {}, **{"Content-Range": f"bytes {start}-{end - 1}/{len(large)}"})
        return mock.call("PUT", upload_url, sent, large[start:end])

    step = 2 * GRAPH_FRAGMENT
    r = fragment(0, step, {"Authorization": f"Bearer {account.access}"})
    check("graph: the upload URL refuses the account's token", r.status == 401, r)
    r = fragment(0, 1000)
    check("graph: a fragment that is not a multiple of 320 KiB is refused", r.status == 400, r)
    r = fragment(0, step)
    check("graph: a fragment is 202 with nextExpectedRanges",
          r.status == 202 and r.field("nextExpectedRanges") == [f"{step}-"], r)
    r = fragment(0, step)
    check("graph: a fragment out of order is 416", r.status == 416, r)
    fragment(step, 2 * step)
    r = fragment(2 * step, len(large))
    check("graph: the last fragment creates the file", r.status == 201 and r.field("size") == len(large), r)
    r = mock.call("GET", account.call("GET", graph_url(f"/{folder}/large.bin", "/content")).header("Location"))
    check("graph: the session's file downloads intact", r.body == large)
    r = account.call("POST", graph_url(f"/{folder}/large.bin", "/createUploadSession"), {"Content-Type": "application/json"},
                     json.dumps({"item": {"@microsoft.graph.conflictBehavior": "fail"}}).encode())
    check("graph: createUploadSession with fail onto a taken name is 409", r.status == 409, r)

    account.call("POST", graph_url("/", "/children"), {"Content-Type": "application/json"},
                 json.dumps({"name": "dir", "folder": {}}).encode())
    directory = account.call("GET", graph_url("/dir", "?$select=id")).field("id")
    patch = graph_url(f"/{folder}/c.txt", "?@microsoft.graph.conflictBehavior=fail")
    r = account.call("PATCH", patch, {"Content-Type": "application/json"}, json.dumps({"name": "D.txt"}).encode())
    check("graph: a rename onto a taken name, any case, is 409", r.status == 409, r)
    r = account.call("PATCH", patch, {"Content-Type": "application/json"},
                     json.dumps({"name": "renamed.txt", "parentReference": {"id": directory}}).encode())
    check("graph: PATCH moves by destination ID and renames", r.status == 200 and r.field("name") == "renamed.txt", r)
    check("graph: the moved file is at its new path and not its old one",
          account.call("GET", graph_url("/dir/renamed.txt")).status == 200
          and account.call("GET", graph_url(f"/{folder}/c.txt")).status == 404)
    r = account.call("PATCH", graph_url("/dir"), {"Content-Type": "application/json"},
                     json.dumps({"parentReference": {"id": directory}}).encode())
    check("graph: moving a folder into itself is refused", r.status == 400, r)
    r = account.call("PATCH", graph_url("/dir/renamed.txt"), {"Content-Type": "application/json"},
                     json.dumps({"parentReference": {"id": "nope"}}).encode())
    check("graph: moving to a missing folder is 404", r.status == 404, r)

    r = account.call("GET", f"{GRAPH_DRIVE}/root/search(q='{quote('renamed')}')?$top=20&$select={GRAPH_FIELDS}")
    hits = [(v["name"], unquote(v["parentReference"]["path"])) for v in r.field("value") or []]
    check("graph: search finds names across the drive with their parent path",
          r.status == 200 and hits == [("renamed.txt", "/drive/root:/dir")], r)
    query = quote("a #1".replace("'", "''"), safe="")
    r = account.call("GET", f"{GRAPH_DRIVE}/root/search(q='{query}')?$top=20&$select={GRAPH_FIELDS}")
    check("graph: search takes an encoded query", [v["name"] for v in r.field("value") or []] == ["a #1.txt"], r)

    r = account.call("DELETE", graph_url(f"/{folder}"))
    check("graph: DELETE is 204", r.status == 204, r)
    check("graph: DELETE took the folder's contents", account.call("GET", graph_url(f"/{folder}/d.txt")).status == 404)
    check("graph: DELETE of a missing item is 404", account.call("DELETE", graph_url(f"/{folder}")).status == 404)

    mock.admin("throttle", provider="microsoft", count=1)
    statuses = [account.call("GET", graph_url("/", "?$select=id")) for _ in range(2)]
    check("graph: throttling answers 429 with Retry-After: 1, then recovers",
          [s.status for s in statuses] == [429, 200] and statuses[0].header("Retry-After") == "1"
          and statuses[0].field("error", "code") == "activityLimitReached", statuses)


# MARK: - Google Drive

DRIVE_API = "https://www.googleapis.com/drive/v3"
DRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3"
DRIVE_FIELDS = "id,name,mimeType,size,modifiedTime,createdTime,md5Checksum,version,shortcutDetails,capabilities(canEdit)"
FOLDER = "application/vnd.google-apps.folder"
SPREADSHEET = "application/vnd.google-apps.spreadsheet"
XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


def test_google(mock):
    account = Account(mock, "google")

    def get(path, **params):
        return account.call("GET", f"{DRIVE_API}{path}" + (f"?{urlencode(params, quote_via=quote)}" if params else ""))

    def create(meta):
        return account.call("POST", f"{DRIVE_API}/files?supportsAllDrives=true&fields=id",
                            {"Content-Type": "application/json"}, json.dumps(meta).encode())

    def patch(file_id, meta, query=""):
        return account.call("PATCH", f"{DRIVE_API}/files/{file_id}?supportsAllDrives=true&fields=id{query}",
                            {"Content-Type": "application/json"}, json.dumps(meta).encode())

    def children(folder_id, page_size=1000):
        files, token, pages = [], None, 0
        while True:
            params = {"q": f"'{folder_id}' in parents and trashed = false",
                      "fields": f"nextPageToken,files({DRIVE_FIELDS})", "pageSize": page_size,
                      "supportsAllDrives": "true", "includeItemsFromAllDrives": "true"}
            if token:
                params["pageToken"] = token
            r = get("/files", **params)
            pages += 1
            files += r.field("files") or []
            token = r.field("nextPageToken")
            if not token:
                return files, pages

    def start_upload(meta, size, file_id=None):
        path, method = (f"/files/{file_id}", "PATCH") if file_id else ("/files", "POST")
        r = account.call(method, f"{DRIVE_UPLOAD}{path}?uploadType=resumable&supportsAllDrives=true&fields=id",
                         {"Content-Type": "application/json", "X-Upload-Content-Length": str(size)},
                         json.dumps(meta).encode())
        return r, r.header("Location") or ""

    r = get("/about")
    check("google: about without fields is 400 required", r.status == 400 and r.field("error", "errors", 0, "reason") == "required", r)
    r = get("/about", fields="user(emailAddress)")
    check("google: about answers just the fields asked for",
          r.status == 200 and list(r.json()) == ["user"] and list(r.field("user")) == ["emailAddress"], r)
    r = mock.call("GET", f"{DRIVE_API}/about?fields=user", {"Authorization": "Bearer nonsense"})
    check("google: an unknown token is 401 authError",
          r.status == 401 and r.field("error", "code") == 401 and r.field("error", "errors", 0, "reason") == "authError", r)
    r = get("/files/root", fields=DRIVE_FIELDS, supportsAllDrives="true")
    root = r.field("id")
    check("google: files/root is My Drive, a folder",
          r.status == 200 and r.field("mimeType") == FOLDER and r.field("capabilities") == {"canEdit": True}, r)
    r = get("/files/root", fields="id,nosuchfield")
    check("google: a field Drive does not have is 400 invalidParameter", r.status == 400, r)
    r = get("/files/root")
    check("google: without fields, files.get answers the default fields",
          set(r.json() or {}) == {"kind", "id", "name", "mimeType"}, r)

    docs = create({"name": "docs", "mimeType": FOLDER, "parents": [root]}).field("id")
    twin = create({"name": "docs", "mimeType": FOLDER, "parents": [root]}).field("id")
    files, _ = children(root)
    check("google: a second folder of the same name is a second item",
          docs and twin and docs != twin and sorted(f["id"] for f in files) == sorted([docs, twin]), files)
    r = get("/files", q="'root' in parents and trashed = false")
    check("google: 'root' names My Drive in a query, and the default list fields apply",
          r.status == 200 and len(r.field("files")) == 2 and set(r.field("files", 0)) == {"kind", "id", "name", "mimeType"}
          and set(r.json()) == {"kind", "incompleteSearch", "files"}, r)
    r = get("/files", q="'root' in parents and")
    check("google: a malformed query is 400", r.status == 400 and r.field("error", "errors", 0, "location") == "q", r)
    r = get("/files", q="'no-such-folder' in parents and trashed = false")
    check("google: a query naming a missing folder is 404", r.status == 404, r)

    data = os.urandom(2000)
    r, location = start_upload({"name": "n.bin", "parents": [docs]}, len(data))
    check("google: a resumable upload answers with a session URI on www.googleapis.com",
          r.status == 200 and location.startswith(f"{DRIVE_UPLOAD}/files?") and "upload_id=" in location, r)
    r = account.call("PUT", location, {"Content-Type": "application/octet-stream"}, data)
    file_id = r.field("id")
    check("google: the whole file in one PUT completes it, answering the fields asked for",
          r.status == 200 and set(r.json()) == {"id"}, r)
    r = get(f"/files/{file_id}", fields=DRIVE_FIELDS)
    check("google: size and md5Checksum describe the bytes",
          r.field("size") == str(len(data)) and r.field("md5Checksum") == hashlib.md5(data).hexdigest(), r)
    version = int(r.field("version") or 0)
    r = account.call("PUT", location, {"Content-Type": "application/octet-stream"}, data)
    check("google: a completed session answers a retry the same way", r.status == 200 and r.field("id") == file_id, r)

    replacement = os.urandom(3000)
    r, location = start_upload({}, len(replacement), file_id)
    check("google: replacing content starts at /upload/drive/v3/files/<id>",
          r.status == 200 and location.startswith(f"{DRIVE_UPLOAD}/files/{file_id}?"), r)
    r = mock.call("PUT", location, {"Content-Type": "application/octet-stream"}, replacement)
    check("google: the session URI takes the bytes without a token", r.status == 200 and r.field("id") == file_id, r)
    r = get(f"/files/{file_id}", fields=DRIVE_FIELDS)
    check("google: the same item now has the new bytes and a higher version",
          r.field("md5Checksum") == hashlib.md5(replacement).hexdigest() and int(r.field("version")) > version, r)
    r = get(f"/files/{file_id}", alt="media", supportsAllDrives="true")
    check("google: alt=media returns the bytes", r.status == 200 and r.body == replacement, r)
    r = account.call("GET", f"{DRIVE_API}/files/{file_id}?alt=media", {"Range": "bytes=10-29"})
    check("google: alt=media serves ranges", r.status == 206 and r.body == replacement[10:30], r)
    r = account.call("GET", f"{DRIVE_API}/files/{file_id}?alt=media", {"Range": "bytes=3000-"})
    check("google: a range past the end is 416", r.status == 416, r)

    chunked = os.urandom(600 * 1024)
    r, location = start_upload({"name": "chunked.bin", "parents": [docs]}, len(chunked))
    first = 256 * 1024
    r = account.call("PUT", location, {"Content-Range": f"bytes 0-{first - 1}/{len(chunked)}"}, chunked[:first])
    check("google: a chunk is 308 Resume Incomplete with the Range received",
          r.status == 308 and r.header("Range") == f"bytes=0-{first - 1}", r)
    r = account.call("PUT", location, {"Content-Range": f"bytes */{len(chunked)}"}, b"")
    check("google: a status query reports the Range received", r.status == 308 and r.header("Range") == f"bytes=0-{first - 1}", r)
    r = account.call("PUT", location, {"Content-Range": f"bytes 5-{len(chunked) - 1}/{len(chunked)}"}, chunked[5:])
    check("google: a chunk at the wrong offset is refused", r.status == 400, r)
    r = account.call("PUT", location, {"Content-Range": f"bytes {first}-{len(chunked) - 1}/{len(chunked)}"},
                     chunked[first:])
    chunked_id = r.field("id")
    check("google: the last chunk completes the upload", r.status == 200 and chunked_id, r)
    check("google: the chunked file reads back intact", get(f"/files/{chunked_id}", alt="media").body == chunked)

    for i in range(3):
        create({"name": f"page-{i}.txt", "parents": [docs]})
    files, pages = children(docs, page_size=2)
    check("google: listing pages through nextPageToken",
          pages == 3 and sorted(f["name"] for f in files) == ["chunked.bin", "n.bin", "page-0.txt", "page-1.txt", "page-2.txt"],
          f"{pages} pages, {[f['name'] for f in files]}")
    check("google: listed files carry only the fields asked for",
          all(set(f) <= set(DRIVE_FIELDS.replace("capabilities(canEdit)", "capabilities").split(",")) for f in files), files)

    sheet = create({"name": "預算", "mimeType": SPREADSHEET, "parents": [docs]}).field("id")
    create({"name": "問卷", "mimeType": "application/vnd.google-apps.form", "parents": [docs]})
    r = get(f"/files/{sheet}", alt="media")
    check("google: alt=media of a Google document is 403 fileNotDownloadable",
          r.status == 403 and r.field("error", "errors", 0, "reason") == "fileNotDownloadable", r)
    r = get(f"/files/{sheet}/export", mimeType=XLSX)
    check("google: export answers the converted document",
          r.status == 200 and r.body == f"EXPORT:預算:{XLSX}".encode(), r)
    r = get(f"/files/{sheet}/export",
            mimeType="application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    check("google: an export to a format the type has not is 400", r.status == 400, r)
    r = get(f"/files/{file_id}/export", mimeType=XLSX)
    check("google: exporting a binary file is 403 fileNotExportable", r.status == 403, r)
    listed = {f["name"]: f for f in children(docs)[0]}
    check("google: a Google document lists without size or md5",
          "size" not in listed["預算"] and "md5Checksum" not in listed["預算"] and "問卷" in listed, listed.get("預算"))

    shortcut = create({"name": "捷徑", "mimeType": "application/vnd.google-apps.shortcut",
                       "shortcutDetails": {"targetId": docs}, "parents": [twin]}).field("id")
    r = get(f"/files/{shortcut}", fields=DRIVE_FIELDS)
    check("google: a shortcut names its target and the target's type",
          r.field("shortcutDetails") == {"targetId": docs, "targetMimeType": FOLDER}, r)
    r = create({"name": "dangling", "mimeType": "application/vnd.google-apps.shortcut",
                "shortcutDetails": {"targetId": "missing"}, "parents": [twin]})
    check("google: a shortcut to a missing item is 404", r.status == 404, r)

    r = patch(file_id, {"name": "a/b.bin"})
    check("google: a rename keeps a slash in the name",
          r.status == 200 and get(f"/files/{file_id}", fields="name").field("name") == "a/b.bin", r)
    r = patch(file_id, {}, f"&addParents={twin}")
    check("google: adding a second parent is 403 cannotAddParent",
          r.status == 403 and r.field("error", "errors", 0, "reason") == "cannotAddParent", r)
    r = patch(file_id, {}, f"&addParents={twin}&removeParents={docs}")
    check("google: addParents with removeParents moves",
          r.status == 200 and get(f"/files/{file_id}", fields="parents").field("parents") == [twin], r)
    r = patch(docs, {}, f"&addParents={docs}&removeParents={root}")
    check("google: moving a folder into itself is refused", r.status == 400, r)

    r = patch(docs, {"trashed": True})
    inside = get(f"/files/{chunked_id}", fields="trashed,explicitlyTrashed")
    check("google: trashing a folder trashes what is inside it",
          r.status == 200 and inside.field("trashed") is True and inside.field("explicitlyTrashed") is False, inside)
    check("google: a trashed folder is left out of trashed = false listings",
          [f["id"] for f in children(root)[0]] == [twin] and children(docs)[0] == [])
    r = get(f"/files/{docs}", fields="trashed")
    check("google: files.get still answers for a trashed item", r.status == 200 and r.field("trashed") is True, r)
    patch(docs, {"trashed": False})
    check("google: restoring from the trash brings it back", len(children(docs)[0]) == 6)

    r = account.call("DELETE", f"{DRIVE_API}/files/{shortcut}")
    check("google: DELETE removes for good", r.status == 204 and get(f"/files/{shortcut}").status == 404, r)

    mock.admin("throttle", provider="google", count=1)
    statuses = [get("/files/root", fields="id") for _ in range(2)]
    check("google: throttling answers 403 userRateLimitExceeded, then recovers",
          [s.status for s in statuses] == [403, 200]
          and statuses[0].field("error", "errors", 0, "reason") == "userRateLimitExceeded", statuses)


# MARK: - Tokens, admin and concurrency

def test_tokens(mock, config):
    for provider in TOKEN_URLS:
        form = urlencode({"grant_type": "authorization_code", "code": "e2e-code", "redirect_uri": "http://127.0.0.1:53682/",
                          "client_id": "hamasen-e2e", "code_verifier": "x" * 64})
        r = mock.call("POST", TOKEN_URLS[provider], {"Content-Type": "application/x-www-form-urlencoded"}, form.encode())
        pair = r.json() or {}
        check(f"{provider}: the code e2e-code is exchanged for a token pair",
              r.status == 200 and pair.get("access_token") and pair.get("refresh_token")
              and pair.get("expires_in") == config["token_lifetime"], r)
        r = mock.call("POST", TOKEN_URLS[provider], {"Content-Type": "application/x-www-form-urlencoded"},
                      form.replace("e2e-code", "other").encode())
        check(f"{provider}: another code is 400 invalid_grant", r.status == 400 and r.field("error") == "invalid_grant", r)
        r = refresh(mock, provider, "never-issued")
        check(f"{provider}: an unknown refresh token is 400 invalid_grant",
              r.status == 400 and r.field("error") == "invalid_grant", r)
        before = mock.admin("stats")["refreshes"][provider]
        r = refresh(mock, provider, pair.get("refresh_token", ""))
        rotates = provider == "microsoft"
        check(f"{provider}: a refresh issues an access token" + (" and a new refresh token" if rotates else " only"),
              r.status == 200 and r.field("access_token")
              and (r.field("refresh_token") not in (None, pair.get("refresh_token")) if rotates
                   else r.field("refresh_token") is None), r)
        check(f"{provider}: stats count the refresh", mock.admin("stats")["refreshes"][provider] == before + 1)

    old = mock.admin("token", provider="microsoft")["refresh_token"]
    new = refresh(mock, "microsoft", old).field("refresh_token")
    check("microsoft: a rotated refresh token still works within the grace period",
          refresh(mock, "microsoft", old).status == 200)
    grace = config["rotation_grace"]
    if grace <= SHORT_WAIT_LIMIT:
        time.sleep(grace + 1)
        check("microsoft: a rotated refresh token stops working after the grace period",
              refresh(mock, "microsoft", old).field("error") == "invalid_grant")
        check("microsoft: its replacement keeps working", refresh(mock, "microsoft", new).status == 200)
    else:
        skip("microsoft: rotated refresh token expiry", f"ROTATION_GRACE is {grace}s")

    lifetime = config["token_lifetime"]
    if lifetime <= SHORT_WAIT_LIMIT:
        pairs = {p: mock.admin("token", provider=p) for p in TOKEN_URLS}
        time.sleep(lifetime + 1)
        r = mock.call("POST", "https://api.dropboxapi.com/2/users/get_current_account",
                      {"Content-Type": "application/json", "Authorization": f"Bearer {pairs['dropbox']['access_token']}"},
                      b"null")
        check("dropbox: an expired access token is 401 expired_access_token",
              r.status == 401 and r.field("error", ".tag") == "expired_access_token", r)
        r = mock.call("GET", "https://graph.microsoft.com/v1.0/me",
                      {"Authorization": f"Bearer {pairs['microsoft']['access_token']}"})
        check("microsoft: an expired access token is 401", r.status == 401, r)
        r = mock.call("GET", f"{DRIVE_API}/about?fields=user",
                      {"Authorization": f"Bearer {pairs['google']['access_token']}"})
        check("google: an expired access token is 401", r.status == 401, r)
        r = refresh(mock, "google", pairs["google"]["refresh_token"])
        r = mock.call("GET", f"{DRIVE_API}/about?fields=user", {"Authorization": f"Bearer {r.field('access_token')}"})
        check("google: a refreshed access token works again", r.status == 200, r)
    else:
        skip("access token expiry", f"TOKEN_LIFETIME is {lifetime}s")

    google = Account(mock, "google")
    r = mock.call("GET", "https://graph.microsoft.com/v1.0/me", {"Authorization": f"Bearer {google.access}"})
    check("microsoft: a Google access token does not open Graph", r.status == 401, r)

    probes = {
        "dropbox": ("POST", "https://api.dropboxapi.com/2/users/get_current_account", b"null"),
        "microsoft": ("GET", "https://graph.microsoft.com/v1.0/me", None),
        "google": ("GET", f"{DRIVE_API}/about?fields=user", None),
    }
    for provider, (method, url, body) in probes.items():
        account = Account(mock, provider)
        mock.admin("revoke", provider=provider)
        r = refresh(mock, provider, account.refresh)
        check(f"{provider}: after revoke, the refresh token is 400 invalid_grant",
              r.status == 400 and r.field("error") == "invalid_grant", r)
        r = mock.call(method, url, {"Content-Type": "application/json", "Authorization": f"Bearer {account.access}"}, body)
        check(f"{provider}: after revoke, the access token is 401", r.status == 401, r)


def test_concurrency(mock):
    """Many clients uploading and reading back at once, as the File Provider extension does."""
    errors = []

    def dropbox_worker(index):
        account = Account(mock, "dropbox")
        data = os.urandom(300_000 + index)
        path = f"/parallel/p-{index}.bin"
        r = account.call("POST", "https://content.dropboxapi.com/2/files/upload",
                         {"Content-Type": "application/octet-stream",
                          "Dropbox-API-Arg": json.dumps({"path": path, "mode": "overwrite"})}, data)
        back = account.call("POST", "https://content.dropboxapi.com/2/files/download",
                            {"Dropbox-API-Arg": json.dumps({"path": path})})
        if r.status != 200 or back.body != data:
            errors.append(f"dropbox {index}: {r} / {back.status}")

    def graph_worker(index):
        account = Account(mock, "microsoft")
        data = os.urandom(200_000 + index)
        r = account.call("PUT", graph_url(f"/parallel/p-{index}.bin", "/content"), {}, data)
        location = account.call("GET", graph_url(f"/parallel/p-{index}.bin", "/content")).header("Location")
        back = mock.call("GET", location) if location else None
        if r.status not in (200, 201) or back is None or back.body != data:
            errors.append(f"graph {index}: {r}")

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(12) for worker in (dropbox_worker, graph_worker)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    check("concurrency: 24 simultaneous uploads and downloads all intact", not errors, errors[:3])
    stats = mock.admin("stats")
    check("concurrency: no upload session is left behind", sum(stats["uploads"].values()) == 0, stats["uploads"])


def main():
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} http://127.0.0.1:<port>")
    mock = Mock(sys.argv[1])
    mock.admin("reset")
    config = mock.admin("stats")["config"]
    print(f"mock config: {config}", flush=True)

    test_dropbox(mock)
    test_graph(mock)
    test_google(mock)
    test_concurrency(mock)

    stats = mock.admin("stats")
    check("admin: stats count requests, refreshes and items per provider",
          all(stats[key].keys() == set(TOKEN_URLS) for key in ("requests", "refreshes", "items"))
          and all(stats["items"][p] > 0 and stats["requests"][p] > 0 for p in TOKEN_URLS), stats)
    test_tokens(mock, config)
    r = mock.send("POST", "/__admin/token", {"Content-Type": "application/json"}, b'{"provider": "icloud"}')
    check("admin: an unknown provider is a 400", r.status == 400, r)
    stale = Account(mock, "dropbox")
    mock.admin("reset")
    stats = mock.admin("stats")
    check("admin: reset empties every drive and forgets every token",
          set(stats["items"].values()) == {0} and stats["tokens"] == {"access": 0, "refresh": 0}, stats)
    r = mock.call("POST", "https://api.dropboxapi.com/2/users/get_current_account",
                  {"Content-Type": "application/json", "Authorization": f"Bearer {stale.access}"}, b"null")
    check("admin: a token from before the reset is 401", r.status == 401, r)

    print(f"{len(failures)} failed" if failures else "all checks passed", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
