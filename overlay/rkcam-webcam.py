#!/usr/bin/env python3
"""On-demand PipeWire bridge for the front camera.

The rkisp selfpath node is multi-planar, which PipeWire's V4L2 support cannot
open, so GStreamer offers the camera to PipeWire instead. Rather than streaming
permanently, the PipeWire source is fed from an appsrc and the camera (and the
rkisp1-awb gain feeder) only run while a client is linked to the source.
An always-running camera costs about 100 mA at idle on the Doogee U10.

While streaming, the bridge also
- crops the 4:3 sensor image to a centered 16:9 window, so 1280x720 is not
  stretched horizontally, and
- runs a gray-world auto white balance on the frames it forwards, handing new
  red/blue gains to rkisp1-awb through a gains file (there is no 3A daemon).
"""
import json
import os
import subprocess
import sys

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

import rkcam_awb  # noqa: E402

DEVICE = "/dev/video23"
NODE = "rkcam-webcam"
WIDTH, HEIGHT, FPS = 1280, 720, 30
CAPS = f"video/x-raw,format=UYVY,width={WIDTH},height={HEIGHT},framerate={FPS}/1"
BLACK_FRAME = bytes([0x80, 0x10]) * (WIDTH * HEIGHT)
AWB_UNIT = "rkisp1-awb.service"
STOP_DELAY_S = 3
RETRY_DELAY_S = 2

# Shared with rkisp1-awb; see rkcam_awb.py.
GAINS_FILE = os.path.expanduser("~/.cache/rkcam-webcam/awb-gains")
DEFAULT_GAINS = (512, 256, 256, 640)


def log(msg):
    print(f"rkcam-webcam: {msg}", file=sys.stderr, flush=True)


def set_crop_16_9(device):
    """Crop the selfpath input to a centered 16:9 window of the sensor image."""
    out = subprocess.run(["v4l2-ctl", "-d", device, "--get-selection",
                          "target=crop_bounds"], capture_output=True, text=True)
    fields = dict(part.strip().split(" ", 1)
                  for part in out.stdout.split(":", 1)[-1].split(",") if " " in part.strip())
    try:
        width, height = int(fields["Width"]), int(fields["Height"])
    except (KeyError, ValueError):
        log("crop bounds unavailable, keeping full sensor image")
        return
    crop_w, crop_h = width, width * 9 // 16 // 2 * 2
    if crop_h > height:
        crop_w, crop_h = height * 16 // 9 // 2 * 2, height
    left, top = (width - crop_w) // 2 // 2 * 2, (height - crop_h) // 2 // 2 * 2
    subprocess.run(["v4l2-ctl", "-d", device, "--set-selection",
                    f"target=crop,left={left},top={top},width={crop_w},height={crop_h}"])


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
        self.awb = rkcam_awb.WhiteBalance(GAINS_FILE, DEFAULT_GAINS)
        self.frames = 0

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
            # A bounded, leaky queue: pipewiresink blocks while a linked
            # client reads slower than 30 fps or pauses, and an unbounded
            # appsrc queue then grew until the OOM killer stopped the bridge.
            "appsrc name=src is-live=true format=time do-timestamp=true "
            "max-buffers=2 leaky-type=downstream ! "
            # enable-last-sample=false: the sink would otherwise keep the last
            # camera frame, whose driver buffer keeps /dev/video23 mapped.
            "pipewiresink mode=provide sync=false enable-last-sample=false "
            "stream-properties="
            '"props,media.class=Video/Source,media.role=Camera,'
            f'node.name={NODE},node.description=Front_Camera,node.nick=Front_Camera"'
        )
        self.src = self.out.get_by_name("src")
        self.src.set_property("caps", Gst.Caps.from_string(CAPS))
        self.out.get_bus().add_signal_watch()
        self.out.get_bus().connect("message::error", self.on_output_error)
        self.out.set_state(Gst.State.PLAYING)
        # One black frame negotiates the format so the source becomes visible.
        self.push_black()

    def push_black(self, count=1):
        for _ in range(count):
            self.src.emit("push-buffer", Gst.Buffer.new_wrapped(BLACK_FRAME))

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
        set_crop_16_9(DEVICE)
        self.frames = 0
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
        # If the last client went away mid-stream, pipewiresink is stuck
        # waiting for a buffer from it, holding a camera frame (which keeps
        # /dev/video23 mapped) and unable to serve the next client; a flush
        # wakes it but leaves the stream unable to start again. Rebuild the
        # source instead. This happens only once the camera is idle, never
        # between an app's probe and its real connection.
        if self.out and not self.wanted:
            GLib.idle_add(self.output_restart)

    def on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if not sample:
            return Gst.FlowReturn.OK
        frame = sample.get_buffer()
        self.frames += 1
        if self.frames % rkcam_awb.EVERY == 0:
            ok, info = frame.map(Gst.MapFlags.READ)
            if ok:
                try:
                    self.awb.update(rkcam_awb.sample_uyvy(info.data))
                finally:
                    frame.unmap(info)
        buf = frame.copy()
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
        err, _ = msg.parse_error()
        # pipewiresink posts "all buffers have been removed" whenever its
        # last client unlinks, including the probe connections apps make
        # before the real one. The stream itself stays connected, so keep the
        # same source: recreating it would give it a new node id and the
        # app's real connection would go to the vanished one (black image).
        if "all buffers have been removed" in err.message:
            return
        log(f"pipewire output reset: {err.message}")
        self.wanted = False
        if self.cam:
            self.camera_off()  # rebuilds the output once the camera is off
        else:
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
