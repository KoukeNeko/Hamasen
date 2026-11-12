# Copyright 2026 KoukeNeko
# Licensed under the Apache License, Version 2.0.
"""System tray icon over D-Bus: StatusNotifierItem plus a dbusmenu menu.

GTK 4 has no tray API and libappindicator is GTK 3, so the two small
interfaces the desktop's tray host (KDE, GNOME's AppIndicator extension,
waybar...) speaks are implemented here directly.
"""
import os

from gi.repository import Gio, GLib

ITEM_PATH, MENU_PATH = "/StatusNotifierItem", "/Menu"

ITEM_XML = """<node><interface name="org.kde.StatusNotifierItem">
 <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
 <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
 <property name="IconName" type="s" access="read"/><property name="IconThemePath" type="s" access="read"/><property name="ItemIsMenu" type="b" access="read"/>
 <property name="Menu" type="o" access="read"/>
 <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <signal name="NewIcon"/><signal name="NewStatus"><arg type="s"/></signal>
</interface></node>"""

MENU_XML = """<node><interface name="com.canonical.dbusmenu">
 <property name="Version" type="u" access="read"/><property name="Status" type="s" access="read"/>
 <property name="TextDirection" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
 <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
  <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
 <method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/>
  <arg type="a(ia{sv})" direction="out"/></method>
 <method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
 <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
 <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
 <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
 <method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
 <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>"""


class Tray:
    """`entries()` returns the menu as (label, checked, callback) tuples, where
    checked is None for a plain item and label None for a separator."""

    def __init__(self, entries, on_activate, icon_name, icon_theme_path=""):
        self.entries, self.on_activate, self.icon_name = entries, on_activate, icon_name
        self.icon_theme_path = icon_theme_path  # lets the tray host find an icon that is not installed
        self.revision = 0
        self.current = []
        self.bus = None
        Gio.bus_own_name(Gio.BusType.SESSION, f"org.kde.StatusNotifierItem-{os.getpid()}-1",
                         Gio.BusNameOwnerFlags.NONE, self._bus_acquired, self._name_acquired, None)

    def _bus_acquired(self, bus, name):
        self.bus = bus
        bus.register_object(ITEM_PATH, Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0],
                            self._item_call, self._item_prop, None)
        bus.register_object(MENU_PATH, Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0],
                            self._menu_call, self._menu_prop, None)

    def _name_acquired(self, bus, name):
        # No watcher (a desktop without a tray) just means no icon.
        bus.call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                 "RegisterStatusNotifierItem", GLib.Variant("(s)", (name,)), None,
                 Gio.DBusCallFlags.NONE, -1, None, None)

    def _item_prop(self, bus, sender, path, iface, prop):
        values = {"Category": ("s", "ApplicationStatus"), "Id": ("s", "hamasen"), "Title": ("s", "Hamasen"),
                  "Status": ("s", "Active"), "IconName": ("s", self.icon_name), "IconThemePath": ("s", self.icon_theme_path),
                  "ItemIsMenu": ("b", False), "Menu": ("o", MENU_PATH)}
        kind, value = values[prop]
        return GLib.Variant(kind, value)

    def _item_call(self, bus, sender, path, iface, method, params, invocation):
        if method in ("Activate", "SecondaryActivate"):
            self.on_activate()
        invocation.return_value(None)

    def _menu_prop(self, bus, sender, path, iface, prop):
        values = {"Version": ("u", 3), "Status": ("s", "normal"), "TextDirection": ("s", "ltr"),
                  "IconThemePath": ("as", [])}
        kind, value = values[prop]
        return GLib.Variant(kind, value)

    def _item_props(self, label, checked):
        if label is None:
            return {"type": GLib.Variant("s", "separator")}
        props = {"label": GLib.Variant("s", label)}
        if checked is not None:
            props["toggle-type"] = GLib.Variant("s", "checkmark")
            props["toggle-state"] = GLib.Variant("i", int(checked))
        return props

    def _menu_call(self, bus, sender, path, iface, method, params, invocation):
        if method == "GetLayout":
            self.current = self.entries()
            children = [GLib.Variant("(ia{sv}av)", (i + 1, self._item_props(label, checked), []))
                        for i, (label, checked, _) in enumerate(self.current)]
            root = (0, {"children-display": GLib.Variant("s", "submenu")}, children)
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (self.revision, root)))
        elif method == "GetGroupProperties":
            ids = params.unpack()[0] or range(len(self.current) + 1)
            props = [(i, self._item_props(*self.current[i - 1][:2]) if i else {}) for i in ids
                     if i <= len(self.current)]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (props,)))
        elif method == "Event":
            item_id, event = params.unpack()[:2]
            if event == "clicked" and 0 < item_id <= len(self.current):
                self.current[item_id - 1][2]()
            invocation.return_value(None)
        elif method == "AboutToShow":
            invocation.return_value(GLib.Variant("(b)", (False,)))
        elif method == "AboutToShowGroup":
            invocation.return_value(GLib.Variant("(aiai)", ([], [])))
        elif method == "EventGroup":
            invocation.return_value(GLib.Variant("(ai)", ([],)))
        else:  # GetProperty is optional for hosts that use GetLayout
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

    def refresh(self):
        if not self.bus:
            return
        self.revision += 1
        self.bus.emit_signal(None, MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated",
                             GLib.Variant("(ui)", (self.revision, 0)))
