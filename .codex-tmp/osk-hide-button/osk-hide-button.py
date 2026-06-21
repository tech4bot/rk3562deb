#!/usr/bin/env python3

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")

from gi.repository import Gdk, Gio, GLib, Gtk, GtkLayerShell


BUS_NAME = "sm.puri.OSK0"
OBJECT_PATH = "/sm/puri/OSK0"
INTERFACE = "sm.puri.OSK0"


class OskHideButton:
    def __init__(self):
        self.proxy = None
        self.proxy_signal_id = None

        self.window = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.window.set_title("Hide Keyboard")
        self.window.set_decorated(False)
        self.window.set_resizable(False)
        self.window.set_skip_taskbar_hint(True)
        self.window.set_skip_pager_hint(True)
        self.window.set_keep_above(True)
        self.window.set_accept_focus(False)
        self.window.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.window.set_name("osk-hide-window")
        self.window.connect("delete-event", self.on_delete_event)

        if not GtkLayerShell.is_supported():
            raise RuntimeError("gtk-layer-shell is not supported in this session")

        GtkLayerShell.init_for_window(self.window)
        GtkLayerShell.set_layer(self.window, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.RIGHT, True)
        GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.BOTTOM, True)
        GtkLayerShell.set_keyboard_mode(self.window, GtkLayerShell.KeyboardMode.NONE)

        button = Gtk.Button()
        button.set_name("osk-hide-button")
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_focus_on_click(False)
        button.set_tooltip_text("Hide keyboard")
        button.connect("clicked", self.on_hide_clicked)

        image = Gtk.Image.new_from_icon_name("go-down-symbolic", Gtk.IconSize.LARGE_TOOLBAR)
        button.add(image)
        button.set_size_request(56, 56)

        self.window.add(button)
        self.install_css()
        self.update_position()
        self.window.hide()

        screen = Gdk.Screen.get_default()
        if screen is not None:
            screen.connect("monitors-changed", self.on_monitors_changed)
            screen.connect("size-changed", self.on_monitors_changed)

        Gio.bus_watch_name(
            Gio.BusType.SESSION,
            BUS_NAME,
            Gio.BusNameWatcherFlags.NONE,
            self.on_name_appeared,
            self.on_name_vanished,
        )

    def install_css(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(
            b"""
            #osk-hide-window {
              background: transparent;
            }
            #osk-hide-button {
              background: rgba(32, 36, 44, 0.92);
              border-radius: 28px;
              border: 1px solid rgba(255, 255, 255, 0.14);
              box-shadow: none;
              padding: 0;
            }
            #osk-hide-button:hover {
              background: rgba(52, 58, 70, 0.96);
            }
            #osk-hide-button:active {
              background: rgba(26, 30, 36, 0.98);
            }
            #osk-hide-button image {
              color: #ffffff;
            }
            """
        )
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def update_position(self):
        screen = Gdk.Screen.get_default()
        height = screen.get_height() if screen is not None else 720
        bottom_margin = max(18, height // 4)

        GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.RIGHT, 14)
        GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.BOTTOM, bottom_margin)

    def on_monitors_changed(self, *_args):
        self.update_position()

    def on_delete_event(self, *_args):
        self.window.hide()
        return True

    def on_name_appeared(self, connection, _name, _owner):
        try:
            proxy = Gio.DBusProxy.new_sync(
                connection,
                Gio.DBusProxyFlags.NONE,
                None,
                BUS_NAME,
                OBJECT_PATH,
                INTERFACE,
                None,
            )
        except GLib.Error:
            self.proxy = None
            self.window.hide()
            return

        self.proxy = proxy
        self.proxy_signal_id = proxy.connect("g-properties-changed", self.on_properties_changed)
        self.refresh_visibility()

    def on_name_vanished(self, *_args):
        if self.proxy is not None and self.proxy_signal_id is not None:
            self.proxy.disconnect(self.proxy_signal_id)
        self.proxy = None
        self.proxy_signal_id = None
        self.window.hide()

    def on_properties_changed(self, *_args):
        self.refresh_visibility()

    def is_visible(self):
        if self.proxy is None:
            return False

        value = self.proxy.get_cached_property("Visible")
        if value is None:
            return False

        return bool(value.unpack())

    def refresh_visibility(self):
        if self.is_visible():
            self.window.show_all()
        else:
            self.window.hide()

    def on_hide_clicked(self, *_args):
        if self.proxy is None:
            return

        try:
            self.proxy.call_sync(
                "SetVisible",
                GLib.Variant("(b)", (False,)),
                Gio.DBusCallFlags.NONE,
                -1,
                None,
            )
        except GLib.Error:
            return

        self.window.hide()


def main():
    app = OskHideButton()
    Gtk.main()


if __name__ == "__main__":
    main()
