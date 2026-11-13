# Copyright 2026 KoukeNeko
# Licensed under the Apache License, Version 2.0.
"""Everything Hamasen does that is not drawing a window: server records,
secrets, GVfs and rclone mounting, SSH config import and autostart."""
import http.client
import json
import os
import re
import shutil
import socket
import threading
from collections import namedtuple
from urllib.parse import quote

import gi

import contributors

gi.require_version("Gtk", "4.0")
gi.require_version("Secret", "1")
from gi.repository import Gio, GLib, Gtk, Secret  # noqa: E402

APP_ID = "app.hamasen.Hamasen"
VERSION = "1.0.0"
REPO_URL = f"https://github.com/{contributors.OWNER}/{contributors.NAME}"
HERE = os.path.dirname(os.path.abspath(__file__))
# Written by the packaging step. A checkout has none and asks GitHub instead.
CONTRIBUTORS_SNAPSHOT = os.path.join(HERE, "contributors.json")
CONFIG = os.path.join(GLib.get_user_config_dir(), "hamasen", "servers.json")
AUTOSTART = os.path.join(GLib.get_user_config_dir(), "autostart", f"{APP_ID}.desktop")
BOOKMARKS = os.path.join(GLib.get_user_config_dir(), "gtk-3.0", "bookmarks")
MOUNT_ROOT = os.path.expanduser("~/Hamasen")
SSH_CONFIG = os.path.expanduser("~/.ssh/config")
# GVfs has no backend for these, so rclone mounts them as FUSE folders.
RCLONE = shutil.which("rclone") or "/home/linuxbrew/.linuxbrew/bin/rclone"

# kind: "gvfs" mounts through GIO, "oauth" is an rclone remote signed in through
# the browser, "s3" is an rclone remote described entirely by the server record.
Protocol = namedtuple("Protocol", "label scheme port kind rclone_type")
PROTOCOLS = [
    Protocol("SFTP", "sftp", 22, "gvfs", None),
    Protocol("FTP", "ftp", 21, "gvfs", None),
    Protocol("SMB", "smb", 445, "gvfs", None),
    Protocol("WebDAV", "dav", 80, "gvfs", None),
    Protocol("WebDAV (HTTPS)", "davs", 443, "gvfs", None),
    Protocol("NFS", "nfs", 2049, "gvfs", None),
    Protocol("Google Drive", "gdrive", 0, "oauth", "drive"),
    Protocol("OneDrive", "onedrive", 0, "oauth", "onedrive"),
    Protocol("Dropbox", "dropbox", 0, "oauth", "dropbox"),
    Protocol("Amazon S3", "s3", 0, "s3", "s3"),
]


def protocol_of(s):
    return next(p for p in PROTOCOLS if p.scheme == s["scheme"])


def is_rclone(s):
    return protocol_of(s).kind != "gvfs"


# --- secrets ---------------------------------------------------------------

SECRET_SCHEMA = Secret.Schema.new(APP_ID, Secret.SchemaFlags.NONE, {"server": Secret.SchemaAttributeType.STRING})


def get_password(server_id):
    return Secret.password_lookup_sync(SECRET_SCHEMA, {"server": server_id}, None)


def set_password(server_id, password):
    if password:
        Secret.password_store_sync(SECRET_SCHEMA, {"server": server_id}, Secret.COLLECTION_DEFAULT,
                                   "Hamasen", password, None)
    else:
        Secret.password_clear_sync(SECRET_SCHEMA, {"server": server_id}, None)


def mount_operation(window, server):
    """The GTK password dialog, except the saved password answers first, once."""
    op = Gtk.MountOperation(parent=window)
    saved = {"password": get_password(server["id"])}

    def ask_password(op, message, default_user, default_domain, flags):
        if not saved["password"]:
            return
        if flags & Gio.AskPasswordFlags.NEED_USERNAME:
            op.set_username(server.get("user") or default_user)
        op.set_password(saved["password"])
        saved["password"] = None  # a rejected password falls through to the dialog
        op.reply(Gio.MountOperationResult.HANDLED)
        op.stop_emission_by_name("ask-password")
    op.connect("ask-password", ask_password)
    return op


# --- server records --------------------------------------------------------

def load_servers():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return []


def save_servers(servers):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w", encoding="utf-8") as f:
        json.dump(servers, f, indent=2, ensure_ascii=False)


def server_uri(s):
    if is_rclone(s):
        return Gio.File.new_for_path(mount_path(s)).get_uri()
    user = quote(s["user"], safe="") + "@" if s.get("user") else ""
    port = f":{s['port']}" if s.get("port") and s["port"] != protocol_of(s).port else ""
    path = "/" + quote(s.get("path", "").lstrip("/"), safe="/")
    return f"{s['scheme']}://{user}{s['host']}{port}{path}"


def mount_path(s):
    return os.path.join(MOUNT_ROOT, s["name"].replace("/", "_"))


def enclosing_mount(uri):
    try:
        return Gio.File.new_for_uri(uri).find_enclosing_mount(None)
    except GLib.Error:
        return None


def is_mounted(s):
    if is_rclone(s):
        return os.path.ismount(mount_path(s))
    return enclosing_mount(server_uri(s)) is not None


def set_bookmark(s, present):
    """A bookmark is what puts a plain folder in the file manager's sidebar."""
    line = f"{Gio.File.new_for_path(mount_path(s)).get_uri()} {s['name']}"
    try:
        with open(BOOKMARKS, encoding="utf-8") as f:
            lines = [existing for existing in f.read().splitlines() if existing != line]
    except FileNotFoundError:
        lines = []
    os.makedirs(os.path.dirname(BOOKMARKS), exist_ok=True)
    with open(BOOKMARKS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines + ([line] if present else [])) + "\n")


# --- rclone ----------------------------------------------------------------

def _quoted(value):
    return '"' + value.replace('"', '""') + '"'


def rclone_remote(s):
    """What rclone mounts: a configured remote, or an S3 connection string."""
    if protocol_of(s).kind == "oauth":
        return s["remote"] + ":"
    options = ["provider=" + ("Other" if s.get("host") else "AWS")]
    if s.get("host"):
        options.append("endpoint=" + _quoted(s["host"]))
    if s.get("region"):
        options.append("region=" + _quoted(s["region"]))
    return f":s3,{','.join(options)}:{s.get('path', '').strip('/')}"


def rclone_env(s):
    """S3 keys travel in the environment, not in the command line or rclone.conf."""
    if protocol_of(s).kind != "s3":
        return {}
    return {"RCLONE_S3_ACCESS_KEY_ID": s.get("user", ""),
            "RCLONE_S3_SECRET_ACCESS_KEY": get_password(s["id"]) or ""}


def rc_socket(s):
    return os.path.join(GLib.get_user_runtime_dir(), f"hamasen-{s['id'][:8]}.sock")


class _UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=2)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def pending_uploads(s):
    """Files rclone has accepted but not yet sent on; 0 if it can't be asked."""
    try:
        conn = _UnixConnection(rc_socket(s))
        conn.request("POST", "/vfs/stats", body="{}", headers={"Content-Type": "application/json"})
        cache = json.loads(conn.getresponse().read())["diskCache"]
        return cache["uploadsQueued"] + cache["uploadsInProgress"]
    except (OSError, ValueError, KeyError):
        return 0


def pending_uploads_async(s, done):
    """pending_uploads off the main loop: rclone answers slowly while it is busy listing."""
    threading.Thread(target=lambda: GLib.idle_add(done, pending_uploads(s)), daemon=True).start()


def run(argv, done, env=None):
    """Runs a command without blocking the window; done(success, stderr)."""
    launcher = Gio.SubprocessLauncher.new(Gio.SubprocessFlags.STDERR_PIPE)
    for name, value in (env or {}).items():
        launcher.setenv(name, value, True)
    process = launcher.spawnv(argv)

    def finished(p, result):
        _, _, err = p.communicate_utf8_finish(result)
        done(p.get_successful(), (err or "").strip())
    process.communicate_utf8_async(None, None, finished)
    return process


def load_contributors(done):
    """done(list of contributors); empty when GitHub could not be reached."""
    if os.path.exists(CONTRIBUTORS_SNAPSHOT):
        with open(CONTRIBUTORS_SNAPSHOT, encoding="utf-8") as f:
            done(json.load(f))
        return

    def fetch():
        try:
            people = contributors.fetch()
        except (OSError, ValueError, KeyError):
            people = []  # the About page links to GitHub's own list instead
        GLib.idle_add(done, people)
    threading.Thread(target=fetch, daemon=True).start()


# --- SSH config and autostart ----------------------------------------------

def ssh_config_hosts(path=SSH_CONFIG):
    """Concrete `Host` aliases. They are mounted by alias, so ssh itself applies
    that entry's HostName, User, Port and IdentityFile."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return []
    hosts = []
    for line in text.splitlines():
        match = re.match(r"\s*host\s*[=\s]\s*(.+)", line, re.IGNORECASE)
        if match:
            hosts += [h for h in match.group(1).split() if not re.search(r"[*?!]", h)]
    return list(dict.fromkeys(hosts))


def autostart_enabled():
    return os.path.exists(AUTOSTART)


def set_autostart(enabled, script, python):
    if not enabled:
        if os.path.exists(AUTOSTART):
            os.remove(AUTOSTART)
        return
    os.makedirs(os.path.dirname(AUTOSTART), exist_ok=True)
    with open(AUTOSTART, "w", encoding="utf-8") as f:
        f.write("[Desktop Entry]\nType=Application\nName=Hamasen\n"
                f"Exec={python} {script} --background\nIcon={APP_ID}\n"
                "X-GNOME-Autostart-enabled=true\n")
