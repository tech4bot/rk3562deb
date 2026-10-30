"""Gray-world auto white balance for the rkisp cameras (there is no 3A daemon).

The caller samples frames it already has (UYVY from the front bridge, NV12 from
the rear preview) and passes them to WhiteBalance.update(); new red/blue gains
go to a gains file that rkisp1-awb feeds to the ISP while the camera streams.
"""
import os

# Gains are Q8 (256 = 1.0x). The file keeps the last result, so the next
# session starts from it.
GAIN_MIN, GAIN_MAX = 64, 4095
EVERY = 15          # frames between white balance updates
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
