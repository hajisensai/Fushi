"""对拍 `convertAsrModelToFp16`（Dart 设备端整图 fp16 转换）产出的编码器与原 fp32 编码器。

流程：
1. `onnx.checker.check_model` 校验 fp16 图合法；
2. 在 DirectML 上按同一静态桶形状（`N` / `T` 用 free-dimension override 钉死）各建一个会话；
3. 同一批合成 log-mel 输入（含 pad 行）各跑若干次，报吞吐（帧/s）与输出偏差
   （只统计 `encoder_out_lens` 内的有效帧）；`encoder_out_lens` 必须逐元素相等、fp16 输出不得含 NaN。

用法（在仓库根）：

    dart run fushi/tool/asr_convert_fp16.dart --in <encoder.onnx> --out <encoder.fp16.onnx>
    python tool/asr/verify_fp16_encoder.py --fp32 <encoder.onnx> --fp16 <encoder.fp16.onnx> \
        [--batch 32] [--frames 560] [--batch-dim N] [--time-dim T] [--runs 10]

依赖：onnx、onnxruntime-directml（钉随包版本 1.22.0：1.24 建 DML 会话报 HasExternalDataInMemory）、numpy。
2026-09-07 RTX 5090 实测（英语 LibriHeavy zipformer）：32×560 fp32 55 ms / fp16 51 ms，
64×1120 fp32 149 ms / fp16 104 ms；有效帧绝对偏差均值 0.0026（相对 0.4%）、无 NaN。
"""
from __future__ import annotations

import argparse
import sys
import time

import numpy as np
import onnx
import onnxruntime as ort


def build_session(path: str, batch: int, frames: int, batch_dim: str, time_dim: str) -> ort.InferenceSession:
    so = ort.SessionOptions()
    so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    so.add_free_dimension_override_by_name(batch_dim, batch)
    so.add_free_dimension_override_by_name(time_dim, frames)
    return ort.InferenceSession(path, so, providers=["DmlExecutionProvider"])


def synth_input(batch: int, frames: int, seed: int = 0) -> tuple[np.ndarray, np.ndarray]:
    """类 log-mel 分布（均值 -8、方差 4），末行满长做哨兵，其余行随机长度、pad 值 log(1e-10)。"""
    rng = np.random.default_rng(seed)
    x = rng.normal(-8, 4, size=(batch, frames, 80)).astype(np.float32)
    lens = np.full((batch,), frames, dtype=np.int64)
    if batch > 1:
        lens[: batch - 1] = rng.integers(frames // 2, frames, size=batch - 1)
    for i in range(batch - 1):
        x[i, lens[i]:, :] = -23.025850929940457
    return x, lens


def run_timed(session: ort.InferenceSession, feed: dict, runs: int) -> tuple[list, float]:
    out = session.run(None, feed)
    t0 = time.perf_counter()
    for _ in range(runs):
        out = session.run(None, feed)
    return out, (time.perf_counter() - t0) / runs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fp32", required=True)
    ap.add_argument("--fp16", required=True)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--frames", type=int, default=560)
    ap.add_argument("--batch-dim", default="N")
    ap.add_argument("--time-dim", default="T")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--max-mean-abs-diff", type=float, default=0.02)
    args = ap.parse_args()

    m16 = onnx.load(args.fp16)
    onnx.checker.check_model(m16)
    print(f"checker ok; producer={m16.producer_name}")

    x, lens = synth_input(args.batch, args.frames)
    feed = {"x": x, "x_lens": lens}
    s32 = build_session(args.fp32, args.batch, args.frames, args.batch_dim, args.time_dim)
    (e32, l32), t32 = run_timed(s32, feed, args.runs)
    s16 = build_session(args.fp16, args.batch, args.frames, args.batch_dim, args.time_dim)
    (e16, l16), t16 = run_timed(s16, feed, args.runs)

    if not np.array_equal(l32, l16):
        print("FAIL: encoder_out_lens differ", file=sys.stderr)
        return 1
    valid = np.zeros(e32.shape, dtype=bool)
    for i in range(args.batch):
        valid[i, : l32[i], :] = True
    if np.isnan(e16[valid]).any():
        print("FAIL: NaN in fp16 output", file=sys.stderr)
        return 1
    d = np.abs(e32 - e16)[valid]
    ref = np.abs(e32[valid])
    area = args.batch * args.frames
    print(
        f"run fp32 {t32 * 1e3:.1f} ms ({area / t32:.0f} frames/s), "
        f"fp16 {t16 * 1e3:.1f} ms ({area / t16:.0f} frames/s), speedup {t32 / t16:.2f}x"
    )
    print(
        f"abs diff max {d.max():.4g} mean {d.mean():.4g}; ref max {ref.max():.4g} mean {ref.mean():.4g}; "
        f"rel(mean/mean) {d.mean() / ref.mean():.3g}"
    )
    if d.mean() > args.max_mean_abs_diff:
        print(f"FAIL: mean abs diff {d.mean():.4g} > {args.max_mean_abs_diff}", file=sys.stderr)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
