"""Auto white balance and auto exposure for the rkisp cameras (there is no 3A
daemon).

The caller samples frames it already has (UYVY from the front bridge, NV12 from
the rear preview) and passes the samples to WhiteBalance.update() and
AutoExposure.update(). New red/blue gains go to a gains file that rkisp1-awb
feeds to the ISP while the camera streams; exposure and analogue gain are set
on the sensor directly.
"""
import fcntl
import glob
import os
import struct
import sys

DEBUG = os.environ.get("RKCAM_3A_DEBUG") == "1"

# Gains are Q8 (256 = 1.0x). The file keeps the last result, so the next
# session starts from it.
GAIN_MIN, GAIN_MAX = 64, 4095
EVERY = 8           # frames between white balance / exposure updates
STRIDE = 97         # sample every 97th chroma pair (~4.7k samples at 720p)
DEADBAND = 2        # mean U/V distance from neutral (128) left alone
MAX_STEP = 1.25     # largest gain change per update


def sample_uyvy(data):
    step = 4 * STRIDE
    return data[1::step], data[0::step], data[2::step]


def sample_nv12(data, width, height):
    """Y, U and V samples of an NV12 frame (tightly packed planes)."""
    luma = width * height
    if len(data) < luma * 3 // 2:
        return (), (), ()
    ys = []
    for k in range(0, luma // 4, STRIDE):
        row, col = divmod(k, width // 2)
        ys.append(data[2 * row * width + 2 * col])
    return ys, data[luma::2 * STRIDE], data[luma + 1::2 * STRIDE]


class WhiteBalance:
    """Steer the mean U/V of mid-tone pixels towards neutral."""

    def __init__(self, gains_file, default_gains):
        self.gains_file = gains_file
        self.gains = list(default_gains)
        try:
            with open(gains_file) as f:
                gains = [int(v) for v in f.read().split()]
            if len(gains) == 4 and all(GAIN_MIN <= g <= GAIN_MAX for g in gains):
                self.gains = gains
        except (OSError, ValueError):
            pass
        self.save()

    def save(self):
        os.makedirs(os.path.dirname(self.gains_file), exist_ok=True)
        tmp = self.gains_file + ".tmp"
        with open(tmp, "w") as f:
            f.write(" ".join(str(g) for g in self.gains) + "\n")
        os.replace(tmp, self.gains_file)

    def update(self, samples):
        n = sum_y = sum_u = sum_v = 0
        for y, u, v in zip(*samples):
            if 40 <= y <= 220:  # skip near-black noise and clipped highlights
                n += 1
                sum_y += y
                sum_u += u
                sum_v += v
        if n < 200:
            return
        y, du, dv = sum_y / n, sum_u / n - 128, sum_v / n - 128
        if abs(du) <= DEADBAND and abs(dv) <= DEADBAND:
            return
        # U ~ 0.564 (B - Y), V ~ 0.713 (R - Y): scale blue/red so they meet Y.
        # Half of the correction per step (square root) keeps the loop calm.
        gains = self.gains[:]
        for idx, d, k in ((3, du, 0.564), (0, dv, 0.713)):
            factor = (y / max(y + d / k, 1.0)) ** 0.5
            factor = min(max(factor, 1 / MAX_STEP), MAX_STEP)
            gains[idx] = int(min(max(gains[idx] * factor, GAIN_MIN), GAIN_MAX))
        if gains != self.gains:
            self.gains = gains
            self.save()


# Sensor controls (linux/videodev2.h)
V4L2_CID_EXPOSURE = 0x00980911
V4L2_CID_ANALOGUE_GAIN = 0x009e0903
VIDIOC_G_CTRL = 0xc008561b
VIDIOC_S_CTRL = 0xc008561c
VIDIOC_QUERYCTRL = 0xc0445624
QUERYCTRL = struct.Struct("II32siiiiI8x")

AE_TARGET = 110         # mean luma aimed for
AE_BLACK = 16           # luma at zero light; above it luma is ~linear
AE_DEADBAND = 0.12      # relative error left alone
AE_MAX_STEP = 4.0       # largest exposure change per update
AE_GAIN_MAX = 512       # analogue gain cap (32 = 1x), more is mostly noise


def find_subdev(name):
    """The /dev/v4l-subdevN whose sensor name contains name."""
    for path in sorted(glob.glob("/sys/class/video4linux/v4l-subdev*/name")):
        with open(path) as f:
            if name in f.read():
                return "/dev/" + path.split("/")[-2]
    return None


class AutoExposure:
    """Steer mean luma towards AE_TARGET: exposure time first, then gain."""

    def __init__(self, sensor_name):
        self.fd = None
        dev = find_subdev(sensor_name)
        if not dev:
            return
        try:
            self.fd = os.open(dev, os.O_RDWR)
            self.exp_min, self.exp_max = self.query(V4L2_CID_EXPOSURE)
            gain_min, gain_max = self.query(V4L2_CID_ANALOGUE_GAIN)
            self.gain_min, self.gain_max = gain_min, min(gain_max, AE_GAIN_MAX)
            self.settling = False
            self.exp = self.get(V4L2_CID_EXPOSURE)
            self.gain = self.get(V4L2_CID_ANALOGUE_GAIN)
        except OSError:
            self.close()

    def query(self, cid):
        buf = bytearray(QUERYCTRL.pack(cid, 0, b"", 0, 0, 0, 0, 0))
        fcntl.ioctl(self.fd, VIDIOC_QUERYCTRL, buf)
        _, _, _, lo, hi, _, _, _ = QUERYCTRL.unpack(buf)
        return lo, hi

    def get(self, cid):
        buf = bytearray(struct.pack("Ii", cid, 0))
        fcntl.ioctl(self.fd, VIDIOC_G_CTRL, buf)
        return struct.unpack("Ii", buf)[1]

    def set(self, cid, value):
        fcntl.ioctl(self.fd, VIDIOC_S_CTRL, bytearray(struct.pack("Ii", cid, value)))

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def update(self, ys):
        if self.fd is None or not ys:
            return
        # A new exposure shows up a few frames late: judge the frames of the
        # next interval only.
        if self.settling:
            self.settling = False
            return
        mean = sum(ys) / len(ys)
        if DEBUG:
            print(f"rkcam-3a: luma {mean:.1f} exposure {self.exp} gain {self.gain}",
                  file=sys.stderr, flush=True)
        if abs(mean - AE_TARGET) <= AE_DEADBAND * AE_TARGET:
            return
        factor = (AE_TARGET - AE_BLACK) / max(mean - AE_BLACK, 1.0)
        factor = min(max(factor, 1 / AE_MAX_STEP), AE_MAX_STEP)
        # Total exposure = lines x gain; use the longest exposure at the
        # lowest gain that reaches it.
        total = self.exp * self.gain * factor
        exp = int(min(max(total / self.gain_min, self.exp_min), self.exp_max))
        gain = int(min(max(total / exp, self.gain_min), self.gain_max))
        try:
            if exp != self.exp:
                self.set(V4L2_CID_EXPOSURE, exp)
                self.exp = exp
                self.settling = True
            if gain != self.gain:
                self.set(V4L2_CID_ANALOGUE_GAIN, gain)
                self.gain = gain
                self.settling = True
        except OSError:
            pass
