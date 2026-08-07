from rknn.api import RKNN
rknn = RKNN(verbose=False)
rknn.config(target_platform='rk3562',
            mean_values=[[127.5, 127.5, 127.5]],
            std_values=[[127.5, 127.5, 127.5]])
assert rknn.load_onnx(model='mobilenetv2-12.onnx', inputs=['input'], input_size_list=[[1, 3, 224, 224]]) == 0, 'load_onnx failed'
# fp16 (no quantization) — smoke test exercises the NPU without needing a
# calibration dataset; INT8 conversion is documented in wiki 05 for real models
assert rknn.build(do_quantization=False) == 0, 'build failed'
assert rknn.export_rknn('mobilenet_v2_rk3562.rknn') == 0, 'export failed'
print('export OK')
