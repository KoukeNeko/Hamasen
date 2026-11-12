#!/usr/bin/python3
# Copyright 2026 KoukeNeko
# Licensed under the Apache License, Version 2.0.
"""Hamasen for Linux: a GTK 4 / libadwaita front end over GVfs.

Servers mount through GIO, so each one appears in the file manager sidebar
(Nautilus, Files, Thunar...) and in every GTK file chooser. Credentials are
asked for by GTK's mount dialog and kept by the desktop keyring, never in
this app's config file.
"""
import json
import os
import sys
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
             ("WebDAV", "dav", 80), ("WebDAV (HTTPS)", "davs", 443)]


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


def server_uri(s):
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
        for row in (self.name, self.protocol, self.host, self.port, self.user, self.password, self.path):
            group.add(row)
        page = Adw.PreferencesPage()
        page.add(group)

        cancel = Gtk.Button(label="取消")
        cancel.connect("clicked", lambda *_: self.close())
        save = Gtk.Button(label="儲存", css_classes=["suggested-action"])
        save.connect("clicked", self.save)
        header = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(save)
        view = Adw.ToolbarView(content=page)
        view.add_top_bar(header)
        self.set_child(view)

    def save(self, *_):
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
            self.path.set_title("路徑（SMB 需填共用資料夾）")
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
        self.rebuild()

    def hide_to_tray(self, *_):
        self.set_visible(False)
        return True

    def tray_entries(self):
        entries = [(s["name"], enclosing_mount(server_uri(s)) is not None, lambda s=s: self.toggle(s))
                   for s in self.servers]
        if entries:
            entries.append((None, None, None))
        return entries + [("開啟 Hamasen", None, self.present), ("結束", None, self.get_application().quit)]

    def toggle(self, server):
        if enclosing_mount(server_uri(server)):
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

    def row(self, s):
        mounted = enclosing_mount(server_uri(s)) is not None
        row = Adw.ActionRow(title=GLib.markup_escape_text(s["name"]),
                            subtitle=GLib.markup_escape_text(server_uri(s)), activatable=False)
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
                save_servers(self.servers)
                self.rebuild()
        dialog.choose(self, None, answered)

    def mount(self, server):
        cancellable = Gio.Cancellable()
        self.connecting[server["id"]] = cancellable

        def done(f, result):
            del self.connecting[server["id"]]
            try:
                f.mount_enclosing_volume_finish(result)
            except GLib.Error as e:
                if e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                    pass
                elif e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED) and enclosing_mount(server_uri(server)):
                    pass
                else:
                    self.show_error(server, e)
            self.rebuild()
        Gio.File.new_for_uri(server_uri(server)).mount_enclosing_volume(
            Gio.MountMountFlags.NONE, mount_operation(self, server), cancellable, done)
        self.rebuild()

    def show_error(self, server, error):
        hint = ""
        if error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED) and server["scheme"] == "smb":
            hint = "請在伺服器的路徑填入共用資料夾名稱。"
        elif error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.TIMED_OUT):
            hint = "主機沒有回應。請確認主機、連接埠與網路。"
        elif error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.FAILED_HANDLED):
            return  # the user dismissed the password dialog
        dialog = Adw.AlertDialog(heading=f"無法連線「{server['name']}」",
                                 body="\n".join(filter(None, [hint, error.message])))
        dialog.add_response("close", "關閉")
        dialog.present(self)

    def unmount(self, server):
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
