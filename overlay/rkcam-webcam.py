#!/usr/bin/env python3
"""On-demand PipeWire bridge for the front camera.

The rkisp selfpath node is multi-planar, which PipeWire's V4L2 support cannot
open, so GStreamer offers the camera to PipeWire instead. Rather than streaming
permanently, the PipeWire source is fed from an appsrc and the camera (and the
rkisp1-awb gain feeder) only run while a client is linked to the source.
An always-running camera costs about 100 mA at idle on the Doogee U10.
"""
import json
import os
import subprocess
import sys

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

DEVICE = "/dev/video23"
NODE = "rkcam-webcam"
WIDTH, HEIGHT, FPS = 1280, 720, 30
CAPS = f"video/x-raw,format=UYVY,width={WIDTH},height={HEIGHT},framerate={FPS}/1"
AWB_UNIT = "rkisp1-awb.service"
STOP_DELAY_S = 3
RETRY_DELAY_S = 2


def log(msg):
    print(f"rkcam-webcam: {msg}", file=sys.stderr, flush=True)


class Bridge:
    def __init__(self):
        self.out = None
        self.src = None
        self.cam = None
        self.node_id = None
        self.wanted = False
        self.stop_source = 0
        self.retry_source = 0
        self.decoder = json.JSONDecoder()
        self.pending = ""

    def start(self):
        self.output_on()
        self.monitor = subprocess.Popen(
            ["pw-dump", "--monitor", "--no-colors"], stdout=subprocess.PIPE)
        GLib.unix_fd_add_full(GLib.PRIORITY_DEFAULT, self.monitor.stdout.fileno(),
                              GLib.IOCondition.IN | GLib.IOCondition.HUP,
                              self.on_monitor)

    # --- PipeWire source -----------------------------------------------
    def output_on(self):
        self.out = Gst.parse_launch(
            "appsrc name=src is-live=true format=time do-timestamp=true ! "
            "pipewiresink mode=provide sync=false stream-properties="
            '"props,media.class=Video/Source,media.role=Camera,'
            f'node.name={NODE},node.description=Front_Camera,node.nick=Front_Camera"'
        )
        self.src = self.out.get_by_name("src")
        self.src.set_property("caps", Gst.Caps.from_string(CAPS))
        self.out.get_bus().add_signal_watch()
        self.out.get_bus().connect("message::error", self.on_output_error)
        self.out.set_state(Gst.State.PLAYING)
        # One black frame negotiates the format so the source becomes visible.
        black = Gst.Buffer.new_wrapped(bytes([0x80, 0x10]) * (WIDTH * HEIGHT))
        self.src.emit("push-buffer", black)

    def output_restart(self):
        self.out.get_bus().remove_signal_watch()
        self.out.set_state(Gst.State.NULL)
        self.node_id = None
        self.output_on()
        return False

    # --- PipeWire node state -------------------------------------------
    def on_monitor(self, fd, condition):
        data = os.read(fd, 65536)
        if not data:
            log("pw-dump exited")
            loop.quit()
            return False
        self.pending += data.decode("utf-8", "replace")
        while True:
            text = self.pending.lstrip()
            if not text:
                self.pending = ""
                break
            try:
                objects, end = self.decoder.raw_decode(text)
            except ValueError:
                break  # incomplete JSON, wait for more lines
            self.pending = text[end:]
            for obj in objects if isinstance(objects, list) else []:
                self.on_object(obj)
        return True

    def on_object(self, obj):
        info = obj.get("info")
        if obj.get("type") == "PipeWire:Interface:Node" and info:
            if info.get("props", {}).get("node.name") == NODE:
                self.node_id = obj.get("id")
        if obj.get("id") != self.node_id or not info or "state" not in info:
            return
        self.set_wanted(info["state"] == "running")

    def set_wanted(self, wanted):
        if wanted == self.wanted:
            return
        self.wanted = wanted
        if wanted:
            if self.stop_source:
                GLib.source_remove(self.stop_source)
                self.stop_source = 0
            self.camera_on()
        elif self.cam and not self.stop_source:
            self.stop_source = GLib.timeout_add_seconds(STOP_DELAY_S, self.on_stop_timeout)

    def on_stop_timeout(self):
        self.stop_source = 0
        if not self.wanted:
            self.camera_off()
        return False

    # --- camera pipeline -----------------------------------------------
    def camera_on(self):
        if self.cam:
            return
        log("client connected, starting camera")
        self.cam = Gst.parse_launch(
            f"v4l2src device={DEVICE} io-mode=0 ! {CAPS} ! "
            "queue max-size-buffers=4 leaky=downstream ! "
            "appsink name=sink emit-signals=true sync=false max-buffers=2 drop=true")
        self.cam.get_by_name("sink").connect("new-sample", self.on_sample)
        self.cam.get_bus().add_signal_watch()
        self.cam.get_bus().connect("message::error", self.on_camera_error)
        self.cam.set_state(Gst.State.PLAYING)
        subprocess.run(["systemctl", "--user", "start", "--no-block", AWB_UNIT])

    def camera_off(self):
        if not self.cam:
            return
        log("no clients, stopping camera")
        subprocess.run(["systemctl", "--user", "stop", AWB_UNIT])
        self.cam.set_state(Gst.State.NULL)
        self.cam.get_bus().remove_signal_watch()
        self.cam = None

    def on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if sample:
            buf = sample.get_buffer().copy()
            buf.pts = buf.dts = Gst.CLOCK_TIME_NONE  # appsrc re-timestamps
            self.src.emit("push-buffer", buf)
        return Gst.FlowReturn.OK

    def on_camera_error(self, bus, msg):
        err, _ = msg.parse_error()
        log(f"camera error: {err.message}")
        self.camera_off()
        if self.wanted and not self.retry_source:
            self.retry_source = GLib.timeout_add_seconds(RETRY_DELAY_S, self.on_retry)

    def on_retry(self):
        self.retry_source = 0
        if self.wanted:
            self.camera_on()
        return False

    def on_output_error(self, bus, msg):
        # pipewiresink fails with "all buffers have been removed" whenever a
        # client unlinks; recreate the source instead of exiting.
        err, _ = msg.parse_error()
        log(f"pipewire output reset: {err.message}")
        self.wanted = False
        self.camera_off()
        GLib.idle_add(self.output_restart)


Gst.init(None)
loop = GLib.MainLoop()
bridge = Bridge()
bridge.start()
try:
    loop.run()
finally:
    bridge.camera_off()
    if bridge.out:
        bridge.out.set_state(Gst.State.NULL)
sys.exit(1)  # only reached on failure; systemd restarts the bridge
