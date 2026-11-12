#!/usr/bin/python3
# Copyright 2026 KoukeNeko
# Licensed under the Apache License, Version 2.0.
"""Hamasen for Linux: a GTK 4 / libadwaita front end that mounts servers into
the file manager, through GVfs where it has a backend and rclone where not."""
import os
import sys
import uuid
from urllib.parse import unquote, urlsplit

import gi

gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

from core import (APP_ID, HERE, MOUNT_ROOT, PROTOCOLS, RCLONE, REPO_URL, VERSION, autostart_enabled, enclosing_mount,  # noqa: E402
                  get_password, is_mounted, is_rclone, load_contributors, load_servers, mount_operation, mount_path,
                  pending_uploads_async, protocol_of, rc_socket, rclone_env, rclone_remote, run,
                  save_servers, server_uri, set_autostart, set_bookmark, set_password,
                  ssh_config_hosts)
from i18n import _, save_language, saved_language  # noqa: E402
from tray import Tray  # noqa: E402

GUIDE_URL = "https://console.cloud.google.com/apis/credentials"
# A checkout carries its own icon; a package installs it into the system theme.
ICON_DIR = os.path.join(HERE, "data", "icons")


def about_dialog():
    about = Adw.AboutDialog(
        application_icon=APP_ID, application_name=_("Hamasen"), developer_name="KoukeNeko", version=VERSION,
        comments=_("Mount servers and cloud drives in the file manager"), website=REPO_URL,
        issue_url=f"{REPO_URL}/issues", support_url=f"{REPO_URL}/blob/main/SUPPORT.md",
        copyright="© 2026 KoukeNeko", license_type=Gtk.License.APACHE_2_0)
    about.add_link(_("Privacy Policy"), f"{REPO_URL}/blob/main/PRIVACY.md")
    about.add_link(_("Contributors"), f"{REPO_URL}/graphs/contributors")
    about.add_legal_section(_("Trademarks"), None, Gtk.License.CUSTOM, _(
        "Google Drive is a trademark of Google LLC. OneDrive is a trademark of the Microsoft group of "
        "companies. Dropbox is a trademark of Dropbox, Inc. Other names are trademarks of their respective "
        "owners. Hamasen is not affiliated with or endorsed by the companies above."))
    load_contributors(lambda people: about.set_developers([f"{p['login']} {p['url']}" for p in people]))
    return about


def language_menu():
    menu = Gio.Menu()
    for code, label in (("auto", _("Automatic")), ("en", "English"), ("zh_TW", "繁體中文")):
        menu.append(label, f"win.language('{code}')")
    return menu


def menubar():
    """Exported to the desktop's global menu; libadwaita never draws it in the window itself."""
    server = Gio.Menu()
    server.append(_("Add Server"), "win.add-server")
    server.append(_("Import from SSH Config"), "win.import-ssh")
    server.append(_("About Hamasen"), "win.about")
    server.append(_("Quit"), "app.quit")
    settings = Gio.Menu()
    settings.append(_("Start at Login"), "win.autostart")
    settings.append_submenu(_("Language"), language_menu())
    bar = Gio.Menu()
    bar.append_submenu(_("Server"), server)
    bar.append_submenu(_("Settings"), settings)
    return bar


class ServerDialog(Adw.Dialog):
    def __init__(self, server, on_save):
        super().__init__(title=_("Server") if server else _("Add Server"), content_width=420)
        self.server, self.on_save = server or {}, on_save
        s = self.server

        self.name = Adw.EntryRow(title=_("Name"), text=s.get("name", ""))
        self.protocol = Adw.ComboRow(title=_("Protocol"), model=Gtk.StringList.new([p.label for p in PROTOCOLS]))
        self.protocol.set_selected(next((i for i, p in enumerate(PROTOCOLS) if p.scheme == s.get("scheme")), 0))
        self.host = Adw.EntryRow(text=s.get("host", ""))
        self.port = Adw.EntryRow(title=_("Port"), text=str(s.get("port") or ""), input_purpose=Gtk.InputPurpose.DIGITS)
        self.region = Adw.EntryRow(title=_("Region"), text=s.get("region", ""))
        self.user = Adw.EntryRow(text=s.get("user", ""))
        self.password = Adw.PasswordEntryRow(text=get_password(s["id"]) or "" if "id" in s else "")
        self.path = Adw.EntryRow(text=s.get("path", ""))
        self.auto_mount = Adw.SwitchRow(title=_("Mount at Login"), active=s.get("auto_mount", False))

        group = Adw.PreferencesGroup()
        self.remote_rows = (self.host, self.port, self.region, self.user, self.password, self.path)
        for row in (self.name, self.protocol) + self.remote_rows + (self.auto_mount,):
            group.add(row)

        # Google's shared rclone client ID is being retired, so offer a personal one.
        self.own_client = Adw.SwitchRow(title=_("Use Own Client ID"))
        self.client_id = Adw.EntryRow(title=_("Client ID"))
        self.client_secret = Adw.PasswordEntryRow(title=_("Client Secret"))
        guide = Gtk.Label(wrap=True, xalign=0, selectable=True, margin_top=6, margin_bottom=6, label=_(
            "1. Create a project in Google Cloud Console.\n"
            "2. Under APIs & Services > Library, enable the Google Drive API.\n"
            "3. Configure the OAuth consent screen and add the account in use as a test user.\n"
            "4. Under Credentials, create an OAuth client ID of type Desktop app.\n"
            "5. Enter the client ID and secret in the fields above."))
        console = Gtk.LinkButton(uri=GUIDE_URL, label=_("Open Google Cloud Console"), halign=Gtk.Align.START)
        self.guide_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin_start=12, margin_end=12)
        self.guide_box.append(guide)
        self.guide_box.append(console)
        self.drive_group = Adw.PreferencesGroup()
        for row in (self.own_client, self.client_id, self.client_secret, self.guide_box):
            self.drive_group.add(row)
        self.own_client.connect("notify::active", self.protocol_changed)
        self.protocol.connect("notify::selected", self.protocol_changed)
        self.protocol_changed()
        page = Adw.PreferencesPage()
        page.add(group)
        page.add(self.drive_group)

        cancel = Gtk.Button(label=_("Cancel"))
        cancel.connect("clicked", lambda *_: self.close())
        self.save_button = save = Gtk.Button(label=_("Save"), css_classes=["suggested-action"])
        save.connect("clicked", self.save)
        self.authorizing = None
        self.connect("closed", lambda *_: self.authorizing and self.authorizing.force_exit())
        header = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(save)
        view = Adw.ToolbarView(content=page)
        view.add_top_bar(header)
        self.set_child(view)

    @property
    def selected(self):
        return PROTOCOLS[self.protocol.get_selected()]

    def protocol_changed(self, *args):
        p = self.selected
        # Which rows a protocol uses, and what each is called there.
        titles = {
            "gvfs": (_("Host"), _("User"), _("Password"), _("Path")),
            "s3": (_("Endpoint (optional)"), _("Access Key ID"), _("Secret Access Key"), _("Bucket")),
        }
        if p.kind != "oauth":
            host, user, password, path = titles["s3" if p.kind == "s3" else "gvfs"]
            if p.scheme == "nfs":
                path = _("Export")
            self.host.set_title(host)
            self.user.set_title(user)
            self.password.set_title(password)
            self.path.set_title(path)
        shown = {
            "gvfs": (self.host, self.port, self.user, self.password, self.path),
            "s3": (self.host, self.region, self.user, self.password, self.path),
            "oauth": (),
        }[p.kind]
        if p.scheme == "nfs":
            shown = (self.host, self.path)
        for row in self.remote_rows:
            row.set_visible(row in shown)
        self.drive_group.set_visible(p.scheme == "gdrive" and not self.server.get("remote"))
        own = self.own_client.get_active()
        for row in (self.client_id, self.client_secret, self.guide_box):
            row.set_visible(own)

    def fail(self, heading, message):
        self.save_button.set_sensitive(True)
        self.save_button.set_label(_("Save"))
        if message:  # empty when the dialog was closed and rclone was stopped
            alert = Adw.AlertDialog(heading=heading, body=message)
            alert.add_response("close", _("Close"))
            alert.present(self)

    def commit(self, **fields):
        self.server.update(id=self.server.get("id") or str(uuid.uuid4()),
                           auto_mount=self.auto_mount.get_active(), **fields)
        self.on_save(self.server)
        self.close()

    def save_oauth(self, p):
        name = self.name.get_text().strip() or p.label
        if self.server.get("remote"):
            self.commit(name=name, scheme=p.scheme)
            return
        self.server.setdefault("id", str(uuid.uuid4()))
        remote = "hamasen-" + self.server["id"][:8]
        options = []
        if p.scheme == "gdrive" and self.own_client.get_active():
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
                self.fail(_("Cannot Authorize {service}").format(service=p.label), err)
                return
            self.commit(name=name, scheme=p.scheme, remote=remote)
        self.save_button.set_sensitive(False)
        self.save_button.set_label(_("Authorizing"))
        try:  # opens the browser for the sign-in and waits for it
            self.authorizing = run([RCLONE, "config", "create", remote, p.rclone_type, *options], authorized)
        except GLib.Error as e:
            authorized(False, e.message)

    def save_s3(self, p):
        key, secret = self.user.get_text().strip(), self.password.get_text()
        if not key or not secret:
            for row, text in ((self.user, key), (self.password, secret)):
                if not text:
                    row.add_css_class("error")
            return
        endpoint = self.host.get_text().strip()
        bucket = self.path.get_text().strip()
        self.server.setdefault("id", str(uuid.uuid4()))
        set_password(self.server["id"], secret)
        self.commit(name=self.name.get_text().strip() or bucket or p.label, scheme=p.scheme, host=endpoint,
                    region=self.region.get_text().strip(), user=key, path=bucket)

    def save(self, *args):
        p = self.selected
        if p.kind == "oauth":
            self.save_oauth(p)
            return
        if p.kind == "s3":
            self.save_s3(p)
            return
        host = self.host.get_text().strip()
        if not host:
            self.host.add_css_class("error")
            return
        scheme = p.scheme
        port = self.port.get_text().strip()
        user, path = self.user.get_text().strip(), self.path.get_text().strip()
        if "://" in host:  # a pasted URL fills in the other fields
            url = urlsplit(host)
            if url.scheme in [q.scheme for q in PROTOCOLS if q.kind == "gvfs"]:
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
            self.path.set_title(_("Path (SMB requires a share)"))
            return
        self.server.setdefault("id", str(uuid.uuid4()))
        set_password(self.server["id"], self.password.get_text())
        self.commit(name=self.name.get_text().strip() or host, scheme=scheme, host=host,
                    port=int(port) if port.isdigit() else None, user=user, path=path)


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title=_("Hamasen"), default_width=560, default_height=800)
        self.servers = load_servers()
        self.connecting = {}  # server id -> Gio.Cancellable of the mount in flight
        self.releasing = set()  # servers the user is unmounting, so their loss is not reported
        self.uploads = {}  # server id -> files rclone still has to upload
        self.polling = set()

        add = Gtk.Button(icon_name="list-add-symbolic", tooltip_text=_("Add Server"))
        add.connect("clicked", lambda *_: self.edit(None))
        menu = Gio.Menu()
        menu.append(_("Import from SSH Config"), "win.import-ssh")
        menu.append(_("Start at Login"), "win.autostart")
        menu.append_submenu(_("Language"), language_menu())
        menu.append(_("About Hamasen"), "win.about")
        header = Adw.HeaderBar()
        header.pack_start(add)
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu))

        about = Gio.SimpleAction.new("about", None)
        about.connect("activate", lambda *_: about_dialog().present(self))
        self.add_action(about)
        add_server = Gio.SimpleAction.new("add-server", None)
        add_server.connect("activate", lambda *_: self.edit(None))
        self.add_action(add_server)
        import_ssh = Gio.SimpleAction.new("import-ssh", None)
        import_ssh.connect("activate", lambda *_: self.import_ssh())
        autostart = Gio.SimpleAction.new_stateful("autostart", None, GLib.Variant.new_boolean(autostart_enabled()))
        autostart.connect("change-state", self.toggle_autostart)
        language = Gio.SimpleAction.new_stateful("language", GLib.VariantType.new("s"),
                                                 GLib.Variant.new_string(saved_language()))
        language.connect("change-state", self.change_language)
        self.add_action(language)
        self.add_action(import_ssh)
        self.add_action(autostart)

        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"],
                                margin_top=12, margin_bottom=12, margin_start=12, margin_end=12, valign=Gtk.Align.START)
        add_first = Gtk.Button(label=_("Add Server"), halign=Gtk.Align.CENTER, css_classes=["suggested-action", "pill"])
        add_first.connect("clicked", lambda *_: self.edit(None))
        self.empty = Adw.StatusPage(icon_name="network-server-symbolic", title=_("No Servers"), child=add_first)
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
        self.mounted = {s["id"] for s in self.servers if is_mounted(s)}
        GLib.timeout_add_seconds(3, self.poll_state)
        self.rebuild()

    # --- background state ---------------------------------------------------

    def notify(self, key, title, body):
        notification = Gio.Notification.new(title)
        notification.set_body(body)
        self.get_application().send_notification(key, notification)

    def poll_state(self):
        mounted = {s["id"] for s in self.servers if is_mounted(s)}
        for s in self.servers:
            if s["id"] in self.mounted - mounted - self.releasing:
                self.notify(f"lost-{s['id']}", _("Connection Lost"), s["name"])
        self.releasing &= mounted
        changed = mounted != self.mounted
        self.mounted = mounted
        for s in self.servers:
            if is_rclone(s) and s["id"] in mounted and s["id"] not in self.polling:
                self.polling.add(s["id"])
                pending_uploads_async(s, lambda n, s=s: self.polled(s, n))
        if changed:
            self.rebuild()
        return True

    def polled(self, server, count):
        self.polling.discard(server["id"])
        before = self.uploads.get(server["id"], 0)
        if before != count:
            self.uploads[server["id"]] = count
            if before and not count:
                self.notify(f"uploaded-{server['id']}", _("Uploads Complete"), server["name"])
            self.rebuild()

    def hide_to_tray(self, *_):
        self.set_visible(False)
        return True

    def tray_entries(self):
        entries = [(s["name"], is_mounted(s), lambda s=s: self.toggle(s)) for s in self.servers]
        if entries:
            entries.append((None, None, None))
        return entries + [(_("Open Hamasen"), None, self.present), (_("Quit"), None, self.get_application().quit)]

    def toggle(self, server):
        if is_mounted(server):
            self.unmount(server)
        elif server["id"] not in self.connecting:
            self.mount(server)

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text))

    # --- list -----------------------------------------------------------------

    def rebuild(self):
        self.list.remove_all()
        for s in self.servers:
            self.list.append(self.row(s))
        self.stack.set_visible_child_name("list" if self.servers else "empty")
        self.get_application().tray.refresh()

    def subtitle(self, s, mounted):
        if not is_rclone(s):
            return GLib.markup_escape_text(server_uri(s))
        pending = self.uploads.get(s["id"], 0) if mounted else 0
        label = protocol_of(s).label
        return _("{service} · Uploading {count}").format(service=label, count=pending) if pending else label

    def row(self, s):
        mounted = is_mounted(s)
        row = Adw.ActionRow(title=GLib.markup_escape_text(s["name"]), subtitle=self.subtitle(s, mounted),
                            activatable=False)
        if s["id"] not in self.connecting:
            row.add_prefix(Gtk.Image(icon_name="folder-remote-symbolic" if mounted else "network-server-symbolic"))
        for icon, tip, cb in (("document-edit-symbolic", _("Edit"), lambda *_: self.edit(s)),
                              ("user-trash-symbolic", _("Delete"), lambda *_: self.delete(s))):
            b = Gtk.Button(icon_name=icon, tooltip_text=tip, valign=Gtk.Align.CENTER, css_classes=["flat"])
            b.connect("clicked", cb)
            row.add_suffix(b)
        if mounted:
            open_btn = Gtk.Button(label=_("Open"), valign=Gtk.Align.CENTER)
            open_btn.connect("clicked", lambda *_: Gtk.UriLauncher(uri=server_uri(s)).launch(self, None, None, None))
            unmount = Gtk.Button(label=_("Unmount"), valign=Gtk.Align.CENTER)
            unmount.connect("clicked", lambda *_: self.unmount(s))
            row.add_suffix(open_btn)
            row.add_suffix(unmount)
        elif s["id"] in self.connecting:
            row.add_prefix(Gtk.Spinner(spinning=True))
            row.set_subtitle(_("Connecting"))
            cancel = Gtk.Button(label=_("Cancel"), valign=Gtk.Align.CENTER)
            cancel.connect("clicked", lambda *_: self.connecting[s["id"]].cancel())
            row.add_suffix(cancel)
        else:
            mount = Gtk.Button(label=_("Mount"), valign=Gtk.Align.CENTER, css_classes=["suggested-action"])
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
        dialog = Adw.AlertDialog(heading=_("Delete “{name}”?").format(name=server["name"]))
        dialog.add_response("cancel", _("Cancel"))
        dialog.add_response("delete", _("Delete"))
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE)

        def answered(d, result):
            if d.choose_finish(result) == "delete":
                self.servers.remove(server)
                set_password(server["id"], None)
                if is_rclone(server):
                    if is_mounted(server):
                        self.unmount(server)
                    if server.get("remote"):
                        run([RCLONE, "config", "delete", server["remote"]], lambda *_: None)
                save_servers(self.servers)
                self.rebuild()
        dialog.choose(self, None, answered)

    # --- settings menu --------------------------------------------------------

    def toggle_autostart(self, action, value):
        script = os.path.abspath(__file__)
        set_autostart(value.get_boolean(), script, sys.executable)
        action.set_state(value)

    def change_language(self, action, value):
        save_language(value.get_string())
        action.set_state(value)
        self.toast(_("Restart Hamasen to apply the language"))

    def import_ssh(self):
        known = {s["host"] for s in self.servers if s["scheme"] == "sftp"}
        fresh = [h for h in ssh_config_hosts() if h not in known]
        for host in fresh:
            self.servers.append({"id": str(uuid.uuid4()), "name": host, "scheme": "sftp", "host": host,
                                 "port": None, "user": "", "path": ""})
        if fresh:
            save_servers(self.servers)
            self.rebuild()
        self.toast(_("{count} servers imported").format(count=len(fresh)))

    # --- mounting -------------------------------------------------------------

    def mount(self, server):
        cancellable = Gio.Cancellable()
        self.connecting[server["id"]] = cancellable
        if is_rclone(server):
            self.mount_rclone(server, cancellable)
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

    def mount_rclone(self, server, cancellable):
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
                           "--rc", f"--rc-addr=unix://{rc_socket(server)}", rclone_remote(server), path],
                          done, env=rclone_env(server))
        except GLib.Error as e:
            done(False, e.message)
            return
        cancellable.connect(process.force_exit)
        self.rebuild()

    def mount_hint(self, server, error):
        if error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED) and server["scheme"] == "smb":
            return _("Specify the share name in the Path field.")
        if error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.TIMED_OUT):
            return _("The host did not respond. Check the host, port and network connection.")
        return ""

    def show_error(self, server, message, hint=""):
        heading = _("Cannot Connect to “{name}”").format(name=server["name"])
        body = "\n".join(filter(None, [hint, message]))
        if not self.is_visible():  # no window to show a dialog in
            self.notify(f"error-{server['id']}", heading, body)
            return
        dialog = Adw.AlertDialog(heading=heading, body=body)
        dialog.add_response("close", _("Close"))
        dialog.present(self)

    def unmount(self, server):
        self.releasing.add(server["id"])
        if is_rclone(server):
            def gone(ok, err):
                if ok:
                    set_bookmark(server, False)
                else:
                    self.releasing.discard(server["id"])
                    self.toast(err)
                self.rebuild()

            def eject():
                run(["fusermount3", "-u", mount_path(server)], gone)

            def checked(pending):
                if not pending:
                    eject()
                    return
                dialog = Adw.AlertDialog(heading=_("Unmount “{name}”?").format(name=server["name"]),
                                         body=_("{count} files have not been uploaded yet.").format(count=pending))
                dialog.add_response("cancel", _("Cancel"))
                dialog.add_response("unmount", _("Unmount Anyway"))
                dialog.set_response_appearance("unmount", Adw.ResponseAppearance.DESTRUCTIVE)

                def answered(d, result):
                    if d.choose_finish(result) == "unmount":
                        eject()
                    else:
                        self.releasing.discard(server["id"])
                dialog.choose(self, None, answered)
            pending_uploads_async(server, checked)
            return
        m = enclosing_mount(server_uri(server))
        if not m:
            return

        def done(mnt, result):
            try:
                mnt.unmount_with_operation_finish(result)
            except GLib.Error as e:
                self.releasing.discard(server["id"])
                self.toast(e.message)
            self.rebuild()
        m.unmount_with_operation(Gio.MountUnmountFlags.NONE, Gtk.MountOperation(parent=self), None, done)


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self.start_hidden = False
        self.add_main_option("background", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE,
                             "Start without a window", None)
        self.connect("handle-local-options", self.handle_options)

    def handle_options(self, _app, options):
        self.start_hidden = options.contains("background")
        return -1

    def do_startup(self):
        Adw.Application.do_startup(self)
        if os.path.isdir(ICON_DIR):
            Gtk.IconTheme.get_for_display(Gdk.Display.get_default()).add_search_path(ICON_DIR)
        self.hold()  # stays alive in the tray after the window is closed
        quit_action = Gio.SimpleAction.new("quit", None)
        quit_action.connect("activate", lambda *_: self.quit())
        self.add_action(quit_action)
        self.set_accels_for_action("app.quit", ["<Control>q"])
        self.set_accels_for_action("win.add-server", ["<Control>n"])
        self.set_menubar(menubar())
        self.tray = Tray(lambda: self.window.tray_entries(), lambda: self.window.present(), "network-server-symbolic")
        self.window = Window(self)
        GLib.timeout_add_seconds(2, self.mount_at_login)

    def mount_at_login(self):
        for s in self.window.servers:
            if s.get("auto_mount") and not is_mounted(s):
                self.window.mount(s)
        return False

    def do_activate(self):
        if self.start_hidden:
            self.start_hidden = False
            return
        self.window.present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv))
