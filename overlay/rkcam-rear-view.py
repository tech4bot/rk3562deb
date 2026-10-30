#!/usr/bin/env python3
"""Rear camera preview window with automatic white balance.

Plays the rkisp output (NV12) once setup_isp_rear.sh has routed the ISP to the
rear sensor. Like the front bridge, it runs a gray-world white balance on the
frames it shows and feeds the resulting gains to the ISP through rkisp1-awb,
with a gains file of its own (the rear sensor needs different gains).

Usage: rkcam-rear-view.py DEVICE WIDTH HEIGHT FPS SINK
"""
import os
import signal
import subprocess
import sys

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

import rkcam_awb  # noqa: E402

AWB_FEEDER = "/usr/local/bin/rkisp1-awb"
GAINS_FILE = os.path.expanduser("~/.cache/rkcam-webcam/awb-gains-rear")
DEFAULT_GAINS = (236, 256, 256, 389)  # converged under room light


def log(msg):
    print(f"[rkcam-rear-view] {msg}", file=sys.stderr, flush=True)


class RearView:
    def __init__(self, device, width, height, fps, sink):
        self.width, self.height = width, height
        self.awb = rkcam_awb.WhiteBalance(GAINS_FILE, DEFAULT_GAINS)
        self.frames = 0
        self.feeder = None
        self.rc = 0
        self.pipeline = Gst.parse_launch(
            f"v4l2src device={device} io-mode=0 do-timestamp=true ! "
            f"video/x-raw,format=NV12,width={width},height={height},"
            f"framerate={fps}/1 ! identity name=tap ! "
            "queue max-size-buffers=4 leaky=downstream ! "
            # videoscale: the window (1280x800 on the U10) is smaller than
            # the frame, and ximagesink does not scale by itself; it showed a
            # 1280x800 corner of the image, which looked zoomed in.
            f"videoconvert ! videoscale ! {sink} sync=false")
        self.pipeline.get_by_name("tap").get_static_pad("src").add_probe(
            Gst.PadProbeType.BUFFER, self.on_buffer)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message::error", self.on_error)
        bus.connect("message::eos", lambda *_: loop.quit())

    def run(self):
        self.pipeline.set_state(Gst.State.PLAYING)
        try:
            loop.run()
        finally:
            self.pipeline.set_state(Gst.State.NULL)
            self.feeder_stop()
        return self.rc

    def on_buffer(self, pad, info):
        self.frames += 1
        if self.frames == 1:
            # The ISP is streaming now, so the feeder's params are consumed.
            GLib.idle_add(self.feeder_start)
        if self.frames % rkcam_awb.EVERY == 0:
            buf = info.get_buffer()
            ok, mapping = buf.map(Gst.MapFlags.READ)
            if ok:
                try:
                    self.awb.update(rkcam_awb.sample_nv12(
                        mapping.data, self.width, self.height))
                finally:
                    buf.unmap(mapping)
        return Gst.PadProbeReturn.OK

    def feeder_start(self):
        try:
            self.feeder = subprocess.Popen(
                [AWB_FEEDER, *map(str, self.awb.gains), GAINS_FILE])
        except OSError as err:
            log(f"white balance unavailable: {err}")
        return False

    def feeder_stop(self):
        if self.feeder and self.feeder.poll() is None:
            self.feeder.terminate()
            try:
                self.feeder.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.feeder.kill()

    def on_error(self, bus, msg):
        err, _ = msg.parse_error()
        # Closing the window is the normal way to end the preview.
        if "window was closed" not in err.message:
            log(f"error: {err.message}")
            self.rc = 1
        loop.quit()


if len(sys.argv) != 6:
    sys.exit(__doc__.strip().splitlines()[-1])
Gst.init(None)
loop = GLib.MainLoop()
for sig in (signal.SIGINT, signal.SIGTERM):
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, loop.quit)
view = RearView(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                int(sys.argv[4]), sys.argv[5])
sys.exit(view.run())
