#!/usr/bin/env python3
"""
Tablet Dock Controller
Transforms the internal tablet touchscreen into a dedicated trackpad,
app launcher, and high-visibility keyboard controller for an external monitor.
Directly grabs /dev/input/event1 to prevent Wayland from stealing focus!
"""

import sys
import os
import time
import math
import subprocess
import signal
import threading

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib

import evdev
from evdev import UInput, ecodes as e

# -----------------------------------------------------------------------------
# Input Device Virtualization
# -----------------------------------------------------------------------------
MOUSE_CAPS = {
    e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_HWHEEL],
    e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE],
}

ALL_KEYS = [
    e.KEY_ESC, e.KEY_F1, e.KEY_F2, e.KEY_F3, e.KEY_F4, e.KEY_F5, e.KEY_F6,
    e.KEY_F7, e.KEY_F8, e.KEY_F9, e.KEY_F10, e.KEY_F11, e.KEY_F12, e.KEY_DELETE,
    e.KEY_GRAVE, e.KEY_1, e.KEY_2, e.KEY_3, e.KEY_4, e.KEY_5, e.KEY_6, e.KEY_7,
    e.KEY_8, e.KEY_9, e.KEY_0, e.KEY_MINUS, e.KEY_EQUAL, e.KEY_BACKSPACE,
    e.KEY_TAB, e.KEY_Q, e.KEY_W, e.KEY_E, e.KEY_R, e.KEY_T, e.KEY_Y, e.KEY_U,
    e.KEY_I, e.KEY_O, e.KEY_P, e.KEY_LEFTBRACE, e.KEY_RIGHTBRACE, e.KEY_BACKSLASH,
    e.KEY_CAPSLOCK, e.KEY_A, e.KEY_S, e.KEY_D, e.KEY_F, e.KEY_G, e.KEY_H,
    e.KEY_J, e.KEY_K, e.KEY_L, e.KEY_SEMICOLON, e.KEY_APOSTROPHE, e.KEY_ENTER,
    e.KEY_LEFTSHIFT, e.KEY_Z, e.KEY_X, e.KEY_C, e.KEY_V, e.KEY_B, e.KEY_N,
    e.KEY_M, e.KEY_COMMA, e.KEY_DOT, e.KEY_SLASH, e.KEY_RIGHTSHIFT,
    e.KEY_LEFTCTRL, e.KEY_LEFTMETA, e.KEY_LEFTALT, e.KEY_SPACE, e.KEY_RIGHTALT,
    e.KEY_RIGHTCTRL, e.KEY_UP, e.KEY_DOWN, e.KEY_LEFT, e.KEY_RIGHT,
    e.KEY_PAGEUP, e.KEY_PAGEDOWN, e.KEY_HOME, e.KEY_END
]
KEYBOARD_CAPS = {
    e.EV_KEY: ALL_KEYS
}

# -----------------------------------------------------------------------------
# Clean, High-Contrast GTK3 CSS
# -----------------------------------------------------------------------------
STYLE_CSS = b"""
window, window * {
    -gtk-icon-effect: none;
}
window {
    background-color: #0b0e14;
}
button {
    background-image: none;
    box-shadow: none;
    text-shadow: none;
    border-radius: 6px;
    outline: none;
}
.top-bar {
    background-color: #151922;
    border-bottom: 2px solid #283040;
    padding: 6px 10px;
}
.title-label {
    color: #58a6ff;
    font-weight: 800;
    font-size: 15px;
}
button.launcher-btn {
    background-color: #1c2331;
    border: 1px solid #388bfd;
    padding: 6px 12px;
}
button.launcher-btn label {
    color: #ffffff;
    font-size: 13px;
    font-weight: 800;
}
button.action-btn {
    background-color: #222a38;
    border: 1px solid #4f5d75;
    padding: 6px 12px;
}
button.action-btn label {
    color: #ffffff;
    font-size: 13px;
    font-weight: 800;
}
button.exit-btn {
    background-color: #b91c1c;
    border: 2px solid #ef4444;
    padding: 6px 18px;
}
button.exit-btn label {
    color: #ffffff;
    font-size: 14px;
    font-weight: 900;
}
.trackpad-area {
    background-color: #10141d;
    border: 2px dashed #283040;
    border-radius: 10px;
    margin: 4px 8px;
}
.trackpad-hint {
    color: #7d8b9e;
    font-size: 15px;
    font-weight: 700;
}
button.mouse-btn {
    background-color: #1b2230;
    border: 2px solid #354259;
    border-radius: 8px;
    padding: 10px;
    min-height: 48px;
}
button.mouse-btn label {
    color: #ffffff;
    font-size: 16px;
    font-weight: 900;
}
button.mouse-btn.active {
    background-color: #1f6feb;
    border-color: #79c0ff;
}
.keyboard-box {
    background-color: #0d1117;
    border-top: 2px solid #283040;
    padding: 4px 8px 6px 8px;
}
button.key-btn {
    background-color: #1e2636;
    border: 2px solid #384661;
    border-radius: 6px;
    min-height: 46px;
    padding: 2px;
}
button.key-btn label {
    color: #ffffff;
    font-size: 19px;
    font-weight: 900;
}
button.key-btn.active {
    background-color: #1f6feb;
    border-color: #79c0ff;
}
button.key-special {
    background-color: #2b3547;
    border: 2px solid #4a5c7d;
}
button.key-special label {
    color: #e2e8f0;
    font-size: 14px;
    font-weight: 900;
}
button.key-btn.modifier-active {
    background-color: #d97706;
    border: 2px solid #fbbf24;
}
button.key-btn.modifier-active label {
    color: #ffffff;
    font-weight: 900;
}
"""

class TabletDockController(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_title("Tablet Dock Controller")
        self.set_default_size(1280, 800)
        
        self.set_accept_focus(False)
        self.set_focus_on_map(False)

        # Initialize UInput virtual devices
        try:
            self.v_mouse = UInput(MOUSE_CAPS, name="rk-dock-virtual-mouse")
            self.v_keyboard = UInput(KEYBOARD_CAPS, name="rk-dock-virtual-keyboard")
        except Exception as ex:
            print(f"Error creating uinput devices: {ex}", file=sys.stderr)
            sys.exit(1)

        self.sensitivity = 1.3
        self.keyboard_shown = True
        self.running = True

        # Modifiers state
        self.mod_ctrl = False
        self.mod_alt = False
        self.mod_shift = False
        self.mod_super = False
        self.mod_caps = False

        self.key_widgets = {}   # code -> Gtk.Button
        self.mouse_widgets = {} # btn_code -> Gtk.Button
        self.top_widgets = []   # list of (Gtk.Button, callback)
        self.hitboxes = []

        self._load_css()
        self._build_ui()
        self._position_on_internal_display()

        self.connect("size-allocate", self._on_size_allocate)

        # Start hardware input interception thread
        self.ts_device = None
        self._init_touchscreen()

    def _load_css(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(STYLE_CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    def _position_on_internal_display(self):
        display = Gdk.Display.get_default()
        screen = Gdk.Screen.get_default()
        n_monitors = display.get_n_monitors()
        target_idx = 0
        for i in range(n_monitors):
            mon = display.get_monitor(i)
            geom = mon.get_geometry()
            # DSI-1 is 1280x800 in landscape
            if geom.width == 1280 and geom.height == 800:
                target_idx = i
                break
        self.fullscreen_on_monitor(screen, target_idx)

    def _build_ui(self):
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        # Margin top leaves clear space below Phosh top bar (clock & status)
        main_box.set_margin_top(44)
        self.add(main_box)

        # 1. Top Bar
        top_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        top_bar.get_style_context().add_class("top-bar")

        title = Gtk.Label(label="💻 Dock Controller")
        title.get_style_context().add_class("title-label")
        top_bar.pack_start(title, False, False, 4)

        btn_chrom = Gtk.Button(label="🌐 Chromium")
        btn_chrom.set_can_focus(False)
        btn_chrom.get_style_context().add_class("launcher-btn")
        self.top_widgets.append((btn_chrom, lambda: self._launch_app("chromium")))
        top_bar.pack_start(btn_chrom, False, False, 2)

        btn_term = Gtk.Button(label="💻 Terminal")
        btn_term.set_can_focus(False)
        btn_term.get_style_context().add_class("launcher-btn")
        self.top_widgets.append((btn_term, lambda: self._launch_app("kgx")))
        top_bar.pack_start(btn_term, False, False, 2)

        btn_files = Gtk.Button(label="📁 Files")
        btn_files.set_can_focus(False)
        btn_files.get_style_context().add_class("launcher-btn")
        self.top_widgets.append((btn_files, lambda: self._launch_app("nautilus")))
        top_bar.pack_start(btn_files, False, False, 2)

        sep = Gtk.Box()
        top_bar.pack_start(sep, True, True, 0)

        sens_label = Gtk.Label(label=f"Speed: {self.sensitivity:.1f}x")
        sens_label.set_can_focus(False)
        self.sens_label = sens_label
        sens_label.get_style_context().add_class("action-btn")

        btn_sens_down = Gtk.Button(label=" - ")
        btn_sens_down.set_can_focus(False)
        btn_sens_down.get_style_context().add_class("action-btn")
        self.top_widgets.append((btn_sens_down, lambda: self._change_sens(-0.2)))

        btn_sens_up = Gtk.Button(label=" + ")
        btn_sens_up.set_can_focus(False)
        btn_sens_up.get_style_context().add_class("action-btn")
        self.top_widgets.append((btn_sens_up, lambda: self._change_sens(0.2)))

        top_bar.pack_start(btn_sens_down, False, False, 1)
        top_bar.pack_start(sens_label, False, False, 1)
        top_bar.pack_start(btn_sens_up, False, False, 1)

        self.btn_toggle_kb = Gtk.Button(label="⌨ Keyboard")
        self.btn_toggle_kb.set_can_focus(False)
        self.btn_toggle_kb.get_style_context().add_class("action-btn")
        self.top_widgets.append((self.btn_toggle_kb, self._toggle_keyboard))
        top_bar.pack_start(self.btn_toggle_kb, False, False, 4)

        btn_exit = Gtk.Button(label="✖ Exit Dock")
        btn_exit.set_can_focus(False)
        btn_exit.get_style_context().add_class("exit-btn")
        self.top_widgets.append((btn_exit, self._exit_dock_mode))
        top_bar.pack_end(btn_exit, False, False, 4)

        main_box.pack_start(top_bar, False, False, 0)

        # 2. Trackpad Area
        self.trackpad_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.trackpad_box.get_style_context().add_class("trackpad-area")

        pad_center = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        pad_center.set_valign(Gtk.Align.CENTER)
        pad_center.set_halign(Gtk.Align.CENTER)
        hint1 = Gtk.Label(label="👆 Touchpad Surface")
        hint1.get_style_context().add_class("trackpad-hint")
        hint2 = Gtk.Label(label="Slide: Move Pointer | Tap: Left Click | 2 Fingers: Scroll | Thumb: Left Click Button")
        hint2.get_style_context().add_class("trackpad-hint")
        pad_center.pack_start(hint1, False, False, 0)
        pad_center.pack_start(hint2, False, False, 0)
        self.trackpad_box.pack_start(pad_center, True, True, 0)

        # Mouse Click Buttons (Left, Middle, Right)
        btn_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        btn_bar.set_margin_start(8)
        btn_bar.set_margin_end(8)
        btn_bar.set_margin_bottom(4)

        btn_left = Gtk.Button(label="LEFT CLICK")
        btn_left.set_can_focus(False)
        btn_left.get_style_context().add_class("mouse-btn")
        self.mouse_widgets[e.BTN_LEFT] = btn_left

        btn_mid = Gtk.Button(label="MIDDLE")
        btn_mid.set_can_focus(False)
        btn_mid.get_style_context().add_class("mouse-btn")
        self.mouse_widgets[e.BTN_MIDDLE] = btn_mid

        btn_right = Gtk.Button(label="RIGHT CLICK")
        btn_right.set_can_focus(False)
        btn_right.get_style_context().add_class("mouse-btn")
        self.mouse_widgets[e.BTN_RIGHT] = btn_right

        btn_bar.pack_start(btn_left, True, True, 0)
        btn_bar.pack_start(btn_mid, False, False, 0)
        btn_bar.pack_start(btn_right, True, True, 0)
        self.trackpad_box.pack_end(btn_bar, False, False, 0)

        main_box.pack_start(self.trackpad_box, True, True, 0)

        # 3. Virtual Keyboard Box
        self.keyboard_container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.keyboard_container.get_style_context().add_class("keyboard-box")
        self._build_keyboard_layout()
        main_box.pack_end(self.keyboard_container, False, False, 0)

    def _on_size_allocate(self, widget, allocation):
        GLib.idle_add(self._refresh_hitboxes)

    def _refresh_hitboxes(self):
        new_hitboxes = []
        # 1. Top bar action buttons
        for btn, action in self.top_widgets:
            coords = btn.translate_coordinates(self, 0, 0)
            alloc = btn.get_allocation()
            if coords and alloc.width > 0 and alloc.height > 0:
                tx, ty = coords
                new_hitboxes.append((tx, ty, tx + alloc.width, ty + alloc.height, "TOP", action, btn))

        # 2. Mouse buttons (LEFT, MIDDLE, RIGHT)
        for btn_code, btn in self.mouse_widgets.items():
            coords = btn.translate_coordinates(self, 0, 0)
            alloc = btn.get_allocation()
            if coords and alloc.width > 0 and alloc.height > 0:
                tx, ty = coords
                new_hitboxes.append((tx, ty, tx + alloc.width, ty + alloc.height, "MOUSE", btn_code, btn))

        # 3. Keyboard keys
        if self.keyboard_shown:
            for key_code, btn in self.key_widgets.items():
                coords = btn.translate_coordinates(self, 0, 0)
                alloc = btn.get_allocation()
                if coords and alloc.width > 0 and alloc.height > 0:
                    tx, ty = coords
                    new_hitboxes.append((tx, ty, tx + alloc.width, ty + alloc.height, "KEY", key_code, btn))

        self.hitboxes = new_hitboxes

    # -------------------------------------------------------------------------
    # App Launching & Controls
    # -------------------------------------------------------------------------
    def _launch_app(self, app_cmd):
        def _runner():
            for _ in range(35):
                self.v_mouse.write(e.EV_REL, e.REL_X, -60)
                self.v_mouse.write(e.EV_REL, e.REL_Y, -40)
                self.v_mouse.syn()
                time.sleep(0.005)
            for _ in range(15):
                self.v_mouse.write(e.EV_REL, e.REL_X, 30)
                self.v_mouse.write(e.EV_REL, e.REL_Y, 20)
                self.v_mouse.syn()
                time.sleep(0.005)
            
            self.v_mouse.write(e.EV_KEY, e.BTN_LEFT, 1)
            self.v_mouse.syn()
            time.sleep(0.04)
            self.v_mouse.write(e.EV_KEY, e.BTN_LEFT, 0)
            self.v_mouse.syn()

            env = dict(os.environ)
            env["WAYLAND_DISPLAY"] = "wayland-0"
            subprocess.Popen([app_cmd], env=env)

        threading.Thread(target=_runner, daemon=True).start()

    def _change_sens(self, delta):
        self.sensitivity = max(0.4, min(3.0, self.sensitivity + delta))
        self.sens_label.set_text(f"Speed: {self.sensitivity:.1f}x")

    def _toggle_keyboard(self):
        self.keyboard_shown = not self.keyboard_shown
        self.keyboard_container.set_visible(self.keyboard_shown)
        self.btn_toggle_kb.set_label("⌨ Keyboard: ON" if self.keyboard_shown else "⌨ Keyboard: OFF")
        GLib.idle_add(self._refresh_hitboxes)

    # -------------------------------------------------------------------------
    # High-Visibility Keyboard Layout Construction
    # -------------------------------------------------------------------------
    def _build_keyboard_layout(self):
        for child in self.keyboard_container.get_children():
            self.keyboard_container.remove(child)
        self.key_widgets.clear()

        shift = self.mod_shift or self.mod_caps

        r0_keys = [
            ("Esc", e.KEY_ESC, 1.2),
            ("F1", e.KEY_F1, 1), ("F2", e.KEY_F2, 1), ("F3", e.KEY_F3, 1), ("F4", e.KEY_F4, 1),
            ("F5", e.KEY_F5, 1), ("F6", e.KEY_F6, 1), ("F7", e.KEY_F7, 1), ("F8", e.KEY_F8, 1),
            ("F9", e.KEY_F9, 1), ("F10", e.KEY_F10, 1), ("F11", e.KEY_F11, 1), ("F12", e.KEY_F12, 1),
            ("Del", e.KEY_DELETE, 1.2),
        ]
        r1_keys = [
            ("~" if shift else "`", e.KEY_GRAVE, 1),
            ("!" if shift else "1", e.KEY_1, 1), ("@" if shift else "2", e.KEY_2, 1),
            ("#" if shift else "3", e.KEY_3, 1), ("$" if shift else "4", e.KEY_4, 1),
            ("%" if shift else "5", e.KEY_5, 1), ("^" if shift else "6", e.KEY_6, 1),
            ("&" if shift else "7", e.KEY_7, 1), ("*" if shift else "8", e.KEY_8, 1),
            ("(" if shift else "9", e.KEY_9, 1), (")" if shift else "0", e.KEY_0, 1),
            ("_" if shift else "-", e.KEY_MINUS, 1), ("+" if shift else "=", e.KEY_EQUAL, 1),
            ("⌫ Back", e.KEY_BACKSPACE, 1.8),
        ]
        r2_keys = [
            ("Tab", e.KEY_TAB, 1.4),
            ("Q", e.KEY_Q, 1), ("W", e.KEY_W, 1), ("E", e.KEY_E, 1), ("R", e.KEY_R, 1),
            ("T", e.KEY_T, 1), ("Y", e.KEY_Y, 1), ("U", e.KEY_U, 1), ("I", e.KEY_I, 1),
            ("O", e.KEY_O, 1), ("P", e.KEY_P, 1),
            ("{" if shift else "[", e.KEY_LEFTBRACE, 1),
            ("}" if shift else "]", e.KEY_RIGHTBRACE, 1),
            ("|" if shift else "\\", e.KEY_BACKSLASH, 1),
        ]
        r3_keys = [
            ("Caps", "MOD_CAPS", 1.5),
            ("A", e.KEY_A, 1), ("S", e.KEY_S, 1), ("D", e.KEY_D, 1), ("F", e.KEY_F, 1),
            ("G", e.KEY_G, 1), ("H", e.KEY_H, 1), ("J", e.KEY_J, 1), ("K", e.KEY_K, 1),
            ("L", e.KEY_L, 1),
            (":" if shift else ";", e.KEY_SEMICOLON, 1),
            ("\"" if shift else "'", e.KEY_APOSTROPHE, 1),
            ("↵ Enter", e.KEY_ENTER, 2.0),
        ]
        r4_keys = [
            ("⇧ Shift", "MOD_SHIFT", 2.0),
            ("Z", e.KEY_Z, 1), ("X", e.KEY_X, 1), ("C", e.KEY_C, 1), ("V", e.KEY_V, 1),
            ("B", e.KEY_B, 1), ("N", e.KEY_N, 1), ("M", e.KEY_M, 1),
            ("<" if shift else ",", e.KEY_COMMA, 1),
            (">" if shift else ".", e.KEY_DOT, 1),
            ("?" if shift else "/", e.KEY_SLASH, 1),
            ("▲", e.KEY_UP, 1),
            ("⇧ Shift", "MOD_SHIFT", 1.5),
        ]
        r5_keys = [
            ("Ctrl", "MOD_CTRL", 1.4),
            ("❖ Super", "MOD_SUPER", 1.4),
            ("Alt", "MOD_ALT", 1.4),
            ("Space", e.KEY_SPACE, 5.0),
            ("Alt", "MOD_ALT", 1.2),
            ("Ctrl", "MOD_CTRL", 1.2),
            ("◀", e.KEY_LEFT, 1),
            ("▼", e.KEY_DOWN, 1),
            ("▶", e.KEY_RIGHT, 1),
        ]

        rows = [r0_keys, r1_keys, r2_keys, r3_keys, r4_keys, r5_keys]
        for row_data in rows:
            row_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=3)
            for label, code, weight in row_data:
                self._add_key_button(row_box, label, code, weight)
            self.keyboard_container.pack_start(row_box, False, False, 0)

        self.keyboard_container.show_all()

    def _add_key_button(self, box, label, code, weight):
        btn = Gtk.Button(label=label)
        btn.set_can_focus(False)
        btn.get_style_context().add_class("key-btn")

        if isinstance(code, str) or code in (e.KEY_ESC, e.KEY_ENTER, e.KEY_BACKSPACE, e.KEY_TAB, e.KEY_DELETE, e.KEY_UP, e.KEY_DOWN, e.KEY_LEFT, e.KEY_RIGHT):
            btn.get_style_context().add_class("key-special")

        if (code == "MOD_SHIFT" and self.mod_shift) or \
           (code == "MOD_CTRL" and self.mod_ctrl) or \
           (code == "MOD_ALT" and self.mod_alt) or \
           (code == "MOD_SUPER" and self.mod_super):
            btn.get_style_context().add_class("modifier-active")
        elif code == "MOD_CAPS" and self.mod_caps:
            btn.get_style_context().add_class("modifier-active")

        self.key_widgets[code] = btn
        box.pack_start(btn, True, True, 0)

    # -------------------------------------------------------------------------
    # Hardware Touchscreen Interception (Prevents Wayland focus stealing)
    # -------------------------------------------------------------------------
    def _init_touchscreen(self):
        devices = [evdev.InputDevice(p) for p in evdev.list_devices()]
        self.ts_device = next((d for d in devices if "gsl3673" in d.name), None)
        if not self.ts_device:
            print("[-] gsl3673 touchscreen not found!", file=sys.stderr)
            return

        print(f"[+] Grabbing touchscreen: {self.ts_device.path}")
        try:
            self.ts_device.grab()
        except Exception as ex:
            print(f"[-] Could not grab ts: {ex}", file=sys.stderr)

        t = threading.Thread(target=self._touch_loop, daemon=True)
        t.start()

    def _touch_loop(self):
        slot = 0
        tracking_ids = {} # slot -> id
        raw_x = {}        # slot -> x (0..800)
        raw_y = {}        # slot -> y (0..1280)
        last_x = {}       # slot -> screen_x
        last_y = {}       # slot -> screen_y
        touch_start_pos = {}  # slot -> (screen_x, screen_y)
        touch_start_time = {} # slot -> timestamp
        held_target = {}  # slot -> (type, id_or_code, widget)

        last_scroll_y = 0

        while self.running and self.ts_device:
            try:
                for ev in self.ts_device.read_loop():
                    if not self.running:
                        break

                    if ev.type == e.EV_ABS:
                        if ev.code == e.ABS_MT_SLOT:
                            slot = ev.value
                        elif ev.code == e.ABS_MT_TRACKING_ID:
                            tracking_ids[slot] = ev.value
                        elif ev.code == e.ABS_MT_POSITION_X:
                            raw_x[slot] = ev.value
                        elif ev.code == e.ABS_MT_POSITION_Y:
                            raw_y[slot] = ev.value

                    elif ev.type == e.EV_SYN and ev.code == e.SYN_REPORT:
                        now = time.time()
                        down_slots = [s for s, tid in tracking_ids.items() if tid >= 0]

                        # Emergency escape: 4 fingers touching anywhere exits immediately
                        if len(down_slots) >= 4:
                            GLib.idle_add(self._exit_dock_mode)
                            break

                        # 1. Process lifted fingers
                        for s in list(last_x.keys()):
                            if s not in down_slots:
                                sx, sy = touch_start_pos.pop(s, (0, 0))
                                st = touch_start_time.pop(s, now)
                                lx = last_x.pop(s, sx)
                                ly = last_y.pop(s, sy)

                                if s in held_target:
                                    t_type, t_val, widget = held_target.pop(s)
                                    if t_type == "KEY":
                                        self._release_key(t_val, widget)
                                    elif t_type == "MOUSE":
                                        self._release_mouse_button(t_val, widget)
                                    elif t_type == "TOP":
                                        if math.hypot(lx - sx, ly - sy) < 40:
                                            GLib.idle_add(t_val)
                                        if widget:
                                            GLib.idle_add(widget.get_style_context().remove_class, "active")
                                else:
                                    # Finger lifted from trackpad area: check for tap-to-click
                                    dist = math.hypot(lx - sx, ly - sy)
                                    dur = now - st
                                    if dist < 25 and dur < 0.35:
                                        self._tap_click(e.BTN_LEFT)

                                last_scroll_y = 0

                        # 2. Track active fingers and categorize (Button vs Trackpad)
                        trackpad_slots = []
                        for s in down_slots:
                            if s in raw_x and s in raw_y:
                                sx = raw_y[s]
                                sy = 800 - raw_x[s]

                                if s not in last_x:
                                    # New finger touch-down
                                    last_x[s] = sx
                                    last_y[s] = sy
                                    touch_start_pos[s] = (sx, sy)
                                    touch_start_time[s] = now

                                    target = self._find_hitbox(sx, sy)
                                    if target:
                                        held_target[s] = target
                                        t_type, t_val, widget = target
                                        if t_type == "KEY":
                                            self._press_key(t_val, widget)
                                        elif t_type == "MOUSE":
                                            self._press_mouse_button(t_val, widget)
                                        elif t_type == "TOP":
                                            GLib.idle_add(widget.get_style_context().add_class, "active")
                                    else:
                                        trackpad_slots.append(s)
                                else:
                                    # Continuing touch
                                    if s not in held_target:
                                        trackpad_slots.append(s)

                        # 3. Trackpad pointer movement and scrolling
                        if len(trackpad_slots) == 1:
                            # Single finger on trackpad -> MOVE POINTER
                            # (Works smoothly even when thumb is holding LEFT CLICK button!)
                            last_scroll_y = 0
                            s = trackpad_slots[0]
                            sx = raw_y[s]
                            sy = 800 - raw_x[s]
                            dx = sx - last_x[s]
                            dy = sy - last_y[s]
                            last_x[s] = sx
                            last_y[s] = sy

                            accel = 1.0 + min(1.5, math.hypot(dx, dy) / 16.0)
                            mx = int(dx * self.sensitivity * accel)
                            my = int(dy * self.sensitivity * accel)
                            if mx != 0 or my != 0:
                                self.v_mouse.write(e.EV_REL, e.REL_X, mx)
                                self.v_mouse.write(e.EV_REL, e.REL_Y, my)
                                self.v_mouse.syn()

                        elif len(trackpad_slots) >= 2:
                            # Two fingers on trackpad -> TWO-FINGER SCROLL
                            s1, s2 = trackpad_slots[0], trackpad_slots[1]
                            y1 = 800 - raw_x[s1]
                            y2 = 800 - raw_x[s2]
                            avg_y = (y1 + y2) / 2.0
                            if last_scroll_y != 0:
                                delta = avg_y - last_scroll_y
                                if abs(delta) >= 12:
                                    self.v_mouse.write(e.EV_REL, e.REL_WHEEL, int(delta / 12))
                                    self.v_mouse.syn()
                                    last_scroll_y = avg_y
                            else:
                                last_scroll_y = avg_y
                            last_x[s1] = raw_y[s1]
                            last_y[s1] = 800 - raw_x[s1]
                            last_x[s2] = raw_y[s2]
                            last_y[s2] = 800 - raw_x[s2]

            except Exception as ex:
                time.sleep(0.05)

    def _find_hitbox(self, x, y):
        for x1, y1, x2, y2, t_type, t_val, widget in getattr(self, "hitboxes", []):
            if x1 <= x <= x2 and y1 <= y <= y2:
                return (t_type, t_val, widget)
        return None

    def _tap_click(self, btn_code):
        self.v_mouse.write(e.EV_KEY, btn_code, 1)
        self.v_mouse.syn()
        time.sleep(0.04)
        self.v_mouse.write(e.EV_KEY, btn_code, 0)
        self.v_mouse.syn()

    def _press_mouse_button(self, btn_code, widget):
        self.v_mouse.write(e.EV_KEY, btn_code, 1)
        self.v_mouse.syn()
        if widget:
            GLib.idle_add(widget.get_style_context().add_class, "active")

    def _release_mouse_button(self, btn_code, widget):
        self.v_mouse.write(e.EV_KEY, btn_code, 0)
        self.v_mouse.syn()
        if widget:
            GLib.idle_add(widget.get_style_context().remove_class, "active")

    def _press_key(self, code, widget):
        if str(code).startswith("MOD_"):
            if code == "MOD_CTRL":
                self.mod_ctrl = not self.mod_ctrl
                self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTCTRL, 1 if self.mod_ctrl else 0)
            elif code == "MOD_ALT":
                self.mod_alt = not self.mod_alt
                self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTALT, 1 if self.mod_alt else 0)
            elif code == "MOD_SUPER":
                self.mod_super = not self.mod_super
                self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTMETA, 1 if self.mod_super else 0)
            elif code == "MOD_SHIFT":
                self.mod_shift = not self.mod_shift
                self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTSHIFT, 1 if self.mod_shift else 0)
            elif code == "MOD_CAPS":
                self.mod_caps = not self.mod_caps
                self.v_keyboard.write(e.EV_KEY, e.KEY_CAPSLOCK, 1)
                self.v_keyboard.syn()
                time.sleep(0.02)
                self.v_keyboard.write(e.EV_KEY, e.KEY_CAPSLOCK, 0)

            self.v_keyboard.syn()
            GLib.idle_add(self._build_keyboard_layout)
            return

        self.v_keyboard.write(e.EV_KEY, code, 1)
        self.v_keyboard.syn()
        if widget:
            GLib.idle_add(widget.get_style_context().add_class, "active")

    def _release_key(self, code, widget):
        if str(code).startswith("MOD_"):
            return

        self.v_keyboard.write(e.EV_KEY, code, 0)
        self.v_keyboard.syn()
        if widget:
            GLib.idle_add(widget.get_style_context().remove_class, "active")

        if self.mod_shift:
            self.mod_shift = False
            self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTSHIFT, 0)
            self.v_keyboard.syn()
            GLib.idle_add(self._build_keyboard_layout)

        if self.mod_ctrl or self.mod_alt or self.mod_super:
            if self.mod_ctrl:
                self.mod_ctrl = False
                self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTCTRL, 0)
            if self.mod_alt:
                self.mod_alt = False
                self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTALT, 0)
            if self.mod_super:
                self.mod_super = False
                self.v_keyboard.write(e.EV_KEY, e.KEY_LEFTMETA, 0)
            self.v_keyboard.syn()
            GLib.idle_add(self._build_keyboard_layout)

    def _exit_dock_mode(self, btn=None):
        self.cleanup()
        self.destroy()
        Gtk.main_quit()
        subprocess.run(["/usr/local/bin/dock-mode.sh", "disable"], check=False)

    def cleanup(self):
        self.running = False
        if self.ts_device:
            try:
                self.ts_device.ungrab()
            except:
                pass
            self.ts_device = None
        try:
            self.v_mouse.close()
            self.v_keyboard.close()
        except:
            pass


def main():
    app = TabletDockController()
    app.connect("destroy", lambda w: app.cleanup())
    app.show_all()

    def handle_sig(sig, frame):
        app.cleanup()
        Gtk.main_quit()

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    Gtk.main()
    app.cleanup()

if __name__ == "__main__":
    main()
