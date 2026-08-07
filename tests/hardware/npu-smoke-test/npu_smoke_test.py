#!/usr/bin/env python3
"""NPU smoke test for samwise (RK3562) — hardware test matrix row 17.

Loads an .rknn model with rknn-toolkit-lite2, runs inference on random
input, and reports timing. Pass criteria: runtime initializes against the
kernel driver and inference completes without error.

Usage: python3 npu_smoke_test.py <model.rknn> [iterations]
"""
import sys
import time

import numpy as np
from rknnlite.api import RKNNLite


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    model_path = sys.argv[1]
    iterations = int(sys.argv[2]) if len(sys.argv) > 2 else 20

    rknn = RKNNLite(verbose=False)
    print(f"[1/4] load_rknn({model_path})")
    if rknn.load_rknn(model_path) != 0:
        print("FAIL: load_rknn")
        return 1

    print("[2/4] init_runtime()  # this is where driver/runtime mismatch shows up")
    if rknn.init_runtime() != 0:
        print("FAIL: init_runtime — check dmesg, /sys/kernel/debug/rknpu/version,")
        print("      and that /sys/class/devfreq/ff300000.npu exists")
        return 1
    print("      runtime OK (SDK:", rknn.get_sdk_version(), ")")

    # Model-zoo classification models expect NHWC uint8 224x224x3; adjust if
    # the model differs. Random data is fine — we test execution, not accuracy.
    inp = np.random.randint(0, 256, (1, 224, 224, 3), dtype=np.uint8)

    print("[3/4] warm-up inference")
    out = rknn.inference(inputs=[inp])
    if out is None:
        print("FAIL: inference returned None")
        return 1

    print(f"[4/4] timing {iterations} iterations "
          f"(read /sys/kernel/debug/rknpu/load in another shell NOW)")
    t0 = time.perf_counter()
    for _ in range(iterations):
        rknn.inference(inputs=[inp])
    dt = (time.perf_counter() - t0) / iterations
    print(f"PASS: {iterations} inferences OK, mean {dt*1000:.1f} ms "
          f"({1/dt:.1f} fps), output shape {out[0].shape}")
    rknn.release()
    return 0


if __name__ == "__main__":
    sys.exit(main())
