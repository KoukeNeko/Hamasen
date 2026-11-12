#!/usr/bin/python3
# Copyright 2026 KoukeNeko
# Licensed under the Apache License, Version 2.0.
"""Hamasen for Linux: a GTK 4 / libadwaita front end over GVfs.

Servers mount through GIO, so each one appears in the file manager sidebar
(Nautilus, Files, Thunar...) and in every GTK file chooser. Credentials are
asked for by GTK's mount dialog and kept by the desktop keyring, never in
this app's config file.
"""
import http.client
import json
import os
import shutil
import socket
import sys
import threading
import uuid
from urllib.parse import quote, unquote, urlsplit

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Secret", "1")
from gi.repository import Adw, Gio, GLib, Gtk, Secret  # noqa: E402

from tray import Tray  # noqa: E402

APP_ID = "app.hamasen.Hamasen"
CONFIG = os.path.join(GLib.get_user_config_dir(), "hamasen", "servers.json")
# label, GVfs scheme, default port
PROTOCOLS = [("SFTP", "sftp", 22), ("FTP", "ftp", 21), ("SMB", "smb", 445),
             ("WebDAV", "dav", 80), ("WebDAV (HTTPS)", "davs", 443), ("Google Drive", "gdrive", 0)]
# Google Drive has no GVfs backend here, so rclone mounts it as a FUSE folder.
RCLONE = shutil.which("rclone") or "/home/linuxbrew/.linuxbrew/bin/rclone"
MOUNT_ROOT = os.path.expanduser("~/Hamasen")
BOOKMARKS = os.path.join(GLib.get_user_config_dir(), "gtk-3.0", "bookmarks")


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


def is_gdrive(s):
    return s["scheme"] == "gdrive"


def mount_path(s):
    return os.path.join(MOUNT_ROOT, s["name"].replace("/", "_"))


def is_mounted(s):
    if is_gdrive(s):
        return os.path.ismount(mount_path(s))
    return enclosing_mount(server_uri(s)) is not None


def set_bookmark(s, present):
    """A bookmark is what puts a plain folder in the file manager's sidebar."""
    line = f"{Gio.File.new_for_path(mount_path(s)).get_uri()} {s['name']}"
    try:
        with open(BOOKMARKS, encoding="utf-8") as f:
            lines = [l for l in f.read().splitlines() if l != line]
    except FileNotFoundError:
        lines = []
    os.makedirs(os.path.dirname(BOOKMARKS), exist_ok=True)
    with open(BOOKMARKS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines + ([line] if present else [])) + "\n")


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
    """Files rclone has accepted but not yet sent to Drive; 0 if it can't be asked."""
    try:  # a local socket answers at once, so this does not wait on the network
        conn = _UnixConnection(rc_socket(s))
        conn.request("POST", "/vfs/stats", body="{}", headers={"Content-Type": "application/json"})
        cache = json.loads(conn.getresponse().read())["diskCache"]
        return cache["uploadsQueued"] + cache["uploadsInProgress"]
    except (OSError, ValueError, KeyError):
        return 0


def pending_uploads_async(s, done):
    """pending_uploads off the main loop: rclone answers slowly while it is busy listing."""
    threading.Thread(target=lambda: GLib.idle_add(done, pending_uploads(s)), daemon=True).start()


def run(argv, done):
    """Runs a command without blocking the window; done(success, stderr)."""
    process = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDERR_PIPE)

    def finished(p, result):
        _, _, err = p.communicate_utf8_finish(result)
        done(p.get_successful(), (err or "").strip())
    process.communicate_utf8_async(None, None, finished)
    return process


def server_uri(s):
    if is_gdrive(s):
        return Gio.File.new_for_path(mount_path(s)).get_uri()
    default_port = next(p for _, scheme, p in PROTOCOLS if scheme == s["scheme"])
    user = quote(s["user"], safe="") + "@" if s.get("user") else ""
    port = f":{s['port']}" if s.get("port") and s["port"] != default_port else ""
    path = "/" + quote(s.get("path", "").lstrip("/"), safe="/")
    return f"{s['scheme']}://{user}{s['host']}{port}{path}"


def enclosing_mount(uri):
    try:
        return Gio.File.new_for_uri(uri).find_enclosing_mount(None)
    except GLib.Error:
        return None


class ServerDialog(Adw.Dialog):
    def __init__(self, server, on_save):
        super().__init__(title="伺服器" if server else "新增伺服器", content_width=420)
        self.server, self.on_save = server or {}, on_save
        s = self.server

        self.name = Adw.EntryRow(title="名稱", text=s.get("name", ""))
        self.protocol = Adw.ComboRow(title="通訊協定", model=Gtk.StringList.new([p[0] for p in PROTOCOLS]))
        self.protocol.set_selected(next((i for i, p in enumerate(PROTOCOLS) if p[1] == s.get("scheme")), 0))
        self.host = Adw.EntryRow(title="主機", text=s.get("host", ""))
        self.port = Adw.EntryRow(title="連接埠", text=str(s.get("port", "")), input_purpose=Gtk.InputPurpose.DIGITS)
        self.user = Adw.EntryRow(title="使用者", text=s.get("user", ""))
        self.password = Adw.PasswordEntryRow(title="密碼", text=get_password(s["id"]) or "" if "id" in s else "")
        self.path = Adw.EntryRow(title="路徑", text=s.get("path", ""))

        group = Adw.PreferencesGroup()
        self.remote_rows = (self.host, self.port, self.user, self.password, self.path)
        for row in (self.name, self.protocol) + self.remote_rows:
            group.add(row)

        # Google Drive: rclone's shared client ID is retiring, so offer the user's own.
        self.own_client = Adw.SwitchRow(title="使用自己的用戶端 ID")
        self.client_id = Adw.EntryRow(title="用戶端 ID")
        self.client_secret = Adw.PasswordEntryRow(title="用戶端密鑰")
        guide = Gtk.Label(wrap=True, xalign=0, selectable=True, margin_top=6, margin_bottom=6, label=(
            "1. 於 Google Cloud Console 建立專案。\n"
            "2. 「API 和服務」→「程式庫」，啟用 Google Drive API。\n"
            "3. 設定「OAuth 同意畫面」，並將所使用的帳戶加入測試使用者。\n"
            "4. 於「憑證」建立「OAuth 用戶端 ID」，應用程式類型選擇「電腦版應用程式」。\n"
            "5. 將用戶端 ID 與密鑰填入上方欄位。"))
        console = Gtk.LinkButton(uri="https://console.cloud.google.com/apis/credentials",
                                 label="開啟 Google Cloud Console", halign=Gtk.Align.START)
        self.guide_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin_start=12, margin_end=12)
        self.guide_box.append(guide)
        self.guide_box.append(console)
        self.drive_group = Adw.PreferencesGroup()
        for row in (self.own_client, self.client_id, self.client_secret):
            self.drive_group.add(row)
        self.drive_group.add(self.guide_box)
        self.own_client.connect("notify::active", self.protocol_changed)
        self.protocol.connect("notify::selected", self.protocol_changed)
        self.protocol_changed()
        page = Adw.PreferencesPage()
        page.add(group)
        page.add(self.drive_group)

        cancel = Gtk.Button(label="取消")
        cancel.connect("clicked", lambda *_: self.close())
        self.save_button = save = Gtk.Button(label="儲存", css_classes=["suggested-action"])
        save.connect("clicked", self.save)
        self.authorizing = None
        self.connect("closed", lambda *_: self.authorizing and self.authorizing.force_exit())
        header = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(save)
        view = Adw.ToolbarView(content=page)
        view.add_top_bar(header)
        self.set_child(view)

    def protocol_changed(self, *_):
        gdrive = PROTOCOLS[self.protocol.get_selected()][1] == "gdrive"
        for row in self.remote_rows:
            row.set_visible(not gdrive)
        self.drive_group.set_visible(gdrive and not self.server.get("remote"))
        own = self.own_client.get_active()
        for row in (self.client_id, self.client_secret, self.guide_box):
            row.set_visible(own)

    def save_gdrive(self):
        name = self.name.get_text().strip() or "Google Drive"
        self.server.update(id=self.server.get("id") or str(uuid.uuid4()), name=name, scheme="gdrive")
        if self.server.get("remote"):
            self.on_save(self.server)
            self.close()
            return
        remote = "hamasen-" + self.server["id"][:8]
        options = []
        if self.own_client.get_active():
            client_id, secret = self.client_id.get_text().strip(), self.client_secret.get_text().strip()
            if not client_id or not secret:
                for row, text in ((self.client_id, client_id), (self.client_secret, secret)):
                    if not text:
                        row.add_css_class("error")
                return
            options = ["client_id", client_id, "client_secret", secret]

        def authorized(ok, err):
            self.authorizing = None
            if not ok:
                self.save_button.set_sensitive(True)
                self.save_button.set_label("儲存")
                if err:  # empty when the dialog was closed and rclone was stopped
                    alert = Adw.AlertDialog(heading="無法授權 Google Drive", body=err)
                    alert.add_response("close", "關閉")
                    alert.present(self)
                return
            self.server["remote"] = remote
            self.on_save(self.server)
            self.close()
        self.save_button.set_sensitive(False)
        self.save_button.set_label("授權中")
        try:  # opens the browser for Google's sign-in and waits for it
            self.authorizing = run([RCLONE, "config", "create", remote, "drive", *options], authorized)
        except GLib.Error as e:
            authorized(False, e.message)

    def save(self, *_):
        if PROTOCOLS[self.protocol.get_selected()][1] == "gdrive":
            self.save_gdrive()
            return
        host = self.host.get_text().strip()
        if not host:
            self.host.add_css_class("error")
            return
        scheme = PROTOCOLS[self.protocol.get_selected()][1]
        port = self.port.get_text().strip()
        user, path = self.user.get_text().strip(), self.path.get_text().strip()
        if "://" in host:  # a pasted URL fills in the other fields
            url = urlsplit(host)
            if url.scheme in [p[1] for p in PROTOCOLS]:
                scheme = url.scheme
            host = url.hostname or ""
            port = port or (str(url.port) if url.port else "")
            user = user or unquote(url.username or "")
            path = path or unquote(url.path)
            if not host:
                self.host.add_css_class("error")
                return
        if scheme == "smb" and not path.strip("/"):  # GVfs mounts shares, not a bare SMB host
            self.path.add_css_class("error")
            self.path.set_title("路徑（SMB 須指定共用資料夾）")
            return
        self.server.update(
            id=self.server.get("id") or str(uuid.uuid4()),
            name=self.name.get_text().strip() or host,
            scheme=scheme, host=host,
            port=int(port) if port.isdigit() else None, user=user, path=path)
        set_password(self.server["id"], self.password.get_text())
        self.on_save(self.server)
        self.close()


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Hamasen 哈瑪星", default_width=560, default_height=520)
        self.servers = load_servers()
        self.connecting = {}  # server id -> Gio.Cancellable of the mount in flight

        add = Gtk.Button(icon_name="list-add-symbolic", tooltip_text="新增伺服器")
        add.connect("clicked", lambda *_: self.edit(None))
        header = Adw.HeaderBar()
        header.pack_start(add)

        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"],
                                margin_top=12, margin_bottom=12, margin_start=12, margin_end=12, valign=Gtk.Align.START)
        add_first = Gtk.Button(label="新增伺服器", halign=Gtk.Align.CENTER, css_classes=["suggested-action", "pill"])
        add_first.connect("clicked", lambda *_: self.edit(None))
        self.empty = Adw.StatusPage(icon_name="network-server-symbolic", title="沒有伺服器", child=add_first)
        self.stack = Gtk.Stack()
        self.stack.add_named(self.empty, "empty")
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(child=self.list)), "list")
        self.toasts = Adw.ToastOverlay(child=self.stack)
        view = Adw.ToolbarView(content=self.toasts)
        view.add_top_bar(header)
        self.set_content(view)

        # Mounts made or lost outside this app (file manager, eject) update the rows too.
        monitor = Gio.VolumeMonitor.get()
        for sig in ("mount-added", "mount-removed"):
            monitor.connect(sig, lambda *_: self.rebuild())
        self.connect("close-request", self.hide_to_tray)
        self.uploads = {}  # server id -> files rclone still has to upload
        self.polling = set()
        GLib.timeout_add_seconds(3, self.poll_uploads)
        self.rebuild()

    def poll_uploads(self):
        for s in self.servers:
            if is_gdrive(s) and is_mounted(s) and s["id"] not in self.polling:
                self.polling.add(s["id"])
                pending_uploads_async(s, lambda n, id=s["id"]: self.polled(id, n))
        return True

    def polled(self, server_id, count):
        self.polling.discard(server_id)
        if self.uploads.get(server_id, 0) != count:
            self.uploads[server_id] = count
            self.rebuild()

    def hide_to_tray(self, *_):
        self.set_visible(False)
        return True

    def tray_entries(self):
        entries = [(s["name"], is_mounted(s), lambda s=s: self.toggle(s))
                   for s in self.servers]
        if entries:
            entries.append((None, None, None))
        return entries + [("開啟 Hamasen", None, self.present), ("結束", None, self.get_application().quit)]

    def toggle(self, server):
        if is_mounted(server):
            self.unmount(server)
        elif server["id"] not in self.connecting:
            self.mount(server)

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text))

    def rebuild(self):
        self.list.remove_all()
        for s in self.servers:
            self.list.append(self.row(s))
        self.stack.set_visible_child_name("list" if self.servers else "empty")
        self.get_application().tray.refresh()

    def subtitle(self, s, mounted):
        if not is_gdrive(s):
            return GLib.markup_escape_text(server_uri(s))
        pending = self.uploads.get(s["id"], 0) if mounted else 0
        return f"Google Drive · 上傳中 {pending}" if pending else "Google Drive"

    def row(self, s):
        mounted = is_mounted(s)
        row = Adw.ActionRow(title=GLib.markup_escape_text(s["name"]),
                            subtitle=self.subtitle(s, mounted),
                            activatable=False)
        if s["id"] not in self.connecting:
            row.add_prefix(Gtk.Image(icon_name="folder-remote-symbolic" if mounted else "network-server-symbolic"))
        for icon, tip, cb in (("document-edit-symbolic", "編輯", lambda *_: self.edit(s)),
                              ("user-trash-symbolic", "刪除", lambda *_: self.delete(s))):
            b = Gtk.Button(icon_name=icon, tooltip_text=tip, valign=Gtk.Align.CENTER, css_classes=["flat"])
            b.connect("clicked", cb)
            row.add_suffix(b)
        if mounted:
            open_btn = Gtk.Button(label="開啟", valign=Gtk.Align.CENTER)
            open_btn.connect("clicked", lambda *_: Gtk.UriLauncher(uri=server_uri(s)).launch(self, None, None, None))
            unmount = Gtk.Button(label="卸載", valign=Gtk.Align.CENTER)
            unmount.connect("clicked", lambda *_: self.unmount(s))
            row.add_suffix(open_btn)
            row.add_suffix(unmount)
        elif s["id"] in self.connecting:
            row.add_prefix(Gtk.Spinner(spinning=True))
            row.set_subtitle("連線中")
            cancel = Gtk.Button(label="取消", valign=Gtk.Align.CENTER)
            cancel.connect("clicked", lambda *_: self.connecting[s["id"]].cancel())
            row.add_suffix(cancel)
        else:
            mount = Gtk.Button(label="掛載", valign=Gtk.Align.CENTER, css_classes=["suggested-action"])
            mount.connect("clicked", lambda *_: self.mount(s))
            row.add_suffix(mount)
        return row

    def edit(self, server):
        def saved(s):
            if s not in self.servers:
                self.servers.append(s)
            save_servers(self.servers)
            self.rebuild()
        ServerDialog(server, saved).present(self)

    def delete(self, server):
        dialog = Adw.AlertDialog(heading=f"刪除「{server['name']}」？")
        dialog.add_response("cancel", "取消")
        dialog.add_response("delete", "刪除")
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE)

        def answered(d, result):
            if d.choose_finish(result) == "delete":
                self.servers.remove(server)
                set_password(server["id"], None)
                if is_gdrive(server):
                    if is_mounted(server):
                        self.unmount(server)
                    if server.get("remote"):
                        run([RCLONE, "config", "delete", server["remote"]], lambda *_: None)
                save_servers(self.servers)
                self.rebuild()
        dialog.choose(self, None, answered)

    def mount(self, server):
        cancellable = Gio.Cancellable()
        self.connecting[server["id"]] = cancellable
        if is_gdrive(server):
            self.mount_gdrive(server, cancellable)
            return

        def done(f, result):
            del self.connecting[server["id"]]
            try:
                f.mount_enclosing_volume_finish(result)
            except GLib.Error as e:
                # Cancelled, or the user dismissed the password dialog.
                if e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED) \
                        or e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.FAILED_HANDLED):
                    pass
                elif e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED) and enclosing_mount(server_uri(server)):
                    pass
                else:
                    self.show_error(server, e.message, self.mount_hint(server, e))
            self.rebuild()
        Gio.File.new_for_uri(server_uri(server)).mount_enclosing_volume(
            Gio.MountMountFlags.NONE, mount_operation(self, server), cancellable, done)
        self.rebuild()

    def mount_gdrive(self, server, cancellable):
        def done(ok, err):
            del self.connecting[server["id"]]
            if ok:
                set_bookmark(server, True)
            elif not cancellable.is_cancelled():
                self.show_error(server, err)
            self.rebuild()
        path = mount_path(server)
        os.makedirs(path, exist_ok=True)
        try:  # --daemon returns once the folder is mounted
            process = run([RCLONE, "mount", "--daemon", "--vfs-cache-mode", "writes",
                           "--dir-cache-time", "1h", "--attr-timeout", "1h",
                           "--rc", f"--rc-addr=unix://{rc_socket(server)}", server["remote"] + ":", path], done)
        except GLib.Error as e:
            done(False, e.message)
            return
        cancellable.connect(process.force_exit)
        self.rebuild()

    def mount_hint(self, server, error):
        if error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED) and server["scheme"] == "smb":
            return "請於「路徑」欄位指定共用資料夾名稱。"
        if error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.TIMED_OUT):
            return "主機未回應。請確認主機、連接埠與網路連線。"
        return ""

    def show_error(self, server, message, hint=""):
        dialog = Adw.AlertDialog(heading=f"無法連線「{server['name']}」",
                                 body="\n".join(filter(None, [hint, message])))
        dialog.add_response("close", "關閉")
        dialog.present(self)

    def unmount(self, server):
        if is_gdrive(server):
            def gone(ok, err):
                if ok:
                    set_bookmark(server, False)
                else:
                    self.toast(err)
                self.rebuild()

            def eject():
                run(["fusermount3", "-u", mount_path(server)], gone)

            def checked(pending):
                if not pending:
                    eject()
                    return
                dialog = Adw.AlertDialog(heading=f"卸載「{server['name']}」？",
                                         body=f"{pending} 個檔案尚未上傳至 Google Drive。")
                dialog.add_response("cancel", "取消")
                dialog.add_response("unmount", "仍要卸載")
                dialog.set_response_appearance("unmount", Adw.ResponseAppearance.DESTRUCTIVE)
                dialog.choose(self, None, lambda d, r: d.choose_finish(r) == "unmount" and eject())
            pending_uploads_async(server, checked)
            return
        m = enclosing_mount(server_uri(server))
        if not m:
            return

        def done(mnt, result):
            try:
                mnt.unmount_with_operation_finish(result)
            except GLib.Error as e:
                self.toast(e.message)
            self.rebuild()
        m.unmount_with_operation(Gio.MountUnmountFlags.NONE, Gtk.MountOperation(parent=self), None, done)


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)

    def do_startup(self):
        Adw.Application.do_startup(self)
        self.hold()  # stays alive in the tray after the window is closed
        self.tray = Tray(lambda: self.window.tray_entries(), lambda: self.window.present(), "network-server-symbolic")
        self.window = Window(self)

    def do_activate(self):
        self.window.present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv))
