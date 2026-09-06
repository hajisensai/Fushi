"""对拍 `buildAsrGreedyGraph`（Dart 运行时拼装的 RNN-T 贪心解码 Loop 图）与逐帧贪心参考。

流程：
1. `dart run fushi/tool/asr_build_greedy_graph.dart` 用真 decoder/joiner（int8 与 fp32 两套）
   以及 `fushi/test/asr/fixtures/` 的极小合成夹具各拼一张图；
2. `onnx.checker.check_model(full_check=True)`；
3. kaldi-native-fbank（参数同 `asr_fbank.dart` 文件头 / `gen_fbank_golden.py`）→ int8 encoder →
   `encoder_out`；
4. onnxruntime 跑 Loop 图一次，与 Python 逐帧贪心参考（同一 decoder/joiner ONNX、同一语义）
   逐元素比对 `emitted[N,T]`，打印解码文本与耗时；
5. batch=3、`encoder_out_lens` 不等长（含被截短的行）用例，验证超长帧一律不发射、上下文不更新。

参考实现有两种批处理方式（结果对 fp32 恒等，对 int8 见下）：
- `loop`：每帧对全部 N 行跑 decoder + joiner（与 Loop 图完全一致的算子输入）；
- `dart`：只对「仍有剩余帧」的行跑 joiner、只对「本帧发射」的行跑 decoder
  （与 `AsrTransducerDecoder` 一致）。
int8 模型里 `DynamicQuantizeLinear` 的 scale 是整批求 min/max 得出的，同一行和不同的行拼批
会得到不同的量化结果，因此 `dart` 模式与 Loop 图之间理论上允许极小差异；脚本把它单独报出
（`--strict-dart` 时也作为断言）。

用法（仓库根）：

    python tool/asr/verify_greedy_graph.py --models-dir <含 decoder/joiner/encoder/tokens 的目录> \
        [--wav fushi/test/asr/fixtures/ja_tts_16k.wav] [--dart D:/flutter_sdk/.../dart.bat] \
        [--out-dir <临时目录>] [--repeat 3] [--strict-dart] [--skip-real] [--skip-tiny]

依赖：onnx、onnxruntime、numpy、kaldi-native-fbank、soundfile（均 pip）。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np
import onnx
import onnxruntime as ort

# Windows 控制台默认代码页会把中文打成乱码。
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FUSHI = os.path.join(REPO, "fushi")
FIXTURES = os.path.join(FUSHI, "test", "asr", "fixtures")
NO_EMIT = -1


# ---------------------------------------------------------------------------
# CLI 入参消毒
#
# --dart / --models-dir / --out-dir / --wav 都会被直接拼进子进程命令行和文件路径。
# 这里在入口处一次性把它们解析成真实绝对路径并校验形态（可执行文件 / 目录 / 文件），
# 之后所有拼接都走 _child_path，越出给定根目录即拒绝——命令与路径都不再由未校验的
# 外部串直接决定。
# ---------------------------------------------------------------------------


def _checked_program(name: str) -> str:
    """把 --dart 解析成一个确实存在且可执行的绝对路径。"""
    candidate = shutil.which(name) if os.path.basename(name) == name else name
    if not candidate:
        raise SystemExit(f"找不到可执行文件：{name}")
    real = os.path.realpath(os.path.expanduser(candidate))
    if not os.path.isfile(real) or not os.access(real, os.X_OK):
        raise SystemExit(f"不是可执行文件：{name}")
    return real


def _checked_dir(label: str, path: str) -> str:
    """把目录参数解析成一个确实存在的绝对路径。不代为创建：脚本只往调用方给的、
    已经存在的目录里写（--out-dir 不存在就先 mkdir 再来），避免拿命令行参数去
    创建任意路径。"""
    real = os.path.realpath(os.path.expanduser(path))
    if not os.path.isdir(real):
        raise SystemExit(f"{label} 不是已存在的目录：{path}")
    return real


def _checked_file(label: str, path: str) -> str:
    real = os.path.realpath(os.path.expanduser(path))
    if not os.path.isfile(real):
        raise SystemExit(f"{label} 不存在：{path}")
    return real


def _child_path(base: str, *parts: str) -> str:
    """base 下的固定子路径；解析后仍必须落在 base 内（挡住 .. 与符号链接穿越）。"""
    real = os.path.realpath(os.path.join(base, *parts))
    if os.path.commonpath([real, base]) != base:
        raise SystemExit(f"路径越界：{os.path.join(*parts)} 不在 {base} 内")
    return real



# ---------------------------------------------------------------------------
# 构图
# ---------------------------------------------------------------------------


def build_graph(dart: str, decoder: str, joiner: str, out: str, blank: int, unk: int) -> None:
    cmd = [
        dart,
        "run",
        "tool/asr_build_greedy_graph.dart",
        "--decoder",
        decoder,
        "--joiner",
        joiner,
        "--out",
        out,
        "--blank",
        str(blank),
        "--unk",
        str(unk),
    ]
    t0 = time.perf_counter()
    res = subprocess.run(cmd, cwd=FUSHI, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stdout + res.stderr)
        raise SystemExit(f"构图失败：{' '.join(cmd)}")
    print(f"  [build] {os.path.basename(out)}: {res.stdout.strip()} (dart run 总耗时 {time.perf_counter() - t0:.1f}s)")


def check_graph(path: str) -> onnx.ModelProto:
    model = onnx.load(path)
    onnx.checker.check_model(model, full_check=True)
    loop = [n for n in model.graph.node if n.op_type == "Loop"]
    assert len(loop) == 1, "主图应恰有一个 Loop"
    body = loop[0].attribute[0].g
    carried = len(body.input) - 2
    gate = [n for n in body.node if n.op_type == "If"]
    assert len(gate) == 1, "body 应恰有一个 If（decoder 门控）"
    branches = {a.name: len(a.g.node) for a in gate[0].attribute}
    print(
        f"  [check] OK ir={model.ir_version} opset={[(o.domain, o.version) for o in model.opset_import]} "
        f"主图节点 {len(model.graph.node)} / initializer {len(model.graph.initializer)} / "
        f"body 节点 {len(body.node)}（If 分支节点 {branches}）/ "
        f"loop-carried {[i.name for i in body.input[2:]]} / scan {[o.name for o in body.output[1 + carried:]]}"
    )
    return model


# ---------------------------------------------------------------------------
# 参考贪心
# ---------------------------------------------------------------------------


def reference_greedy(
    dec: ort.InferenceSession,
    joi: ort.InferenceSession,
    encoder_out: np.ndarray,
    lens: np.ndarray,
    blank: int,
    unk: int,
    context: int,
    mode: str,
) -> np.ndarray:
    """逐帧贪心；返回 emitted[N,T]（-1 = 不发射）。mode 见模块文档。"""
    n, t_max, _ = encoder_out.shape
    ctx = np.full((n, context), blank, dtype=np.int64)
    emitted = np.full((n, t_max), NO_EMIT, dtype=np.int64)
    if mode == "dart":
        dec_out = dec.run(None, {"y": ctx})[0]
    for t in range(t_max):
        if mode == "loop":
            dec_out = dec.run(None, {"y": ctx})[0]
            logit = joi.run(None, {"encoder_out": np.ascontiguousarray(encoder_out[:, t, :]), "decoder_out": dec_out})[0]
            y = np.argmax(logit, axis=1).astype(np.int64)
            emit = (y != blank) & (y != unk) & (t < lens)
        else:
            active = np.nonzero(t < lens)[0]
            y = np.full(n, blank, dtype=np.int64)
            emit = np.zeros(n, dtype=bool)
            if active.size:
                logit = joi.run(
                    None,
                    {
                        "encoder_out": np.ascontiguousarray(encoder_out[active, t, :]),
                        "decoder_out": np.ascontiguousarray(dec_out[active]),
                    },
                )[0]
                y[active] = np.argmax(logit, axis=1)
                emit[active] = (y[active] != blank) & (y[active] != unk)
        if emit.any():
            new_ctx = np.concatenate([ctx[:, 1:], y[:, None]], axis=1)
            ctx = np.where(emit[:, None], new_ctx, ctx)
            emitted[emit, t] = y[emit]
            if mode == "dart":
                rows = np.nonzero(emit)[0]
                dec_out[rows] = dec.run(None, {"y": np.ascontiguousarray(ctx[rows])})[0]
    return emitted


def run_loop_graph(sess: ort.InferenceSession, encoder_out: np.ndarray, lens: np.ndarray) -> np.ndarray:
    return sess.run(None, {"encoder_out": encoder_out, "encoder_out_lens": lens})[0]


def timeit(fn, repeat: int) -> float:
    best = float("inf")
    for _ in range(repeat):
        t0 = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t0)
    return best


def decode_text(emitted_row: np.ndarray, tokens: dict[int, str]) -> str:
    return "".join(tokens[int(v)] for v in emitted_row if v != NO_EMIT)


def compare(name: str, got: np.ndarray, want: np.ndarray, strict: bool) -> bool:
    if got.shape != want.shape:
        raise AssertionError(f"{name}: 形状 {got.shape} != {want.shape}")
    diff = np.nonzero(got != want)
    if diff[0].size == 0:
        print(f"  [equal] {name}: {got.shape} 逐元素相等")
        return True
    msg = f"{name}: {diff[0].size} 处不同，首个 (n,t)=({diff[0][0]},{diff[1][0]}) got={got[diff][0]} want={want[diff][0]}"
    if strict:
        raise AssertionError(msg)
    print(f"  [DIFF ] {msg}")
    return False


# ---------------------------------------------------------------------------
# 特征与 encoder
# ---------------------------------------------------------------------------


def compute_fbank(samples: np.ndarray) -> np.ndarray:
    import kaldi_native_fbank as knf

    opts = knf.FbankOptions()
    opts.frame_opts.samp_freq = 16000
    opts.frame_opts.frame_length_ms = 25.0
    opts.frame_opts.frame_shift_ms = 10.0
    opts.frame_opts.dither = 0.0
    opts.frame_opts.preemph_coeff = 0.97
    opts.frame_opts.remove_dc_offset = True
    opts.frame_opts.window_type = "povey"
    opts.frame_opts.round_to_power_of_two = True
    opts.frame_opts.snip_edges = False
    opts.mel_opts.num_bins = 80
    opts.mel_opts.low_freq = 20.0
    opts.mel_opts.high_freq = -400.0
    opts.mel_opts.is_librosa = False
    opts.use_energy = False
    opts.use_log_fbank = True
    opts.use_power = True
    fbank = knf.OnlineFbank(opts)
    fbank.accept_waveform(16000, samples.astype(np.float32).tolist())
    fbank.input_finished()
    return np.asarray([fbank.get_frame(i) for i in range(fbank.num_frames_ready)], dtype=np.float32)


def encoder_out_for_wav(models_dir: str, wav: str) -> tuple[np.ndarray, np.ndarray]:
    import soundfile as sf

    samples, sr = sf.read(wav, dtype="float32")
    assert sr == 16000 and samples.ndim == 1, (sr, samples.shape)
    feats = compute_fbank(samples)
    enc = ort.InferenceSession(_child_path(models_dir, "encoder-epoch-99-avg-1.int8.onnx"), providers=["CPUExecutionProvider"])
    out, lens = enc.run(None, {"x": feats[None], "x_lens": np.array([feats.shape[0]], dtype=np.int64)})
    print(f"  [enc  ] fbank {feats.shape} -> encoder_out {out.shape}, lens {lens.tolist()}")
    return out.astype(np.float32), lens.astype(np.int64)


def load_tokens(path: str) -> tuple[dict[int, str], int, int]:
    tokens: dict[int, str] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            sep = line.rfind("\t") if "\t" in line else line.rfind(" ")
            tokens[int(line[sep + 1 :])] = line[:sep]
    inv = {v: k for k, v in tokens.items()}
    return tokens, inv["<blk>"], inv["<unk>"]


# ---------------------------------------------------------------------------
# 用例
# ---------------------------------------------------------------------------


def make_bench(encoder_out: np.ndarray, n: int, t: int, rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """代表真实批次规模的合成用例：把真 encoder_out 沿时间平铺到 T 帧，每行加不同幅度噪声。"""
    reps = int(np.ceil(t / encoder_out.shape[1]))
    base = np.concatenate([encoder_out[0]] * reps, axis=0)[:t]
    rows = [base + rng.standard_normal(base.shape).astype(np.float32) * 0.1 * i for i in range(n)]
    return np.stack(rows).astype(np.float32), np.full(n, t, dtype=np.int64)


def make_batch3(encoder_out: np.ndarray, lens: np.ndarray, rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """行 0 = 原样；行 1 = 原样但 lens 截到一半；行 2 = 时间反转 + 噪声、lens 截到 1/3。
    pad 区域填随机数，用来验证超过 lens 的帧绝不发射。"""
    t = encoder_out.shape[1]
    full = lens[0]
    rows = [encoder_out[0], encoder_out[0], encoder_out[0, ::-1] + rng.standard_normal(encoder_out.shape[1:]).astype(np.float32) * 0.5]
    batch = np.stack(rows).copy()
    batch_lens = np.array([full, full // 2, full // 3], dtype=np.int64)
    for i, l in enumerate(batch_lens):
        batch[i, l:] = rng.standard_normal((t - l, batch.shape[2])).astype(np.float32) * 3.0
    return batch, batch_lens


def verify_variant(
    label: str,
    graph_path: str,
    decoder_path: str,
    joiner_path: str,
    blank: int,
    unk: int,
    cases: list[tuple[str, np.ndarray, np.ndarray]],
    tokens: dict[int, str] | None,
    repeat: int,
    strict_dart: bool,
) -> bool:
    print(f"== {label}")
    check_graph(graph_path)
    prov = ["CPUExecutionProvider"]
    loop_sess = ort.InferenceSession(graph_path, providers=prov)
    dec = ort.InferenceSession(decoder_path, providers=prov)
    joi = ort.InferenceSession(joiner_path, providers=prov)
    ok = True
    for case_name, enc_out, lens in cases:
        context = 2
        got = run_loop_graph(loop_sess, enc_out, lens)
        ref_loop = reference_greedy(dec, joi, enc_out, lens, blank, unk, context, "loop")
        ref_dart = reference_greedy(dec, joi, enc_out, lens, blank, unk, context, "dart")
        ok &= compare(f"{label}/{case_name} Loop 图 vs 参考(loop 批)", got, ref_loop, strict=True)
        ok &= compare(f"{label}/{case_name} Loop 图 vs 参考(dart 批)", got, ref_dart, strict=strict_dart)
        # 超过 lens 的帧一律不发射。
        for n, l in enumerate(lens):
            assert np.all(got[n, l:] == NO_EMIT), f"{case_name} 行 {n} 在 t>={l} 仍有发射"
        if tokens is not None:
            for n in range(got.shape[0]):
                print(f"  [text ] {case_name} 行{n} (lens={lens[n]}): 「{decode_text(got[n], tokens)}」")
        t_loop = timeit(lambda: run_loop_graph(loop_sess, enc_out, lens), repeat)
        t_ref = timeit(lambda: reference_greedy(dec, joi, enc_out, lens, blank, unk, context, "dart"), repeat)
        frames = enc_out.shape[1]
        print(
            f"  [time ] {case_name} N={enc_out.shape[0]} T={frames}: Loop 图单次 {t_loop * 1000:.1f} ms "
            f"({t_loop / frames * 1e3:.3f} ms/帧)，Python 逐帧参考(dart 批) {t_ref * 1000:.1f} ms "
            f"({t_ref / frames * 1e3:.3f} ms/帧)，比值 {t_ref / t_loop:.2f}x（{repeat} 次取最小）"
        )
    return ok


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models-dir", help="含 decoder/joiner(.int8).onnx、encoder-epoch-99-avg-1.int8.onnx、tokens.txt 的目录")
    ap.add_argument("--wav", default=os.path.join(FIXTURES, "ja_tts_16k.wav"))
    ap.add_argument("--dart", default=os.environ.get("DART", "dart"), help="dart 可执行文件（默认 $DART 或 PATH 里的 dart）")
    ap.add_argument("--out-dir", help="生成图落盘目录，必须已存在（默认临时目录，结束后删除）")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--bench-shape", default="8,250", help="合成计时用例的 N,T（真实批次量级；空串跳过）")
    ap.add_argument("--strict-dart", action="store_true", help="int8 下也要求与 dart 批方式参考逐元素相等")
    ap.add_argument("--skip-real", action="store_true")
    ap.add_argument("--skip-tiny", action="store_true")
    args = ap.parse_args()

    dart_exe = _checked_program(args.dart)
    out_dir = (_checked_dir("--out-dir", args.out_dir) if args.out_dir
               else tempfile.mkdtemp(prefix="fushi_greedy_"))
    all_ok = True
    try:
        if not args.skip_tiny:
            dec_p = os.path.join(FIXTURES, "greedy_tiny_decoder.onnx")
            joi_p = os.path.join(FIXTURES, "greedy_tiny_joiner.onnx")
            g = _child_path(out_dir, "tiny.onnx")
            build_graph(dart_exe, dec_p, joi_p, g, blank=0, unk=5)
            rng = np.random.default_rng(7)
            enc = rng.standard_normal((3, 25, 4)).astype(np.float32) * 2.0
            lens = np.array([25, 13, 6], dtype=np.int64)
            all_ok &= verify_variant("tiny", g, dec_p, joi_p, 0, 5, [("batch3", enc, lens)], None, args.repeat, strict_dart=True)

        if not args.skip_real:
            if not args.models_dir:
                raise SystemExit("--models-dir 必填（或用 --skip-real）")
            models_dir = _checked_dir("--models-dir", args.models_dir)
            wav_path = _checked_file("--wav", args.wav)
            tokens, blank, unk = load_tokens(_child_path(models_dir, "tokens.txt"))
            enc_out, lens = encoder_out_for_wav(models_dir, wav_path)
            b3, b3_lens = make_batch3(enc_out, lens, np.random.default_rng(3))
            cases = [("single", enc_out, lens), ("batch3", b3, b3_lens)]
            if args.bench_shape:
                bn, bt = (int(v) for v in args.bench_shape.split(","))
                cases.append((f"bench N{bn} T{bt}", *make_bench(enc_out, bn, bt, np.random.default_rng(11))))
            for tag, dec_name, joi_name in [
                ("int8", "decoder-epoch-99-avg-1.int8.onnx", "joiner-epoch-99-avg-1.int8.onnx"),
                ("fp32", "decoder-epoch-99-avg-1.onnx", "joiner-epoch-99-avg-1.onnx"),
            ]:
                dec_p = _child_path(models_dir, dec_name)
                joi_p = _child_path(models_dir, joi_name)
                g = _child_path(out_dir, f"{tag}.onnx")
                build_graph(dart_exe, dec_p, joi_p, g, blank, unk)
                all_ok &= verify_variant(tag, g, dec_p, joi_p, blank, unk, cases, tokens, args.repeat, args.strict_dart or tag == "fp32")
    finally:
        if not args.out_dir:
            shutil.rmtree(out_dir, ignore_errors=True)
    print("RESULT:", "PASSED" if all_ok else "PASSED (with int8 dart-batch diffs reported above)")


if __name__ == "__main__":
    main()
