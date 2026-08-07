#!/usr/bin/env python3
"""Convert a HuggingFace LLM to a .rkllm model for the RK3562 NPU.

Runs inside the ~/venvs/rkllm environment (see setup-rkllm-conversion-env.sh);
normally invoked via convert-rkllm-model.sh.

Calibration data: per Rockchip_RKLLM_SDK_EN_1.3.0 Table 3-3, the `dataset`
parameter of rkllm.build() is optional, and the SDK's own w4a16 example
passes dataset=None. w4a16_* quantization only quantizes weights (activations
stay fp16), so no activation-calibration set is needed; we default to None.
For w8a8/w4a8 modes a JSON calibration file ([{"input": ..., "target": ...}])
can improve accuracy — pass it with --dataset.
"""
import argparse
import os
import sys

# Quant types supported by RK3562 per SDK 1.3.0 Table 3-3.
RK3562_QUANT_TYPES = ("w8a8", "w4a16_g32", "w4a16_g64", "w4a16_g128", "w4a8_g32")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("model", help="HuggingFace model ID (e.g. Qwen/Qwen3-0.6B) or local model dir")
    ap.add_argument("output", help="Output .rkllm path")
    ap.add_argument("--quantized-dtype", default="w4a16_g64", choices=RK3562_QUANT_TYPES)
    ap.add_argument("--dataset", default=None,
                    help="Optional JSON calibration dataset (see SDK 1.3.0 Table 3-3)")
    ap.add_argument("--optimization-level", type=int, default=1, choices=(0, 1))
    ap.add_argument("--max-context", type=int, default=None,
                    help="Optional max context length (<=16384, multiple of 32)")
    args = ap.parse_args()

    model_path = args.model
    if not os.path.isdir(model_path):
        from huggingface_hub import snapshot_download
        print(f"'{model_path}' is not a local directory; downloading from HuggingFace Hub ...")
        model_path = snapshot_download(repo_id=args.model)
        print(f"Model cached at {model_path}")

    from rkllm.api import RKLLM

    llm = RKLLM()
    ret = llm.load_huggingface(model=model_path, model_lora=None, device="cpu")
    if ret != 0:
        sys.exit(f"load_huggingface failed (ret={ret}) for {model_path}")

    build_kwargs = dict(
        do_quantization=True,
        optimization_level=args.optimization_level,
        quantized_dtype=args.quantized_dtype,
        quantized_algorithm="normal",  # "grq" needs GPU acceleration; CPU-only here
        target_platform="rk3562",
        num_npu_core=1,                # RK3562 supports [1] only (SDK 1.3.0 Table 3-3)
        extra_qparams=None,
        dataset=args.dataset,
    )
    if args.max_context is not None:
        build_kwargs["max_context"] = args.max_context
    ret = llm.build(**build_kwargs)
    if ret != 0:
        sys.exit(f"build failed (ret={ret})")

    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)
    ret = llm.export_rkllm(args.output)
    if ret != 0:
        sys.exit(f"export_rkllm failed (ret={ret})")

    size_mb = os.path.getsize(args.output) / (1024 * 1024)
    print(f"OK: {args.output} ({size_mb:.0f} MiB, {args.quantized_dtype}, rk3562)")


if __name__ == "__main__":
    main()
