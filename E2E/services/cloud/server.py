#!/usr/bin/env python3
"""Mock of Dropbox, Microsoft Graph (OneDrive) and Google Drive, with their
OAuth token endpoints, for Hamasen's end-to-end tests.

The harness rewrites every request a cloud client makes from
https://<host>/<path> to http://<this server>/<host>/<path>, so the first
path component names the real API host. E2E/CONTRACT.md ("Cloud mock") is
the contract, admin API included. The API surface is what the Swift clients
in HamasenCore/Sources/HamasenCore/Cloud send; the answers follow what each
provider documents, error formats included.

Metadata is kept in memory behind one lock. File content is kept in files
under DATA_DIR, so a long run grows the disk by what is stored and the
process by nothing else.

Environment: PORT (8090), BIND (0.0.0.0), DATA_DIR (/data),
TOKEN_LIFETIME (3600), ROTATION_GRACE (60).
"""

import base64
import calendar
import contextlib
import hashlib
import hmac
import http.server
import io
import itertools
import json
import mimetypes
import os
import re
import secrets
import shutil
import signal
import sys
import threading
import time
import traceback
import uuid
from urllib.parse import parse_qsl, quote, unquote

PORT = int(os.environ.get("PORT", "8090"))
BIND = os.environ.get("BIND", "0.0.0.0")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
TOKEN_LIFETIME = int(os.environ.get("TOKEN_LIFETIME", "3600"))
ROTATION_GRACE = int(os.environ.get("ROTATION_GRACE", "60"))

FILES_DIR = os.path.join(DATA_DIR, "files")
PROVIDERS = ("dropbox", "microsoft", "google")
EMAIL = "hamasen@example.com"
DISPLAY_NAME = "Hamasen E2E"

# Every API here documents that a page may hold fewer entries than asked
# for. Pages never hold more than this, so folders of a size a test can
# afford to create still make the clients follow their cursors.
PAGE_SIZE = 100
UPLOAD_IDLE_SECONDS = 3600
TRASH_RETENTION_SECONDS = 30 * 86400  # Drive empties its trash after 30 days
CONTENT_URL_SECONDS = 3600  # lifetime of a Graph pre-signed download URL
# An expired access token is remembered this long, so a late request hears
# "expired" rather than "invalid"; after that it is forgotten.
EXPIRED_TOKEN_MEMORY_SECONDS = 600
MAX_JSON_BODY = 1024 * 1024
DROPBOX_BLOCK = 4 * 1024 * 1024
GRAPH_FRAGMENT = 320 * 1024
GRAPH_DRIVE_ID = "e2e0c1d0e2e0c1d0"
GRAPH_INVALID_CHARACTERS = set('"*:<>?/\\|')

FOLDER_MIME = "application/vnd.google-apps.folder"
SHORTCUT_MIME = "application/vnd.google-apps.shortcut"
GOOGLE_TYPE_PREFIX = "application/vnd.google-apps."

SEQUENCE = itertools.count(1)
REVISION_PREFIX = secrets.token_hex(4)
SIGNING_KEY = secrets.token_bytes(32)
LOG_LOCK = threading.Lock()


# MARK: - Utilities

def iso(timestamp, millis=True):
    """RFC 3339 in UTC, the way the providers write times."""
    text = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(timestamp))
    if millis:
        text += ".%03d" % (int(timestamp * 1000) % 1000)
    return text + "Z"


def encode_token(value):
    """An opaque, URL-safe cursor or page token."""
    raw = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_token(text):
    """Raises ValueError for anything encode_token did not make."""
    return json.loads(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)))


def unlink(path):
    # A blob can already be gone when a reset raced the request holding it.
    with contextlib.suppress(FileNotFoundError):
        os.remove(path)


def new_blob_path():
    return os.path.join(FILES_DIR, uuid.uuid4().hex)


def new_revision():
    return f"{REVISION_PREFIX}{next(SEQUENCE):08x}"


def guess_mime(name):
    return mimetypes.guess_type(name)[0] or "application/octet-stream"


def digests(blocks):
    """The hashes the providers report, over content in DROPBOX_BLOCK-sized
    blocks. Dropbox's content_hash is the SHA-256 of the blocks' SHA-256s."""
    md5, sha1, sha256, block_hashes = hashlib.md5(), hashlib.sha1(), hashlib.sha256(), []
    for block in blocks:
        md5.update(block)
        sha1.update(block)
        sha256.update(block)
        block_hashes.append(hashlib.sha256(block).digest())
    return {
        "md5": md5.hexdigest(), "sha1": sha1.hexdigest(), "sha256": sha256.hexdigest(),
        "dropbox": hashlib.sha256(b"".join(block_hashes)).hexdigest(),
    }


def digest_file(path):
    with open(path, "rb") as f:
        return digests(iter(lambda: f.read(DROPBOX_BLOCK), b""))


EMPTY_DIGESTS = digests([])


def free_name(drive, parent, name, folder, pattern):
    """The first numbered variant of name that parent does not hold yet."""
    base, extension = (name, "") if folder else os.path.splitext(name)
    for number in itertools.count(1):
        candidate = pattern.format(base=base, n=number, ext=extension)
        if drive.child(parent, candidate) is None:
            return candidate


# MARK: - Requests and replies

class BadRequestBody(Exception):
    """The body's framing is broken; the connection cannot be reused."""


class BodyTooLarge(Exception):
    pass


class RequestBody:
    """The request's body, read once, framed by Content-Length or chunked."""

    def __init__(self, rfile, headers):
        self.rfile = rfile
        self.chunked = "chunked" in (headers.get("Transfer-Encoding") or "").lower()
        if self.chunked:
            self.left = 0  # bytes left in the current chunk
            self.done = False
            return
        try:
            self.left = int(headers.get("Content-Length") or 0)
        except ValueError:
            raise BadRequestBody("invalid Content-Length")
        if self.left < 0:
            raise BadRequestBody("invalid Content-Length")
        self.done = self.left == 0

    def read(self, size=1 << 20):
        """Up to size bytes; b"" once the body is over."""
        if self.done:
            return b""
        if self.chunked and self.left == 0:
            line = self.rfile.readline(1024)
            try:
                self.left = int(line.split(b";")[0].strip(), 16)
            except ValueError:
                raise BadRequestBody("invalid chunk size")
            if self.left == 0:
                while self.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                    pass  # trailer fields
                self.done = True
                return b""
        data = self.rfile.read(min(size, self.left))
        if not data:
            raise BadRequestBody("the body ended early")
        self.left -= len(data)
        if self.left == 0:
            if self.chunked:
                self.rfile.readline(1024)  # the CRLF closing the chunk
            else:
                self.done = True
        return data

    def read_all(self, limit):
        parts, total = [], 0
        while chunk := self.read():
            total += len(chunk)
            if total > limit:
                raise BodyTooLarge()
            parts.append(chunk)
        return b"".join(parts)

    def copy_to(self, file):
        total = 0
        while chunk := self.read():
            file.write(chunk)
            total += len(chunk)
        return total

    def drain(self):
        while self.read():
            pass


class Request:
    """A request with its target split into the real host and the rest."""

    def __init__(self, method, target, headers, body):
        path, _, self.raw_query = target.partition("?")
        host, _, rest = path[1:].partition("/")
        self.method = method
        self.host = host.lower()
        self.path = "/" + rest
        self.query = dict(parse_qsl(self.raw_query, keep_blank_values=True))
        self.headers = headers
        self.body = body

    def header(self, name):
        return self.headers.get(name)

    def media_type(self):
        return (self.header("Content-Type") or "").split(";")[0].strip().lower()

    def json(self):
        """The body as JSON, {} when empty. Raises ValueError when it is not JSON."""
        raw = self.body.read_all(MAX_JSON_BODY)
        return json.loads(raw) if raw.strip() else {}

    @property
    def bearer(self):
        scheme, _, token = (self.header("Authorization") or "").partition(" ")
        return token.strip() if scheme.lower() == "bearer" else None


class Reply:
    """A response: a body in memory, or `stream` = (open file, offset, length)."""

    def __init__(self, status, headers=(), body=b"", stream=None, reason=None):
        self.status = status
        self.headers = list(headers)
        self.body = body
        self.stream = stream
        self.reason = reason


class Fail(Exception):
    """Ends a request early with a reply in the provider's own error format."""

    def __init__(self, reply):
        super().__init__(reply.status)
        self.reply = reply


def json_reply(value, status=200, headers=()):
    body = json.dumps(value, ensure_ascii=False).encode()
    return Reply(status, [("Content-Type", "application/json; charset=utf-8"), *headers], body)


def text_reply(text, status):
    return Reply(status, [("Content-Type", "text/plain; charset=utf-8")], text.encode())


RANGE = re.compile(r"\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*")


def byte_range(header, size):
    """(start, end) for a single-range header, "unsatisfiable", or None to
    send everything: a header this does not understand is ignored, as
    RFC 9110 allows."""
    match = RANGE.fullmatch(header or "")
    if not match or not (match[1] or match[2]):
        return None
    if match[1]:
        start = int(match[1])
        if match[2] and int(match[2]) < start:
            return None
        end = min(int(match[2]), size - 1) if match[2] else size - 1
    else:
        suffix = int(match[2])
        if suffix == 0:
            return "unsatisfiable"
        start, end = max(size - suffix, 0), size - 1
    return (start, end) if start < size else "unsatisfiable"


def ranged_reply(request, stream, size, headers):
    span = byte_range(request.header("Range"), size)
    if span == "unsatisfiable":
        stream.close()
        return Reply(416, [("Content-Range", f"bytes */{size}")])
    headers = [*headers, ("Accept-Ranges", "bytes")]
    if span is None:
        return Reply(200, headers, stream=(stream, 0, size))
    start, end = span
    return Reply(206, [*headers, ("Content-Range", f"bytes {start}-{end}/{size}")],
                 stream=(stream, start, end - start + 1))


# MARK: - Drives

class Node:
    """A file or folder. Its content is in the file at `blob`, never in memory."""

    def __init__(self, node_id, name, folder, parent, mime=None):
        now = time.time()
        self.id = node_id
        self.name = name
        self.folder = folder
        self.parent = parent
        self.children = {} if folder else None
        self.mime = mime or (FOLDER_MIME if folder else guess_mime(name))
        self.created = self.modified = self.client_modified = now
        self.blob = None
        self.size = 0
        self.digests = EMPTY_DIGESTS
        self.version = 1  # any change: Google's version, Graph's eTag
        self.content_version = 1  # content changes only: Graph's cTag
        self.rev = new_revision()  # Dropbox's rev
        self.seq = next(SEQUENCE)
        self.trashed_at = None  # Google: when it was put in the trash itself
        self.target = None  # Google shortcut: (target id, target mime type)


# Each root keeps its ID across resets, so a client that cached it keeps working.
ROOTS = {
    "dropbox": ("id:AAAAAAAAAAAAAAAAAAAAAQ", ""),
    "microsoft": (GRAPH_DRIVE_ID.upper() + "!0", "root"),
    "google": ("0AE2EHamasenMockRootUk9PVA", "My Drive"),
}


def new_item_id(provider):
    if provider == "dropbox":
        return "id:" + secrets.token_urlsafe(16)
    if provider == "microsoft":
        return f"{GRAPH_DRIVE_ID.upper()}!{next(SEQUENCE)}"
    return "1" + secrets.token_urlsafe(24)


class Drive:
    """One provider's items: a tree of nodes under a root, indexed by ID."""

    def __init__(self, provider):
        self.provider = provider
        self.nodes = {}
        self.clear()

    def clear(self):
        """Empties the drive, deleting the content of everything in it."""
        for node in self.nodes.values():
            if node.blob:
                unlink(node.blob)
        root_id, root_name = ROOTS[self.provider]
        self.root = Node(root_id, root_name, True, None)
        self.nodes = {root_id: self.root}

    def add(self, parent, name, folder, mime=None):
        node = Node(new_item_id(self.provider), name, folder, parent, mime)
        parent.children[node.id] = node
        self.nodes[node.id] = node
        return node

    def child(self, folder, name):
        """The child with this name, ignoring case as Dropbox and OneDrive do."""
        wanted = name.lower()
        return next((n for n in folder.children.values() if n.name.lower() == wanted), None)

    def walk(self, names):
        """The node at names below the root, or None."""
        node = self.root
        for name in names:
            if not node.folder:
                return None
            node = self.child(node, name)
            if node is None:
                return None
        return node

    def make_folders(self, names):
        """The folder at names, created along the way as Dropbox and OneDrive
        do for an upload; None when a file is in the way."""
        node = self.root
        for name in names:
            found = self.child(node, name)
            if found is None:
                found = self.add(node, name, True)
            elif not found.folder:
                return None
            node = found
        return node

    def names(self, node):
        names = []
        while node.parent is not None:
            names.append(node.name)
            node = node.parent
        return names[::-1]

    def sorted_children(self, node):
        if not node.folder:
            return []
        return sorted(node.children.values(), key=lambda n: (n.name.lower(), n.seq))

    def descendants(self, node):
        """Everything under node, depth first, each folder's children by name."""
        pending = [iter(self.sorted_children(node))]
        while pending:
            child = next(pending[-1], None)
            if child is None:
                pending.pop()
                continue
            yield child
            if child.folder:
                pending.append(iter(self.sorted_children(child)))

    def contains(self, ancestor, node):
        while node is not None:
            if node is ancestor:
                return True
            node = node.parent
        return False

    def remove(self, node):
        """Deletes node and everything under it, content included."""
        for gone in [node, *self.descendants(node)]:
            del self.nodes[gone.id]
            if gone.blob:
                unlink(gone.blob)
        del node.parent.children[node.id]

    def move(self, node, parent, name):
        del node.parent.children[node.id]
        node.parent, node.name = parent, name
        parent.children[node.id] = node
        node.version += 1

    def set_content(self, node, staged):
        old = node.blob
        node.blob, node.size, node.digests = staged.adopt()
        node.modified = time.time()
        node.version += 1
        node.content_version += 1
        node.rev = new_revision()
        if old:
            unlink(old)

    def open(self, node):
        """The content as an open file, and its size. Opened under the lock,
        the file stays readable after a later change replaces or deletes it."""
        if node.blob is None:
            return io.BytesIO(), 0
        return open(node.blob, "rb"), node.size

    def is_trashed(self, node):
        """Google: in the trash itself, or inside a folder that is."""
        while node is not None:
            if node.trashed_at is not None:
                return True
            node = node.parent
        return False


class Staged:
    """Content in a file of its own, on its way to becoming an item's."""

    def __init__(self, path, size):
        self.path = path
        self.size = size
        self.digests = digest_file(path)
        self.adopted = False

    def adopt(self):
        self.adopted = True
        return self.path, self.size, self.digests

    def discard(self):
        if not self.adopted:
            unlink(self.path)


def stage(body):
    """Writes a request body to a file of its own. Never under the lock: a
    body takes as long to arrive as the client takes to send it."""
    path = new_blob_path()
    try:
        with open(path, "wb") as f:
            size = body.copy_to(f)
        return Staged(path, size)
    except BaseException:
        unlink(path)
        raise


class Upload:
    """A transfer spread over several requests: the bytes so far in a file
    of their own, the destination in `info`."""

    def __init__(self, provider, **info):
        self.id = secrets.token_urlsafe(18)
        self.provider = provider
        self.info = info
        self.path = new_blob_path()
        open(self.path, "wb").close()
        self.size = 0
        self.total = None  # the size declared up front, where the API has one
        self.closed = False  # Dropbox: no more appends
        self.result = None  # Google: the answer once complete, repeated to retries
        self.lock = threading.Lock()  # held while a request adds bytes
        self.touched = time.time()

    def append(self, body):
        """Adds the request body; returns its length, or None when the upload
        was dropped (reset or expired) meanwhile."""
        try:
            # r+b never recreates a file a reset deleted.
            with open(self.path, "r+b") as f:
                f.seek(self.size)
                written = body.copy_to(f)
                f.truncate()
        except FileNotFoundError:
            return None
        self.size += written
        self.touched = time.time()
        return written

    def truncate(self, size):
        with contextlib.suppress(FileNotFoundError):
            os.truncate(self.path, size)
        self.size = size

    def staged(self):
        return Staged(self.path, self.size)


class Tokens:
    """Access and refresh tokens the mock issued, by provider."""

    def __init__(self):
        self.access = {}  # token -> (provider, expires at)
        self.refresh = {}  # token -> [provider, stops working at or None]

    def clear(self):
        self.access.clear()
        self.refresh.clear()

    def new_access(self, provider):
        token = f"{provider}-access-{secrets.token_urlsafe(32)}"
        self.access[token] = (provider, time.time() + TOKEN_LIFETIME)
        return token

    def new_refresh(self, provider):
        token = f"{provider}-refresh-{secrets.token_urlsafe(32)}"
        self.refresh[token] = [provider, None]
        return token

    def check(self, provider, token):
        """None when the access token is good for provider, otherwise why
        not: "missing", "invalid" or "expired"."""
        if not token:
            return "missing"
        entry = self.access.get(token)
        if entry is None or entry[0] != provider:
            return "invalid"
        return "expired" if entry[1] <= time.time() else None

    def redeemable(self, provider, token):
        entry = self.refresh.get(token)
        return entry is not None and entry[0] == provider and (entry[1] is None or entry[1] > time.time())

    def retire(self, token):
        """Microsoft rotation: the old refresh token works a little longer."""
        entry = self.refresh[token]
        deadline = time.time() + ROTATION_GRACE
        entry[1] = deadline if entry[1] is None else min(entry[1], deadline)

    def revoke(self, provider):
        self.access = {t: e for t, e in self.access.items() if e[0] != provider}
        self.refresh = {t: e for t, e in self.refresh.items() if e[0] != provider}

    def prune(self, now):
        self.access = {t: e for t, e in self.access.items() if e[1] > now - EXPIRED_TOKEN_MEMORY_SECONDS}
        self.refresh = {t: e for t, e in self.refresh.items() if e[1] is None or e[1] > now}


class State:
    def __init__(self):
        self.lock = threading.RLock()
        self.tokens = Tokens()
        self.drives = {provider: Drive(provider) for provider in PROVIDERS}
        self.uploads = {}
        self.reset_counters()

    def reset_counters(self):
        self.requests = dict.fromkeys(PROVIDERS, 0)
        self.refreshes = dict.fromkeys(PROVIDERS, 0)
        self.throttle = dict.fromkeys(PROVIDERS, 0)

    def reset(self):
        for drive in self.drives.values():
            drive.clear()
        for upload in self.uploads.values():
            if upload.path:
                unlink(upload.path)
        self.uploads = {}
        self.tokens.clear()
        self.reset_counters()

    def prune(self, now):
        self.tokens.prune(now)
        for upload in list(self.uploads.values()):
            if now - upload.touched > UPLOAD_IDLE_SECONDS and not upload.lock.locked():
                del self.uploads[upload.id]
                if upload.path:
                    unlink(upload.path)
        drive = self.drives["google"]
        expired = [n for n in drive.nodes.values()
                   if n.trashed_at is not None and now - n.trashed_at > TRASH_RETENTION_SECONDS]
        for node in expired:
            if node.id in drive.nodes:
                drive.remove(node)

    def stats(self):
        def per_provider(value):
            return {provider: value(provider) for provider in PROVIDERS}

        return {
            "requests": dict(self.requests),
            "refreshes": dict(self.refreshes),
            "items": per_provider(lambda p: len(self.drives[p].nodes) - 1),
            "bytes": per_provider(lambda p: sum(n.size for n in self.drives[p].nodes.values())),
            "uploads": per_provider(
                lambda p: sum(1 for u in self.uploads.values() if u.provider == p and u.result is None)),
            "throttle": dict(self.throttle),
            "tokens": {"access": len(self.tokens.access), "refresh": len(self.tokens.refresh)},
            "config": {"token_lifetime": TOKEN_LIFETIME, "rotation_grace": ROTATION_GRACE,
                       "page_size": PAGE_SIZE},
        }


STATE = State()


def find_upload(provider, upload_id):
    with STATE.lock:
        upload = STATE.uploads.get(upload_id)
    return upload if upload is not None and upload.provider == provider else None


def take_upload(upload):
    """Unregisters a finished upload; False when a reset or expiry dropped it first."""
    return STATE.uploads.pop(upload.id, None) is upload


# MARK: - Dropbox

DROPBOX_ACCOUNT = {
    "account_id": "dbid:AADE2EHamasenMockAccount000000000000",
    "name": {"given_name": "Hamasen", "surname": "E2E", "familiar_name": "Hamasen",
             "display_name": DISPLAY_NAME, "abbreviated_name": "HE"},
    "email": EMAIL, "email_verified": True, "disabled": False, "locale": "en", "country": "TW",
    "is_paired": False, "account_type": {".tag": "basic"},
    "root_info": {".tag": "user", "root_namespace_id": "1", "home_namespace_id": "1"},
}
DROPBOX_UPLOAD_ROUTES = (
    "files/upload", "files/upload_session/start", "files/upload_session/append_v2",
    "files/upload_session/finish",
)


def dropbox_error(summary, **details):
    """An endpoint-specific failure: 409, a summary such as "path/not_found/.."
    and the same tags as nested unions."""
    tags = summary.split("/")
    error = {".tag": tags[-1], **details}
    for tag in reversed(tags[:-1]):
        error = {".tag": tag, tag: error}
    return Fail(json_reply({"error_summary": summary + "/..", "error": error}, 409))


def dropbox_bad(route, message):
    """A malformed call: 400 with plain text, as Dropbox answers it."""
    return Fail(text_reply(f'Error in call to API function "{route}": {message}', 400))


def dropbox_names(route, value, tag, root_allowed=False):
    """A Dropbox path as names below the root, which Dropbox calls ""."""
    if not isinstance(value, str):
        raise dropbox_bad(route, f"request body: {tag}: expected string")
    if value == "":
        if root_allowed:
            return []
        raise dropbox_bad(route, f"request body: {tag}: The root folder is unsupported.")
    if value == "/":
        raise dropbox_bad(route, f'request body: {tag}: Specify the root folder as an empty string rather than as "/".')
    if not value.startswith("/"):
        raise dropbox_bad(route, f"request body: {tag}: '{value}' did not match pattern '(/(.|[\\r\\n])*)|(ns:[0-9]+(/.*)?)|(id:.*)'")
    names = value[1:].split("/")
    if "" in names:
        raise dropbox_error(f"{tag}/malformed_path")
    return names


def dropbox_time(route, value):
    if value is None:
        return None
    try:
        return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        raise dropbox_bad(route, "request body: client_modified: expected a timestamp like 2015-05-12T15:50:38Z")


def dropbox_metadata(drive, node):
    display = "/" + "/".join(drive.names(node))
    meta = {".tag": "folder" if node.folder else "file", "name": node.name, "id": node.id,
            "path_lower": display.lower(), "path_display": display}
    if not node.folder:
        meta.update({
            "client_modified": iso(node.client_modified, millis=False),
            "server_modified": iso(node.modified, millis=False),
            "rev": node.rev, "size": node.size, "is_downloadable": True,
            "content_hash": node.digests["dropbox"],
        })
    return meta


def dropbox_page(drive, folder, offset, limit, recursive):
    entries = list(drive.descendants(folder)) if recursive else drive.sorted_children(folder)
    page = entries[offset:offset + min(limit, PAGE_SIZE)]
    end = offset + len(page)
    return json_reply({
        "entries": [dropbox_metadata(drive, n) for n in page],
        "cursor": encode_token({"folder": folder.id, "offset": end, "limit": limit, "recursive": recursive}),
        "has_more": end < len(entries),
    })


def dropbox_account(route, args, drive):
    return json_reply(DROPBOX_ACCOUNT)


def dropbox_list_folder(route, args, drive):
    names = dropbox_names(route, args.get("path"), "path", root_allowed=True)
    limit = args.get("limit", 2000)
    if not isinstance(limit, int) or not 1 <= limit <= 2000:
        raise dropbox_bad(route, "request body: limit: expected an integer from 1 to 2000")
    folder = drive.walk(names)
    if folder is None:
        raise dropbox_error("path/not_found")
    if not folder.folder:
        raise dropbox_error("path/not_folder")
    return dropbox_page(drive, folder, 0, limit, bool(args.get("recursive")))


def dropbox_list_folder_continue(route, args, drive):
    try:
        cursor = decode_token(args.get("cursor"))
        folder_id, offset, limit, recursive = cursor["folder"], cursor["offset"], cursor["limit"], cursor["recursive"]
    except (ValueError, TypeError, KeyError):
        raise dropbox_bad(route, "request body: cursor: invalid cursor")
    folder = drive.nodes.get(folder_id)
    if folder is None:
        raise dropbox_error("reset")
    return dropbox_page(drive, folder, offset, limit, recursive)


def dropbox_get_metadata(route, args, drive):
    node = drive.walk(dropbox_names(route, args.get("path"), "path"))
    if node is None:
        raise dropbox_error("path/not_found")
    return json_reply(dropbox_metadata(drive, node))


def dropbox_create_folder(route, args, drive):
    names = dropbox_names(route, args.get("path"), "path")
    existing = drive.walk(names)
    if existing is not None and not args.get("autorename"):
        raise dropbox_error("path/conflict/" + ("folder" if existing.folder else "file"))
    # Dropbox creates missing parent folders along the way.
    parent = drive.make_folders(names[:-1])
    if parent is None:
        raise dropbox_error("path/conflict/file")
    name = names[-1] if existing is None else free_name(drive, parent, names[-1], True, "{base} ({n}){ext}")
    return json_reply({"metadata": dropbox_metadata(drive, drive.add(parent, name, True))})


def dropbox_delete(route, args, drive):
    node = drive.walk(dropbox_names(route, args.get("path"), "path_lookup"))
    if node is None:
        raise dropbox_error("path_lookup/not_found")
    meta = dropbox_metadata(drive, node)
    drive.remove(node)
    return json_reply({"metadata": meta})


def dropbox_move(route, args, drive):
    source = dropbox_names(route, args.get("from_path"), "from_lookup")
    target = dropbox_names(route, args.get("to_path"), "to")
    node = drive.walk(source)
    if node is None:
        raise dropbox_error("from_lookup/not_found")
    lowered = [n.lower() for n in target]
    if len(target) > len(source) and lowered[:len(source)] == [n.lower() for n in source]:
        raise dropbox_error("cant_move_folder_into_itself")
    existing = drive.walk(target)
    # The same item under another case is a rename, not a conflict.
    if existing is not None and (existing is not node or target == source) and not args.get("autorename"):
        raise dropbox_error("to/conflict/" + ("folder" if existing.folder else "file"))
    parent = drive.make_folders(target[:-1])
    if parent is None:
        raise dropbox_error("to/conflict/file")
    name = target[-1]
    if existing is not None and existing is not node:
        name = free_name(drive, parent, name, node.folder, "{base} ({n}){ext}")
    drive.move(node, parent, name)
    return json_reply({"metadata": dropbox_metadata(drive, node)})


def dropbox_search(route, args, drive):
    query = args.get("query")
    if not isinstance(query, str) or not query.strip():
        raise dropbox_bad(route, "request body: query: expected a non-empty string")
    options = args.get("options") or {}
    names = dropbox_names(route, options.get("path", ""), "path", root_allowed=True)
    limit = options.get("max_results", 100)
    if not isinstance(limit, int) or not 1 <= limit <= 1000:
        raise dropbox_bad(route, "request body: options.max_results: expected an integer from 1 to 1000")
    scope = drive.walk(names)
    if scope is None:
        raise dropbox_error("path/not_found")
    if not scope.folder:
        raise dropbox_error("path/not_folder")
    terms = query.lower().split()
    found = [n for n in drive.descendants(scope) if all(t in n.name.lower() for t in terms)]
    return json_reply({
        "matches": [{"match_type": {".tag": "filename"},
                     "metadata": {".tag": "metadata", "metadata": dropbox_metadata(drive, n)}}
                    for n in found[:limit]],
        "has_more": len(found) > limit,
    })


DROPBOX_RPC = {
    "users/get_current_account": dropbox_account,
    "files/list_folder": dropbox_list_folder,
    "files/list_folder/continue": dropbox_list_folder_continue,
    "files/get_metadata": dropbox_get_metadata,
    "files/create_folder_v2": dropbox_create_folder,
    "files/delete_v2": dropbox_delete,
    "files/move_v2": dropbox_move,
    "files/search_v2": dropbox_search,
}


def dropbox_api(request):
    if not request.path.startswith("/2/"):
        return text_reply("Not Found", 404)
    route = request.path[3:]
    handler = DROPBOX_RPC.get(route)
    if handler is None:
        return text_reply(f'Unknown API function: "{route}"', 404)
    media = request.media_type()
    raw = request.body.read_all(MAX_JSON_BODY)
    if not media and not raw.strip():
        args = None
    elif media not in ("application/json", "text/plain"):
        raise dropbox_bad(route, f'Bad HTTP "Content-Type" header: "{media}".  Expecting one of '
                                 '"application/json", "application/json; charset=utf-8", '
                                 '"text/plain; charset=dropbox-cors-hack".')
    else:
        try:
            args = json.loads(raw)
        except ValueError:
            raise dropbox_bad(route, "request body: could not decode input as JSON")
    if handler is not dropbox_account and not isinstance(args, dict):
        raise dropbox_bad(route, "request body: expected an object")
    with STATE.lock:
        return handler(route, args or {}, STATE.drives["dropbox"])


def dropbox_content(request):
    if not request.path.startswith("/2/"):
        return text_reply("Not Found", 404)
    route = request.path[3:]
    header = request.header("Dropbox-API-Arg")
    raw = header if header is not None else request.query.get("arg")
    if raw is None:
        raise dropbox_bad(route, 'Must provide HTTP header "Dropbox-API-Arg" or URL parameter "arg".')
    # An HTTP header is ASCII; Dropbox wants anything else as \u escapes.
    if header is not None and not header.isascii():
        raise dropbox_bad(route, 'HTTP header "Dropbox-API-Arg": could not decode input as JSON')
    try:
        args = json.loads(raw)
    except ValueError:
        raise dropbox_bad(route, 'HTTP header "Dropbox-API-Arg": could not decode input as JSON')
    if not isinstance(args, dict):
        raise dropbox_bad(route, 'HTTP header "Dropbox-API-Arg": expected an object')
    if route == "files/download":
        return dropbox_download(request, route, args)
    if route not in DROPBOX_UPLOAD_ROUTES:
        return text_reply(f'Unknown API function: "{route}"', 404)
    if request.media_type() not in ("application/octet-stream", "text/plain"):
        raise dropbox_bad(route, f'Bad HTTP "Content-Type" header: "{request.media_type()}".  Expecting one of '
                                 '"application/octet-stream", "text/plain; charset=dropbox-cors-hack".')
    if route == "files/upload":
        staged = stage(request.body)
        try:
            with STATE.lock:
                return dropbox_commit(route, args, staged)
        finally:
            staged.discard()
    if route == "files/upload_session/start":
        upload = Upload("dropbox")
        upload.append(request.body)
        upload.closed = bool(args.get("close"))
        with STATE.lock:
            STATE.uploads[upload.id] = upload
        return json_reply({"session_id": upload.id})
    return dropbox_session(request, route, args)


def dropbox_download(request, route, args):
    names = dropbox_names(route, args.get("path"), "path")
    with STATE.lock:
        drive = STATE.drives["dropbox"]
        node = drive.walk(names)
        if node is None:
            raise dropbox_error("path/not_found")
        if node.folder:
            raise dropbox_error("path/not_file")
        result = json.dumps(dropbox_metadata(drive, node))  # ASCII, as a header must be
        stream, size = drive.open(node)
    return ranged_reply(request, stream, size,
                        [("Content-Type", "application/octet-stream"), ("Dropbox-API-Result", result)])


def dropbox_session(request, route, args):
    """upload_session/append_v2 and upload_session/finish."""
    finish = route.endswith("finish")
    cursor = args.get("cursor")
    if not isinstance(cursor, dict) or not isinstance(cursor.get("session_id"), str) \
            or not isinstance(cursor.get("offset"), int):
        raise dropbox_bad(route, "request body: cursor: expected session_id and offset")
    lookup = "lookup_failed/" if finish else ""
    upload = find_upload("dropbox", cursor["session_id"])
    if upload is None:
        raise dropbox_error(lookup + "not_found")
    with upload.lock:
        if upload.closed and not finish:
            raise dropbox_error("closed")
        if cursor["offset"] != upload.size:
            raise dropbox_error(lookup + "incorrect_offset", correct_offset=upload.size)
        if upload.append(request.body) is None:
            raise dropbox_error(lookup + "not_found")
        if not finish:
            upload.closed = bool(args.get("close"))
            return json_reply(None)
        staged = upload.staged()
        with STATE.lock:
            try:
                if not take_upload(upload):
                    raise dropbox_error("lookup_failed/not_found")
                return dropbox_commit(route, args.get("commit") or {}, staged)
            finally:
                staged.discard()


def dropbox_commit(route, commit, staged):
    """Puts uploaded content at commit["path"] the way the commit's mode says."""
    drive = STATE.drives["dropbox"]
    names = dropbox_names(route, commit.get("path"), "path")
    mode = commit.get("mode", "add")
    tag = mode if isinstance(mode, str) else (mode or {}).get(".tag")
    if tag not in ("add", "overwrite", "update"):
        raise dropbox_bad(route, "request body: mode: expected add, overwrite or update")
    client_modified = dropbox_time(route, commit.get("client_modified"))
    existing = drive.walk(names)
    if existing is not None and not existing.folder and not commit.get("strict_conflict") \
            and existing.digests == staged.digests:
        # The same content again is no conflict, and no new revision.
        return json_reply(dropbox_metadata(drive, existing))
    replace = existing is not None and not existing.folder and (
        tag == "overwrite" or (tag == "update" and mode.get("update") == existing.rev))
    if existing is not None and not replace and not commit.get("autorename"):
        raise dropbox_error("path/conflict/" + ("folder" if existing.folder else "file"))
    parent = drive.make_folders(names[:-1])
    if parent is None:
        raise dropbox_error("path/conflict/file")
    if replace:
        node = existing
    else:
        name = names[-1] if existing is None else free_name(drive, parent, names[-1], False, "{base} ({n}){ext}")
        node = drive.add(parent, name, False)
    drive.set_content(node, staged)
    node.client_modified = client_modified or node.modified
    return json_reply(dropbox_metadata(drive, node))


# MARK: - Microsoft Graph

GRAPH_ME = {
    "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users/$entity",
    "id": "e2e0c1d0-0000-4000-8000-0000000000e2", "displayName": DISPLAY_NAME,
    "givenName": "Hamasen", "surname": "E2E", "userPrincipalName": EMAIL, "mail": EMAIL,
}


def graph_error(status, code, message, headers=()):
    inner = {"date": iso(time.time(), millis=False), "request-id": str(uuid.uuid4()),
             "client-request-id": str(uuid.uuid4())}
    return Fail(json_reply({"error": {"code": code, "message": message, "innerError": inner}}, status, headers))


def graph_not_found():
    return graph_error(404, "itemNotFound", "The resource could not be found.")


def graph_body(request):
    try:
        body = request.json()
    except ValueError:
        raise graph_error(400, "invalidRequest", "Unable to read JSON request payload. Please ensure "
                                                 "Content-Type header is set and payload is of valid JSON format.")
    if not isinstance(body, dict):
        raise graph_error(400, "invalidRequest", "The request body must be a JSON object.")
    return body


def graph_check_name(name):
    if not isinstance(name, str) or not name or name != name.strip() or name in (".", "..") \
            or any(c in GRAPH_INVALID_CHARACTERS for c in name):
        raise graph_error(400, "invalidRequest", 'The provided name cannot have leading or trailing spaces, '
                                                 'or contain any of these characters: " * : < > ? / \\ |')


def graph_behavior(value):
    if value not in ("fail", "replace", "rename"):
        raise graph_error(400, "invalidRequest", f"Invalid conflict behavior '{value}'.")
    return value


def graph_select(request, value):
    fields = request.query.get("$select")
    if not fields:
        return value
    keys = [f.strip() for f in fields.split(",") if f.strip()]
    return {k: value[k] for k in keys if k in value}


def graph_item(drive, node):
    item = {
        "id": node.id, "name": node.name,
        "eTag": f'"{{{node.id}}},{node.version}"', "cTag": f'"c:{{{node.id}}},{node.content_version}"',
        "createdDateTime": iso(node.created), "lastModifiedDateTime": iso(node.modified),
        "size": sum(n.size for n in drive.descendants(node)) if node.folder else node.size,
        "fileSystemInfo": {"createdDateTime": iso(node.created), "lastModifiedDateTime": iso(node.modified)},
        "parentReference": {"driveId": GRAPH_DRIVE_ID, "driveType": "personal"},
    }
    if node is drive.root:
        item["root"] = {}
    else:
        path = "".join("/" + quote(name, safe="") for name in drive.names(node.parent))
        item["parentReference"].update(id=node.parent.id, path="/drive/root:" + path)
    if node.folder:
        item["folder"] = {"childCount": len(node.children)}
    else:
        item["file"] = {"mimeType": node.mime, "hashes": {"sha1Hash": node.digests["sha1"].upper(),
                                                          "sha256Hash": node.digests["sha256"].upper()}}
    return item


def graph_node(drive, names, item_id):
    if names is not None:
        node = drive.walk(names)
    else:
        node = drive.root if item_id == "root" else drive.nodes.get(item_id)
    if node is None:
        raise graph_not_found()
    return node


def graph_page(request, drive, nodes):
    """One page of items, with an @odata.nextLink to the next one."""
    try:
        top = int(request.query.get("$top", "200"))
        offset = decode_token(request.query["$skiptoken"])["offset"] if "$skiptoken" in request.query else 0
        if top < 1 or not isinstance(offset, int):
            raise ValueError(top)
    except (ValueError, TypeError, KeyError):
        raise graph_error(400, "invalidRequest", "Invalid $top or $skiptoken.")
    end = offset + min(top, PAGE_SIZE)
    body = {"value": [graph_select(request, graph_item(drive, n)) for n in nodes[offset:end]]}
    if end < len(nodes):
        # The same request, raw path and all, asking for the next page.
        kept = [p for p in request.raw_query.split("&") if p and unquote(p.split("=", 1)[0]) != "$skiptoken"]
        kept.append("$skiptoken=" + encode_token({"offset": end}))
        body["@odata.nextLink"] = "https://graph.microsoft.com" + request.path + "?" + "&".join(kept)
    return json_reply(body)


def graph_place(drive, names, item_id, behavior):
    """The node an upload's bytes go to, and whether it is new."""
    if names is None:
        node = graph_node(drive, None, item_id)
        if node.folder:
            raise graph_error(400, "invalidRequest", "A folder has no content to replace.")
        return node, False
    if not names:
        raise graph_error(400, "invalidRequest", "The root folder has no content.")
    for name in names:
        graph_check_name(name)
    existing = drive.walk(names)
    if existing is not None:
        if behavior == "replace" and not existing.folder:
            return existing, False
        if behavior != "rename":
            raise graph_error(409, "nameAlreadyExists", "The specified item name already exists.")
    # Graph creates missing parent folders of a path it uploads to.
    parent = drive.make_folders(names[:-1])
    if parent is None:
        raise graph_error(409, "nameAlreadyExists", "A file has the name of a folder on this path.")
    name = names[-1] if existing is None else free_name(drive, parent, names[-1], False, "{base} {n}{ext}")
    return drive.add(parent, name, False), True


def graph_get_item(request, drive, names, item_id):
    with STATE.lock:
        return json_reply(graph_select(request, graph_item(drive, graph_node(drive, names, item_id))))


def graph_list_children(request, drive, names, item_id):
    with STATE.lock:
        return graph_page(request, drive, drive.sorted_children(graph_node(drive, names, item_id)))


def graph_download(request, drive, names, item_id):
    """/content redirects to a pre-signed URL on another host, which must
    be fetched without the account's token."""
    with STATE.lock:
        node = graph_node(drive, names, item_id)
        if node.folder:
            raise graph_error(400, "invalidRequest", "A folder has no content to download.")
    expires = int(time.time()) + CONTENT_URL_SECONDS
    location = (f"https://graph-content.mock/download/{quote(node.id, safe='')}"
                f"?expires={expires}&sig={content_signature(node.id, expires)}")
    return Reply(302, [("Location", location)])


def content_signature(item_id, expires):
    return hmac.new(SIGNING_KEY, f"{item_id}|{expires}".encode(), hashlib.sha256).hexdigest()[:32]


def graph_put_content(request, drive, names, item_id):
    behavior = graph_behavior(request.query.get("@microsoft.graph.conflictBehavior", "replace"))
    staged = stage(request.body)
    try:
        with STATE.lock:
            node, created = graph_place(drive, names, item_id, behavior)
            drive.set_content(node, staged)
            return json_reply(graph_item(drive, node), 201 if created else 200)
    finally:
        staged.discard()


def graph_create_upload_session(request, drive, names, item_id):
    item = graph_body(request).get("item") or {}
    if not isinstance(item, dict):
        raise graph_error(400, "invalidRequest", "item must be an object.")
    behavior = graph_behavior(item.get("@microsoft.graph.conflictBehavior", "replace"))
    with STATE.lock:
        if names is None:
            graph_place(drive, None, item_id, behavior)
        elif not names:
            raise graph_error(400, "invalidRequest", "The root folder has no content.")
        else:
            for name in names:
                graph_check_name(name)
            existing = drive.walk(names)
            if existing is not None and (behavior == "fail" or (existing.folder and behavior == "replace")):
                raise graph_error(409, "nameAlreadyExists", "The specified item name already exists.")
        upload = Upload("microsoft", names=names, item_id=item_id, behavior=behavior)
        if isinstance(item.get("fileSize"), int):
            upload.total = item["fileSize"]
        STATE.uploads[upload.id] = upload
    return json_reply({
        "uploadUrl": f"https://graph-upload.mock/session/{upload.id}",
        "expirationDateTime": iso(upload.touched + UPLOAD_IDLE_SECONDS),
        "nextExpectedRanges": ["0-"],
    })


def graph_create_folder(request, drive, names, item_id):
    body = graph_body(request)
    name = body.get("name")
    graph_check_name(name)
    if not isinstance(body.get("folder"), dict):
        raise graph_error(400, "invalidRequest", "Only folders are created this way; upload files with PUT .../content.")
    behavior = graph_behavior(body.get("@microsoft.graph.conflictBehavior", "fail"))
    with STATE.lock:
        parent = graph_node(drive, names, item_id)
        if not parent.folder:
            raise graph_error(400, "invalidRequest", "The parent item is not a folder.")
        existing = drive.child(parent, name)
        if existing is not None:
            if behavior == "fail":
                raise graph_error(409, "nameAlreadyExists", "The specified item name already exists.")
            if behavior == "replace":
                drive.remove(existing)
            else:
                name = free_name(drive, parent, name, True, "{base} {n}{ext}")
        return json_reply(graph_item(drive, drive.add(parent, name, True)), 201)


def graph_delete(request, drive, names, item_id):
    with STATE.lock:
        node = graph_node(drive, names, item_id)
        if node is drive.root:
            raise graph_error(403, "accessDenied", "The root folder cannot be deleted.")
        drive.remove(node)
    return Reply(204)


def graph_update(request, drive, names, item_id):
    """PATCH: rename, move by destination ID, or both."""
    body = graph_body(request)
    behavior = graph_behavior(request.query.get("@microsoft.graph.conflictBehavior")
                              or body.get("@microsoft.graph.conflictBehavior") or "fail")
    with STATE.lock:
        node = graph_node(drive, names, item_id)
        if node is drive.root:
            raise graph_error(403, "accessDenied", "The root folder cannot be renamed or moved.")
        parent = node.parent
        reference = body.get("parentReference")
        if isinstance(reference, dict) and "id" in reference:
            parent = drive.root if reference["id"] == "root" else drive.nodes.get(reference["id"])
            if parent is None:
                raise graph_not_found()
            if not parent.folder:
                raise graph_error(400, "invalidRequest", "The destination is not a folder.")
            if drive.contains(node, parent):
                raise graph_error(400, "invalidRequest", "An item cannot be moved into itself or its descendants.")
        name = body.get("name", node.name)
        graph_check_name(name)
        clash = drive.child(parent, name)
        if clash is not None and clash is not node:
            if behavior == "fail":
                raise graph_error(409, "nameAlreadyExists", "An item with the same name already exists under the parent.")
            if behavior == "replace":
                drive.remove(clash)
            else:
                name = free_name(drive, parent, name, node.folder, "{base} {n}{ext}")
        drive.move(node, parent, name)
        return json_reply(graph_select(request, graph_item(drive, node)))


GRAPH_ITEM_ACTIONS = {
    ("GET", ""): graph_get_item,
    ("GET", "/children"): graph_list_children,
    ("GET", "/content"): graph_download,
    ("PUT", "/content"): graph_put_content,
    ("POST", "/createUploadSession"): graph_create_upload_session,
    ("POST", "/children"): graph_create_folder,
    ("DELETE", ""): graph_delete,
    ("PATCH", ""): graph_update,
}


def graph_search(request, drive, segment):
    match = re.fullmatch(r"/search\(q='(.*)'\)", unquote(segment))
    if not match:
        raise graph_error(400, "invalidRequest", "Invalid search request.")
    terms = match[1].replace("''", "'").lower().split()
    with STATE.lock:
        found = [n for n in drive.descendants(drive.root) if terms and all(t in n.name.lower() for t in terms)]
        return graph_page(request, drive, found)


def graph(request):
    if not request.path.startswith("/v1.0/"):
        raise graph_error(400, "BadRequest", "Invalid version.")
    rest = request.path[len("/v1.0"):]
    drive = STATE.drives["microsoft"]
    if rest == "/me" and request.method == "GET":
        return json_reply(graph_select(request, GRAPH_ME))
    if rest == "/me/drive" and request.method == "GET":
        with STATE.lock:
            used = sum(n.size for n in drive.nodes.values())
        return json_reply(graph_select(request, {
            "id": GRAPH_DRIVE_ID, "driveType": "personal",
            "owner": {"user": {"displayName": DISPLAY_NAME, "id": GRAPH_ME["id"]}},
            "quota": {"total": 1 << 40, "used": used, "remaining": (1 << 40) - used, "deleted": 0, "state": "normal"},
        }))
    names, item_id, suffix = None, None, None
    if rest.startswith("/me/drive/root"):
        after = rest[len("/me/drive/root"):]
        if after.startswith("/search("):
            return graph_search(request, drive, after)
        if after.startswith(":"):
            # root:/a/b:/children: each segment percent-encoded, so a ":" in
            # a name cannot end the path early.
            raw, _, suffix = after[1:].partition(":")
            names = [unquote(segment) for segment in raw.split("/") if segment]
        else:
            names, suffix = [], after
    else:
        match = re.fullmatch(r"/me/drive/items/([^/:]+)(.*)", rest)
        if match:
            item_id, suffix = unquote(match[1]), match[2]
    action = GRAPH_ITEM_ACTIONS.get((request.method, suffix))
    if action is None:
        raise graph_error(400, "invalidRequest", f"Unsupported request: {request.method} {rest}")
    return action(request, drive, names, item_id)


def graph_upload_host(request):
    """The pre-signed upload session URL createUploadSession hands out."""
    if request.header("Authorization") is not None:
        raise graph_error(401, "unauthenticated",
                          "The upload URL is pre-authenticated and does not accept an Authorization header.")
    match = re.fullmatch(r"/session/([\w-]+)", request.path)
    upload = find_upload("microsoft", match[1]) if match else None
    if upload is None:
        raise graph_error(404, "itemNotFound", "The upload session does not exist or has expired.")
    if request.method == "GET":
        return json_reply({"expirationDateTime": iso(upload.touched + UPLOAD_IDLE_SECONDS),
                           "nextExpectedRanges": [f"{upload.size}-"]})
    if request.method == "DELETE":
        with STATE.lock:
            if take_upload(upload):
                unlink(upload.path)
        return Reply(204)
    if request.method != "PUT":
        raise graph_error(405, "invalidRequest", "Upload fragments are sent with PUT.")
    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", (request.header("Content-Range") or "").strip())
    if not match:
        raise graph_error(400, "invalidRequest", "The Content-Range header is missing or malformed.")
    start, end, total = (int(n) for n in match.groups())
    with upload.lock:
        if upload.total is None:
            upload.total = total
        if total != upload.total or end < start or end >= total:
            raise graph_error(400, "invalidRequest", "The Content-Range header does not match the upload session.")
        if start != upload.size:
            raise graph_error(416, "invalidRange", f"The fragment starts at {start}; the next expected byte is {upload.size}.")
        if end + 1 < total and (end - start + 1) % GRAPH_FRAGMENT:
            raise graph_error(400, "invalidRequest", "Every fragment but the last must be a multiple of 320 KiB.")
        written = upload.append(request.body)
        if written is None:
            raise graph_error(404, "itemNotFound", "The upload session does not exist or has expired.")
        if written != end - start + 1:
            upload.truncate(start)
            raise graph_error(400, "invalidRequest", "The fragment's length does not match its Content-Range.")
        if upload.size < total:
            return json_reply({"expirationDateTime": iso(upload.touched + UPLOAD_IDLE_SECONDS),
                               "nextExpectedRanges": [f"{upload.size}-"]}, 202)
        staged = upload.staged()
        drive = STATE.drives["microsoft"]
        with STATE.lock:
            try:
                if not take_upload(upload):
                    raise graph_error(404, "itemNotFound", "The upload session does not exist or has expired.")
                node, created = graph_place(drive, upload.info["names"], upload.info["item_id"], upload.info["behavior"])
                drive.set_content(node, staged)
                return json_reply(graph_item(drive, node), 201 if created else 200)
            finally:
                staged.discard()


def graph_content_host(request):
    """The pre-signed download URL /content redirects to."""
    if request.header("Authorization") is not None:
        raise graph_error(401, "unauthenticated",
                          "The download URL is pre-authenticated and does not accept an Authorization header.")
    match = re.fullmatch(r"/download/([^/]+)", request.path)
    expires = request.query.get("expires", "")
    if request.method != "GET" or not match or not expires.isdigit() or int(expires) < time.time() \
            or not hmac.compare_digest(request.query.get("sig", ""), content_signature(unquote(match[1]), int(expires))):
        raise graph_error(401, "unauthenticated", "The download URL is invalid or has expired.")
    with STATE.lock:
        drive = STATE.drives["microsoft"]
        node = drive.nodes.get(unquote(match[1]))
        if node is None:
            raise graph_not_found()
        stream, size = drive.open(node)
        mime = node.mime
    return ranged_reply(request, stream, size, [("Content-Type", mime)])


# MARK: - Google Drive

GOOGLE_FILE_FIELDS = frozenset("""
    kind id name mimeType description starred trashed explicitlyTrashed trashedTime trashingUser
    parents properties appProperties spaces version webContentLink webViewLink iconLink
    hasThumbnail thumbnailLink thumbnailVersion viewedByMe viewedByMeTime createdTime
    modifiedTime modifiedByMeTime modifiedByMe sharedWithMeTime sharingUser owners teamDriveId
    driveId lastModifyingUser shared ownedByMe capabilities viewersCanCopyContent
    copyRequiresWriterPermission writersCanShare permissions permissionIds
    hasAugmentedPermissions folderColorRgb originalFilename fullFileExtension fileExtension
    md5Checksum sha1Checksum sha256Checksum size quotaBytesUsed headRevisionId contentHints
    imageMediaMetadata videoMediaMetadata isAppAuthorized exportLinks shortcutDetails
    contentRestrictions resourceKey linkShareMetadata labelInfo inheritedPermissionsDisabled
    downloadRestrictions
""".split())
GOOGLE_LIST_FIELDS = frozenset({"kind", "nextPageToken", "incompleteSearch", "files"})
GOOGLE_ABOUT_FIELDS = frozenset("""
    kind user storageQuota driveThemes canCreateDrives importFormats exportFormats appInstalled
    folderColorPalette maxImportSizes maxUploadSize teamDriveThemes canCreateTeamDrives
""".split())
GOOGLE_FILE_DEFAULT = "kind,id,name,mimeType"
GOOGLE_LIST_DEFAULT = "kind,incompleteSearch,nextPageToken,files(kind,id,name,mimeType)"
GOOGLE_EXPORTS = {
    "application/vnd.google-apps.document": {
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/pdf",
        "text/plain", "application/rtf", "application/vnd.oasis.opendocument.text", "text/html",
        "application/zip", "application/epub+zip", "text/markdown"},
    "application/vnd.google-apps.spreadsheet": {
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/pdf",
        "text/csv", "text/tab-separated-values", "application/vnd.oasis.opendocument.spreadsheet",
        "application/x-vnd.oasis.opendocument.spreadsheet", "application/zip"},
    "application/vnd.google-apps.presentation": {
        "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/pdf",
        "text/plain", "application/vnd.oasis.opendocument.presentation"},
    "application/vnd.google-apps.drawing": {"application/pdf", "image/png", "image/jpeg", "image/svg+xml"},
}


def google_error(status, reason, message, location=None, domain="global", headers=()):
    error = {"domain": domain, "reason": reason, "message": message}
    if location:
        error.update(location=location, locationType="header" if location == "Authorization" else "parameter")
    return Fail(json_reply({"error": {"code": status, "message": message, "errors": [error]}}, status, headers))


def google_json(request):
    try:
        body = request.json()
    except ValueError:
        raise google_error(400, "parseError", "Parse Error")
    if not isinstance(body, dict):
        raise google_error(400, "badRequest", "The request body must be a JSON object.")
    return body


def google_node(drive, file_id):
    node = drive.root if file_id == "root" else drive.nodes.get(file_id)
    if node is None:
        raise google_error(404, "notFound", f"File not found: {file_id}.", location="fileId")
    return node


FIELD_TOKEN = re.compile(r"\s*([A-Za-z0-9_*]+|[(),/])")


def parse_fields(text):
    """Google's partial-response syntax, such as
    "nextPageToken,files(id,capabilities(canEdit))", as nested dicts in
    which None selects a field whole. Raises ValueError."""
    tokens, position = [], 0
    while text[position:].strip():
        match = FIELD_TOKEN.match(text, position)
        if not match:
            raise ValueError(text)
        tokens.append(match[1])
        position = match.end()
    mask, position = parse_field_list(tokens, 0)
    if position != len(tokens):
        raise ValueError(text)
    return mask


def parse_field_list(tokens, position):
    mask = {}
    while True:
        path = []
        while True:
            if position >= len(tokens) or tokens[position] in "(),/":
                raise ValueError(tokens)
            path.append(tokens[position])
            position += 1
            if position < len(tokens) and tokens[position] == "/":
                position += 1
                continue
            break
        selection = None
        if position < len(tokens) and tokens[position] == "(":
            selection, position = parse_field_list(tokens, position + 1)
            if position >= len(tokens) or tokens[position] != ")":
                raise ValueError(tokens)
            position += 1
        node = mask
        for name in path[:-1]:
            node = node.setdefault(name, {})
            if node is None:
                break  # already selected whole
        else:
            node[path[-1]] = selection
        if position < len(tokens) and tokens[position] == ",":
            position += 1
            continue
        return mask, position


def apply_fields(value, mask):
    if mask is None or "*" in mask:
        return value
    if isinstance(value, list):
        return [apply_fields(v, mask) for v in value]
    if isinstance(value, dict):
        return {k: apply_fields(value[k], m) for k, m in mask.items() if k in value}
    return value


def google_fields(request, default, allowed, nested=None):
    """The `fields` mask of a request; Drive refuses one naming a field it does not have."""
    text = request.query.get("fields") or default
    try:
        mask = parse_fields(text)
    except ValueError:
        raise google_error(400, "invalidParameter", f"Invalid field selection {text}", location="fields")

    def check(selection, names, children):
        for name, inner in selection.items():
            if name != "*" and name not in names:
                raise google_error(400, "invalidParameter", f"Invalid field selection {name}", location="fields")
            if inner and name in children:
                check(inner, children[name], {})

    check(mask, allowed, nested or {})
    return mask


def google_file(drive, node):
    is_root = node is drive.root
    item = {
        "kind": "drive#file", "id": node.id, "name": node.name, "mimeType": node.mime,
        "starred": False, "trashed": drive.is_trashed(node), "explicitlyTrashed": node.trashed_at is not None,
        "spaces": ["drive"], "version": str(node.version),
        "createdTime": iso(node.created), "modifiedTime": iso(node.modified),
        "modifiedByMe": True, "modifiedByMeTime": iso(node.modified), "viewedByMe": True,
        "ownedByMe": True, "shared": False,
        "owners": [{"kind": "drive#user", "displayName": DISPLAY_NAME, "me": True, "emailAddress": EMAIL}],
        "capabilities": {
            "canEdit": True, "canRename": not is_root, "canDelete": not is_root, "canTrash": not is_root,
            "canUntrash": not is_root, "canDownload": True, "canMoveItemWithinDrive": not is_root,
            "canAddChildren": node.folder, "canListChildren": node.folder, "canRemoveChildren": node.folder,
            "canCopy": not node.folder, "canModifyContent": True, "canShare": True,
        },
    }
    if node.parent is not None:
        item["parents"] = [node.parent.id]
    if node.trashed_at is not None:
        item["trashedTime"] = iso(node.trashed_at)
    if not node.mime.startswith(GOOGLE_TYPE_PREFIX):
        extension = os.path.splitext(node.name)[1][1:]
        item.update({
            "size": str(node.size), "quotaBytesUsed": str(node.size), "originalFilename": node.name,
            "md5Checksum": node.digests["md5"], "sha1Checksum": node.digests["sha1"],
            "sha256Checksum": node.digests["sha256"], "headRevisionId": node.rev,
        })
        if extension:
            item.update(fileExtension=extension, fullFileExtension=extension)
    if node.mime == SHORTCUT_MIME:
        target = drive.nodes.get(node.target[0])
        item["shortcutDetails"] = {"targetId": node.target[0],
                                   "targetMimeType": target.mime if target else node.target[1]}
    return item


QUERY_TOKEN = re.compile(r"\s*(?:'((?:[^'\\]|\\.)*)'|(!=|<=|>=|=|<|>)|([A-Za-z]+))")


def parse_query(text):
    """Drive's search syntax, as much as a file browser uses: terms joined by
    "and" — '<id>' in parents, trashed, and name, mimeType or fullText
    comparisons. Returns the parent IDs named and a predicate per other term.
    Raises ValueError."""
    tokens, position = [], 0
    while text[position:].strip():
        match = QUERY_TOKEN.match(text, position)
        if not match:
            raise ValueError(text)
        if match[1] is not None:
            tokens.append(("string", re.sub(r"\\(.)", r"\1", match[1])))
        elif match[2]:
            tokens.append(("operator", match[2]))
        else:
            tokens.append(("word", match[3]))
        position = match.end()
    parents, predicates = [], []
    position = 0
    while position < len(tokens):
        if position + 3 > len(tokens):
            raise ValueError(text)
        first, second, third = tokens[position:position + 3]
        if first[0] == "string" and second == ("word", "in") and third == ("word", "parents"):
            parents.append(first[1])
        elif first[0] == "word" and first[1] in ("name", "mimeType", "fullText", "trashed"):
            predicates.append(query_predicate(first[1], second, third))
        else:
            raise ValueError(text)
        position += 3
        if position < len(tokens):
            if tokens[position] != ("word", "and") or position + 1 == len(tokens):
                raise ValueError(text)
            position += 1
    return parents, predicates


def query_predicate(field, operator, operand):
    operator = operator[1] if operator[0] == "operator" else operator[1].lower()
    if field == "trashed":
        if operator not in ("=", "!=") or operand[0] != "word" or operand[1].lower() not in ("true", "false"):
            raise ValueError(field)
        wanted = (operand[1].lower() == "true") == (operator == "=")
        return lambda drive, node: drive.is_trashed(node) == wanted
    if operand[0] != "string":
        raise ValueError(field)
    value = operand[1]
    attribute = (lambda node: node.mime) if field == "mimeType" else (lambda node: node.name)
    if operator == "=" and field != "fullText":
        return lambda drive, node: attribute(node) == value
    if operator == "!=" and field != "fullText":
        return lambda drive, node: attribute(node) != value
    if operator == "contains":
        lowered = value.lower()
        if field == "name":
            # Drive matches a name term by prefix: of the name, or of a word in it.
            return lambda drive, node: node.name.lower().startswith(lowered) or any(
                word.startswith(lowered) for word in re.split(r"\W+", node.name.lower()))
        return lambda drive, node: lowered in attribute(node).lower()
    raise ValueError(field)


def google_about(request, drive):
    if not request.query.get("fields"):
        raise google_error(400, "required", "The 'fields' parameter is required for this method.", location="fields")
    mask = google_fields(request, "", GOOGLE_ABOUT_FIELDS)
    with STATE.lock:
        used = sum(n.size for n in drive.nodes.values())
        trashed = sum(n.size for n in drive.nodes.values() if drive.is_trashed(n))
    about = {
        "kind": "drive#about",
        "user": {"kind": "drive#user", "displayName": DISPLAY_NAME, "me": True,
                 "permissionId": "00000000000000000000", "emailAddress": EMAIL},
        "storageQuota": {"limit": str(15 << 30), "usage": str(used), "usageInDrive": str(used),
                         "usageInDriveTrash": str(trashed)},
        "maxUploadSize": str(5 << 40), "canCreateDrives": False, "appInstalled": False,
    }
    return json_reply(apply_fields(about, mask))


def google_list(request, drive):
    try:
        parents, predicates = parse_query(request.query.get("q", ""))
    except ValueError:
        raise google_error(400, "invalid", "Invalid Value", location="q")
    page_size = request.query.get("pageSize", "100")
    if not page_size.isdigit() or not 1 <= int(page_size) <= 1000:
        raise google_error(400, "invalid", f"Invalid value '{page_size}'. Values must be within the range: [1, 1000]",
                           location="pageSize")
    try:
        offset = decode_token(request.query["pageToken"])["offset"] if "pageToken" in request.query else 0
        if not isinstance(offset, int):
            raise ValueError(offset)
    except (ValueError, TypeError, KeyError):
        raise google_error(400, "invalid", "Invalid Value", location="pageToken")
    mask = google_fields(request, GOOGLE_LIST_DEFAULT, GOOGLE_LIST_FIELDS, {"files": GOOGLE_FILE_FIELDS})
    with STATE.lock:
        if parents:
            folders = [google_node(drive, p) for p in parents]
            candidates = [n for n in drive.sorted_children(folders[0]) if all(n.parent is f for f in folders)]
        else:
            candidates = [n for n in drive.nodes.values() if n is not drive.root]
        matched = sorted((n for n in candidates if all(p(drive, n) for p in predicates)), key=lambda n: n.seq)
        page = matched[offset:offset + min(int(page_size), PAGE_SIZE)]
        body = {"kind": "drive#fileList", "incompleteSearch": False,
                "files": [google_file(drive, n) for n in page]}
        if offset + len(page) < len(matched):
            body["nextPageToken"] = encode_token({"offset": offset + len(page)})
        return json_reply(apply_fields(body, mask))


def google_parent_for_new(drive, meta):
    parents = meta.get("parents") or ["root"]
    if not isinstance(parents, list) or not all(isinstance(p, str) for p in parents):
        raise google_error(400, "invalid", "Invalid value for parents.", location="parents")
    if len(parents) > 1:
        raise google_error(403, "cannotAddParent", "A file can only have one parent folder.")
    parent = google_node(drive, parents[0])
    if not parent.folder:
        raise google_error(400, "badRequest", "The specified parent is not a folder.")
    return parent


def google_create_node(drive, meta, fallback_mime=None):
    parent = google_parent_for_new(drive, meta)
    name = meta.get("name", "Untitled")
    mime = meta.get("mimeType") or fallback_mime
    if not isinstance(name, str) or not isinstance(mime or "", str):
        raise google_error(400, "invalid", "Invalid value for name or mimeType.")
    mime = mime or guess_mime(name)
    target = None
    if mime == SHORTCUT_MIME:
        details = meta.get("shortcutDetails")
        if not isinstance(details, dict) or not details.get("targetId"):
            raise google_error(400, "required", "A shortcut needs shortcutDetails.targetId.")
        target_node = google_node(drive, details["targetId"])
        target = (target_node.id, target_node.mime)
    node = drive.add(parent, name, mime == FOLDER_MIME, mime)
    node.target = target
    return node


def google_create(request, drive):
    meta = google_json(request)
    mask = google_fields(request, GOOGLE_FILE_DEFAULT, GOOGLE_FILE_FIELDS)
    with STATE.lock:
        return json_reply(apply_fields(google_file(drive, google_create_node(drive, meta)), mask))


def google_get(request, drive, file_id):
    if request.query.get("alt") == "media":
        return google_media(request, drive, file_id)
    mask = google_fields(request, GOOGLE_FILE_DEFAULT, GOOGLE_FILE_FIELDS)
    with STATE.lock:
        return json_reply(apply_fields(google_file(drive, google_node(drive, file_id)), mask))


def google_media(request, drive, file_id):
    with STATE.lock:
        node = google_node(drive, file_id)
        if node.folder or node.mime.startswith(GOOGLE_TYPE_PREFIX):
            raise google_error(403, "fileNotDownloadable", "Only files with binary content can be downloaded. "
                                                           "Use Export with Docs Editors files.", location="alt")
        stream, size = drive.open(node)
        mime = node.mime
    return ranged_reply(request, stream, size, [("Content-Type", mime)])


def google_export(request, drive, file_id):
    mime = request.query.get("mimeType")
    if not mime:
        raise google_error(400, "required", "Required parameter: mimeType", location="mimeType")
    with STATE.lock:
        node = google_node(drive, file_id)
        formats = GOOGLE_EXPORTS.get(node.mime)
        if formats is None:
            raise google_error(403, "fileNotExportable", "Export only supports Docs Editors files.")
        if mime not in formats:
            raise google_error(400, "badRequest", "The requested conversion is not supported.", location="convertTo")
        payload = f"EXPORT:{node.name}:{mime}".encode()
    return Reply(200, [("Content-Type", mime)], payload)


def google_update(request, drive, file_id):
    """PATCH: rename, move with addParents/removeParents, trash or restore."""
    meta = google_json(request)
    mask = google_fields(request, GOOGLE_FILE_DEFAULT, GOOGLE_FILE_FIELDS)
    with STATE.lock:
        node = google_node(drive, file_id)
        if node is drive.root:
            raise google_error(403, "insufficientFilePermissions",
                               "The user does not have sufficient permissions for this file.")
        added = [google_node(drive, i) for i in request.query.get("addParents", "").split(",") if i]
        removed = [google_node(drive, i) for i in request.query.get("removeParents", "").split(",") if i]
        parents = [] if node.parent in removed else [node.parent]
        for folder in added:
            if not folder.folder:
                raise google_error(400, "badRequest", "The specified parent is not a folder.")
            if folder not in parents:
                parents.append(folder)
        if len(parents) > 1:
            raise google_error(403, "cannotAddParent", "Increasing the number of parents is not allowed. "
                                                       "Remove the current parent in the same request.")
        if not parents:
            raise google_error(400, "badRequest", "A file must keep one parent folder.")
        if drive.contains(node, parents[0]):
            raise google_error(400, "badRequest", "A folder cannot be moved into itself or one of its descendants.")
        name = meta.get("name", node.name)
        if not isinstance(name, str) or not name:
            raise google_error(400, "invalid", "Invalid value for name.", location="name")
        renamed = name != node.name
        drive.move(node, parents[0], name)
        if renamed:
            node.modified = time.time()
        if "trashed" in meta:
            if not meta["trashed"]:
                node.trashed_at = None
            elif node.trashed_at is None:
                node.trashed_at = time.time()
        return json_reply(apply_fields(google_file(drive, node), mask))


def google_delete(request, drive, file_id):
    with STATE.lock:
        node = google_node(drive, file_id)
        if node is drive.root:
            raise google_error(403, "insufficientFilePermissions",
                               "The user does not have sufficient permissions for this file.")
        drive.remove(node)
    return Reply(204)


def google_empty_trash(request, drive):
    with STATE.lock:
        for node in [n for n in drive.nodes.values() if n.trashed_at is not None]:
            if node.id in drive.nodes:
                drive.remove(node)
    return Reply(204)


def google_upload_start(request, drive, rest):
    """Starts a resumable upload; the session URI goes back in Location."""
    if request.query.get("uploadType") != "resumable":
        raise google_error(400, "badRequest", "Only uploadType=resumable is supported.", location="uploadType")
    match = re.fullmatch(r"/([^/]+)", rest)
    if request.method == "POST" and rest == "":
        file_id = None
    elif request.method == "PATCH" and match:
        file_id = unquote(match[1])
    else:
        raise google_error(404, "notFound", "Not Found")
    meta = google_json(request)
    mask = google_fields(request, GOOGLE_FILE_DEFAULT, GOOGLE_FILE_FIELDS)
    declared = (request.header("X-Upload-Content-Length") or "").strip()
    if declared and not declared.isdigit():
        raise google_error(400, "badRequest", "Invalid X-Upload-Content-Length.")
    with STATE.lock:
        if file_id is None:
            google_parent_for_new(drive, meta)
            if meta.get("mimeType") == FOLDER_MIME:
                raise google_error(400, "badRequest", "A folder has no content to upload.")
        else:
            node = google_node(drive, file_id)
            if node.folder or node.mime.startswith(GOOGLE_TYPE_PREFIX):
                raise google_error(403, "fileNotWritable", "The content of this file cannot be replaced.")
        upload = Upload("google", file_id=file_id, meta=meta, mask=mask,
                        content_type=request.header("X-Upload-Content-Type"))
        upload.total = int(declared) if declared else None
        STATE.uploads[upload.id] = upload
    location = f"https://www.googleapis.com/upload/drive/v3/files{rest}?{request.raw_query}&upload_id={upload.id}"
    return Reply(200, [("Location", location), ("X-GUploader-UploadID", upload.id)])


def google_upload_bytes(request, drive, upload_id):
    """A PUT to the session URI: the whole file, a Content-Range chunk, or a
    status query ("bytes */total"). 308 until every byte is there."""
    upload = find_upload("google", upload_id)
    if upload is None:
        raise google_error(404, "notFound", "The upload session does not exist or has expired.")
    if request.method not in ("PUT", "POST"):
        raise google_error(405, "badRequest", "Upload bytes are sent with PUT.")
    content_range = request.header("Content-Range")
    match = re.fullmatch(r"bytes (?:(\d+)-(\d+)|\*)/(\d+|\*)", (content_range or "").strip())
    if content_range is not None and not match:
        raise google_error(400, "badRequest", "Invalid Content-Range.")
    with upload.lock:
        if upload.result is not None:
            return json_reply(upload.result)
        total = int(match[3]) if match and match[3] != "*" else None
        if total is not None:
            if upload.total is not None and total != upload.total:
                raise google_error(400, "badRequest", "The total size does not match the size declared.")
            upload.total = total
        if content_range is None or match[1] is not None:
            start = int(match[1]) if match else 0
            if start != upload.size:
                raise google_error(400, "badRequest", f"The bytes start at {start}; the session holds {upload.size}.")
            written = upload.append(request.body)
            if written is None:
                raise google_error(404, "notFound", "The upload session does not exist or has expired.")
            if match and written != int(match[2]) - start + 1:
                upload.truncate(start)
                raise google_error(400, "badRequest", "The body does not match its Content-Range.")
            if content_range is None:
                if upload.total is not None and upload.size != upload.total:
                    upload.truncate(0)
                    raise google_error(400, "badRequest", "The body does not match X-Upload-Content-Length.")
                upload.total = upload.size
        if upload.total is None or upload.size < upload.total:
            received = [("Range", f"bytes=0-{upload.size - 1}")] if upload.size else []
            return Reply(308, [*received, ("X-GUploader-UploadID", upload.id)], reason="Resume Incomplete")
        if upload.size > upload.total:
            upload.truncate(0)
            raise google_error(400, "badRequest", "More bytes arrived than the upload declared.")
        staged = upload.staged()
        with STATE.lock:
            try:
                if STATE.uploads.get(upload.id) is not upload:
                    raise google_error(404, "notFound", "The upload session does not exist or has expired.")
                node = google_commit(drive, upload, staged)
                upload.result = apply_fields(google_file(drive, node), upload.info["mask"])
            except Fail:
                take_upload(upload)
                raise
            finally:
                staged.discard()
                upload.path = None  # now the item's, or deleted
        return json_reply(upload.result)


def google_commit(drive, upload, staged):
    meta = upload.info["meta"]
    if upload.info["file_id"] is None:
        node = google_create_node(drive, meta, upload.info["content_type"])
        if node.mime.startswith(GOOGLE_TYPE_PREFIX):
            return node  # an import: a Google document holds no bytes of its own
    else:
        node = drive.nodes.get(upload.info["file_id"])
        if node is None:
            raise google_error(404, "notFound", f"File not found: {upload.info['file_id']}.", location="fileId")
        if isinstance(meta.get("name"), str) and meta["name"]:
            node.name = meta["name"]
    drive.set_content(node, staged)
    return node


def google(request):
    drive = STATE.drives["google"]
    if request.path.startswith("/upload/drive/v3/files"):
        rest = request.path[len("/upload/drive/v3/files"):]
        if "upload_id" in request.query:
            return google_upload_bytes(request, drive, request.query["upload_id"])
        return google_upload_start(request, drive, rest)
    method, path = request.method, request.path
    if (method, path) == ("GET", "/drive/v3/about"):
        return google_about(request, drive)
    if (method, path) == ("GET", "/drive/v3/files"):
        return google_list(request, drive)
    if (method, path) == ("POST", "/drive/v3/files"):
        return google_create(request, drive)
    if (method, path) == ("DELETE", "/drive/v3/files/trash"):
        return google_empty_trash(request, drive)
    match = re.fullmatch(r"/drive/v3/files/([^/]+)(/export)?", path)
    if match:
        file_id = unquote(match[1])
        if match[2] and method == "GET":
            return google_export(request, drive, file_id)
        if not match[2] and method == "GET":
            return google_get(request, drive, file_id)
        if not match[2] and method == "PATCH":
            return google_update(request, drive, file_id)
        if not match[2] and method == "DELETE":
            return google_delete(request, drive, file_id)
    raise google_error(404, "notFound", "Not Found")


# MARK: - Authorization

def unauthorized(provider, problem):
    if provider == "dropbox":
        tag = "expired_access_token" if problem == "expired" else "invalid_access_token"
        return json_reply({"error_summary": tag + "/..", "error": {".tag": tag}}, 401)
    if provider == "microsoft":
        message = {"missing": "Access token is empty.",
                   "expired": "Lifetime validation failed, the token is expired.",
                   "invalid": "Invalid authentication token."}[problem]
        challenge = ('Bearer realm="", authorization_uri="https://login.microsoftonline.com/common/oauth2/authorize", '
                     'client_id="00000003-0000-0000-c000-000000000000"')
        return graph_error(401, "InvalidAuthenticationToken", message, [("WWW-Authenticate", challenge)]).reply
    reason, message = ("required", "Login Required.") if problem == "missing" else ("authError", "Invalid Credentials")
    challenge = 'Bearer realm="https://accounts.google.com/", error="invalid_token"'
    return google_error(401, reason, message, location="Authorization",
                        headers=[("WWW-Authenticate", challenge)]).reply


def rate_limited(provider):
    if provider == "dropbox":
        return json_reply({"error_summary": "too_many_requests/..",
                           "error": {"reason": {".tag": "too_many_requests"}, "retry_after": 1}},
                          429, [("Retry-After", "1")])
    if provider == "microsoft":
        return graph_error(429, "activityLimitReached", "The request has been throttled.",
                           [("Retry-After", "1")]).reply
    return google_error(403, "userRateLimitExceeded", "User Rate Limit Exceeded", domain="usageLimits").reply


MICROSOFT_TOKEN_PATH = re.compile(r"/(common|consumers|organizations|[0-9a-fA-F-]{36})/oauth2/v2\.0/token")


def token_provider(request):
    if request.host == "api.dropboxapi.com" and request.path == "/oauth2/token":
        return "dropbox"
    if request.host == "oauth2.googleapis.com" and request.path == "/token":
        return "google"
    if request.host == "login.microsoftonline.com" and MICROSOFT_TOKEN_PATH.fullmatch(request.path):
        return "microsoft"
    return None


def oauth_error(provider, error, description, status=400):
    body = {"error": error, "error_description": description}
    if provider == "microsoft":
        code = {"invalid_grant": 70000, "unsupported_grant_type": 70003}.get(error, 900144)
        body.update(error_description=f"AADSTS{code}: {description}", error_codes=[code],
                    timestamp=time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime()),
                    trace_id=str(uuid.uuid4()), correlation_id=str(uuid.uuid4()))
    return json_reply(body, status)


def token_response(provider, access):
    if provider == "google":
        return {"access_token": access, "expires_in": TOKEN_LIFETIME,
                "scope": "https://www.googleapis.com/auth/drive", "token_type": "Bearer"}
    if provider == "microsoft":
        return {"token_type": "Bearer", "expires_in": TOKEN_LIFETIME, "ext_expires_in": TOKEN_LIFETIME,
                "scope": "https://graph.microsoft.com/Files.ReadWrite.All https://graph.microsoft.com/User.Read",
                "access_token": access}
    return {"access_token": access, "token_type": "bearer", "expires_in": TOKEN_LIFETIME,
            "scope": "account_info.read files.content.read files.content.write files.metadata.read "
                     "files.metadata.write",
            "uid": "1", "account_id": DROPBOX_ACCOUNT["account_id"]}


def token_endpoint(request, provider):
    """grant_type=refresh_token with a refresh token the mock issued, or
    grant_type=authorization_code with code e2e-code."""
    if request.method != "POST":
        return oauth_error(provider, "invalid_request", "The token endpoint only accepts POST.", 405)
    try:
        form = dict(parse_qsl(request.body.read_all(MAX_JSON_BODY).decode(), keep_blank_values=True))
    except UnicodeDecodeError:
        return oauth_error(provider, "invalid_request", "The request body is not form-encoded UTF-8.")
    grant = form.get("grant_type")
    with STATE.lock:
        tokens = STATE.tokens
        if grant == "refresh_token":
            refresh = form.get("refresh_token", "")
            if not tokens.redeemable(provider, refresh):
                description = {
                    "google": "Token has been expired or revoked.",
                    "microsoft": "The provided value for the 'refresh_token' parameter is not valid.",
                    "dropbox": "refresh token is invalid or revoked",
                }[provider]
                return oauth_error(provider, "invalid_grant", description)
            body = token_response(provider, tokens.new_access(provider))
            if provider == "microsoft":
                # Microsoft rotates refresh tokens; Google and Dropbox send none on refresh.
                tokens.retire(refresh)
                body["refresh_token"] = tokens.new_refresh(provider)
            STATE.refreshes[provider] += 1
        elif grant == "authorization_code":
            if form.get("code") != "e2e-code":
                description = {
                    "google": "Malformed auth code.",
                    "microsoft": "The provided value for the 'code' parameter is not valid.",
                    "dropbox": "code doesn't exist or has expired",
                }[provider]
                return oauth_error(provider, "invalid_grant", description)
            body = token_response(provider, tokens.new_access(provider))
            body["refresh_token"] = tokens.new_refresh(provider)
        else:
            return oauth_error(provider, "unsupported_grant_type",
                               "grant_type must be authorization_code or refresh_token.")
    return json_reply(body, headers=[("Cache-Control", "no-store"), ("Pragma", "no-cache")])


# MARK: - Admin

def admin(request):
    action = request.path.strip("/")
    if request.method == "GET" and action == "stats":
        with STATE.lock:
            return json_reply(STATE.stats())
    if request.method != "POST" or action not in ("reset", "token", "revoke", "throttle"):
        return json_reply({"error": f"no admin endpoint {request.method} /__admin/{action}"}, 404)
    try:
        body = request.json()
    except ValueError:
        return json_reply({"error": "the body must be JSON"}, 400)
    if not isinstance(body, dict):
        return json_reply({"error": "the body must be a JSON object"}, 400)
    if action == "reset":
        with STATE.lock:
            STATE.reset()
        return json_reply({})
    provider = body.get("provider")
    if provider not in PROVIDERS:
        return json_reply({"error": "provider must be one of " + ", ".join(PROVIDERS)}, 400)
    with STATE.lock:
        if action == "token":
            return json_reply({"access_token": STATE.tokens.new_access(provider),
                               "refresh_token": STATE.tokens.new_refresh(provider),
                               "expires_in": TOKEN_LIFETIME})
        if action == "revoke":
            STATE.tokens.revoke(provider)
            return json_reply({})
        count = body.get("count")
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            return json_reply({"error": "count must be a non-negative integer"}, 400)
        STATE.throttle[provider] = count
        return json_reply({})


# MARK: - Routing

HOST_PROVIDERS = {
    "api.dropboxapi.com": "dropbox", "content.dropboxapi.com": "dropbox",
    "graph.microsoft.com": "microsoft", "graph-upload.mock": "microsoft", "graph-content.mock": "microsoft",
    "login.microsoftonline.com": "microsoft",
    "www.googleapis.com": "google", "oauth2.googleapis.com": "google",
}
API_HOSTS = {
    "api.dropboxapi.com": dropbox_api, "content.dropboxapi.com": dropbox_content,
    "graph.microsoft.com": graph, "www.googleapis.com": google,
}
# Pre-signed hosts authorize by URL and refuse the account's token.
PRESIGNED_HOSTS = {"graph-upload.mock": graph_upload_host, "graph-content.mock": graph_content_host}


def route(request):
    if request.host == "__admin":
        return admin(request)
    provider = HOST_PROVIDERS.get(request.host)
    if provider is None:
        return text_reply(f"The cloud mock does not serve the host {request.host!r}.", 404)
    token_for = token_provider(request)
    if token_for:
        return token_endpoint(request, token_for)
    if request.host not in API_HOSTS and request.host not in PRESIGNED_HOSTS:
        return text_reply("Not Found", 404)
    with STATE.lock:
        STATE.requests[provider] += 1
    if request.host in PRESIGNED_HOSTS:
        return PRESIGNED_HOSTS[request.host](request)
    # A resumable upload's session URI authorizes the bytes sent to it; a
    # token sent along must still be a valid one.
    session_uri = request.host == "www.googleapis.com" and "upload_id" in request.query
    with STATE.lock:
        problem = STATE.tokens.check(provider, request.bearer)
        if problem and not (session_uri and problem == "missing"):
            return unauthorized(provider, problem)
        if STATE.throttle[provider] > 0:
            STATE.throttle[provider] -= 1
            return rate_limited(provider)
    return API_HOSTS[request.host](request)


def respond(request):
    try:
        return route(request)
    except Fail as failure:
        return failure.reply
    except BodyTooLarge:
        return text_reply("The request body is too large for this endpoint.", 413)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hamasen-e2e-cloud"
    sys_version = ""
    timeout = 300  # seconds a connection may stay silent, mid-request or idle

    def serve(self):
        started = time.monotonic()
        reply = None
        try:
            body = RequestBody(self.rfile, self.headers)
            try:
                reply = respond(Request(self.command, self.path, self.headers, body))
            except (BadRequestBody, ConnectionError, TimeoutError):
                raise
            except Exception:
                traceback.print_exc()
                reply = text_reply("The cloud mock failed to handle this request.", 500)
            # The client finishes sending before it reads the answer, so an
            # early refusal of a large upload is heard rather than reset.
            body.drain()
        except BadRequestBody as error:
            if reply is not None and reply.stream:
                reply.stream[0].close()
            reply = text_reply(f"Malformed request: {error}", 400)
            self.close_connection = True
        except (ConnectionError, TimeoutError) as error:
            if reply is not None and reply.stream:
                reply.stream[0].close()
            self.close_connection = True
            self.log_line(started, f"dropped ({type(error).__name__})", 0)
            return
        self.log_line(started, reply.status, self.send_reply(reply))

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = serve

    def send_reply(self, reply):
        stream = reply.stream
        length = stream[2] if stream else len(reply.body)
        try:
            self.send_response(reply.status, reply.reason)
            for name, value in reply.headers:
                self.send_header(name, value)
            if reply.status != 204:
                self.send_header("Content-Length", str(length))
            if self.close_connection:
                self.send_header("Connection", "close")
            self.end_headers()
            if stream:
                file, offset, left = stream
                file.seek(offset)
                while left > 0:
                    chunk = file.read(min(left, 1 << 20))
                    if not chunk:
                        self.close_connection = True  # shorter than announced: never reuse
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            elif reply.status != 204:
                self.wfile.write(reply.body)
            return length
        except (ConnectionError, TimeoutError):
            self.close_connection = True
            return 0
        finally:
            if stream:
                stream[0].close()

    def log_line(self, started, status, size):
        elapsed = (time.monotonic() - started) * 1000
        with LOG_LOCK:
            sys.stdout.write(f"{iso(time.time())} {self.command} {self.path} {status} {size}B {elapsed:.1f}ms\n")
            sys.stdout.flush()

    def log_request(self, code="-", size="-"):
        pass  # serve() logs each request once, with its timing

    def log_message(self, format, *args):
        with LOG_LOCK:
            sys.stderr.write(f"{iso(time.time())} {self.address_string()} {format % args}\n")
            sys.stderr.flush()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64


def housekeeping():
    while True:
        time.sleep(15)
        with STATE.lock:
            STATE.prune(time.time())


def main():
    # Metadata does not outlive the process, so neither does the content it described.
    if os.path.exists(FILES_DIR):
        shutil.rmtree(FILES_DIR)
    os.makedirs(FILES_DIR)
    server = Server((BIND, PORT), Handler)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    threading.Thread(target=housekeeping, daemon=True).start()
    print(f"{iso(time.time())} cloud mock listening on {BIND}:{PORT}, content in {FILES_DIR}", flush=True)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
