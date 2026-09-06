"""生成 `AsrFbank` 的黄金特征（与 sherpa-onnx 喂给 ReazonSpeech k2-v2 的 fbank 逐值一致）。

运行环境（生成本目录 json 时）：Python 3.11，kaldi-native-fbank 1.22.3（`pip install kaldi-native-fbank`），
numpy，soundfile。

    python gen_fbank_golden.py

产出：
- fbank_golden.json     —— 固定种子合成 0.4 s 信号（几路正弦 + 高斯噪声，幅度 ≤ 0.5）的样本与 knf 特征。
- fbank_golden_ja.json  —— ja_tts_16k.wav（edge-tts ja-JP-NanamiNeural 生成、ffmpeg 转 16 kHz 单声道 s16）
                           的 knf 特征（样本由 Dart 测试自行读 wav）。

knf 选项对齐 sherpa-onnx `sherpa-onnx/csrc/features.cc` 的 `FeatureExtractorConfig` 默认值：
frame_opts: samp_freq=16000, frame_length_ms=25, frame_shift_ms=10, dither=0（knf 默认是 3e-5，
必须显式置 0），preemph_coeff=0.97, remove_dc_offset=True, window_type="povey",
round_to_power_of_two=True, snip_edges=False；mel_opts: num_bins=80, low_freq=20, high_freq=-400,
is_librosa=False；use_energy=False, use_log_fbank=True, use_power=True。
样本按 [-1, 1] 浮点直接喂（sherpa-onnx normalize_samples=True 不乘 32768）。

json 里的 float 保留 6 位有效数字（log 域特征绝对值 < 30，量化误差 < 3e-5，远小于 Dart 测试阈值 1e-3）。
"""

from __future__ import annotations

import json
import os

import kaldi_native_fbank as knf
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLE_RATE = 16000


def make_opts() -> knf.FbankOptions:
    opts = knf.FbankOptions()
    opts.frame_opts.samp_freq = SAMPLE_RATE
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
    return opts


def compute_fbank(samples: np.ndarray) -> np.ndarray:
    """与 sherpa-onnx OfflineStream 相同：一次 accept_waveform + input_finished，取全部帧。"""
    fbank = knf.OnlineFbank(make_opts())
    fbank.accept_waveform(SAMPLE_RATE, samples.astype(np.float32).tolist())
    fbank.input_finished()
    frames = [fbank.get_frame(i) for i in range(fbank.num_frames_ready)]
    return np.asarray(frames, dtype=np.float32)


def round6(values: np.ndarray) -> list[float]:
    return [float(f"{v:.6g}") for v in values.reshape(-1)]


def synth_signal() -> np.ndarray:
    rng = np.random.default_rng(20260905)
    n = int(SAMPLE_RATE * 0.4)
    t = np.arange(n) / SAMPLE_RATE
    sig = (
        0.20 * np.sin(2 * np.pi * 220.0 * t)
        + 0.12 * np.sin(2 * np.pi * 1375.0 * t + 0.7)
        + 0.08 * np.sin(2 * np.pi * 5200.0 * t + 1.9)
        + 0.05 * rng.standard_normal(n)
    )
    # 加一段直流与一段静音，覆盖 remove_dc_offset 与 log 下限路径。
    sig[: n // 8] += 0.1
    sig[-n // 10 :] = 0.0
    sig = np.clip(sig, -0.5, 0.5)
    # 先量化到 float32 再落 6 位有效数字，保证 Dart 读回的样本与喂 knf 的完全一致。
    return np.asarray([float(f"{v:.6g}") for v in sig.astype(np.float32)], dtype=np.float32)


def main() -> None:
    samples = synth_signal()
    feats = compute_fbank(samples)
    with open(os.path.join(HERE, "fbank_golden.json"), "w", encoding="utf-8") as f:
        json.dump(
            {
                "sample_rate": SAMPLE_RATE,
                "num_bins": 80,
                "samples": [float(v) for v in samples],
                "frames": int(feats.shape[0]),
                "features": round6(feats),
            },
            f,
            separators=(",", ":"),
        )

    wav, sr = sf.read(os.path.join(HERE, "ja_tts_16k.wav"), dtype="float32")
    assert sr == SAMPLE_RATE and wav.ndim == 1, (sr, wav.shape)
    feats_ja = compute_fbank(wav)
    with open(os.path.join(HERE, "fbank_golden_ja.json"), "w", encoding="utf-8") as f:
        json.dump(
            {
                "sample_rate": SAMPLE_RATE,
                "num_bins": 80,
                "num_samples": int(wav.shape[0]),
                "frames": int(feats_ja.shape[0]),
                "features": round6(feats_ja),
            },
            f,
            separators=(",", ":"),
        )
    print("synthetic:", samples.shape, feats.shape, "ja:", wav.shape, feats_ja.shape)


if __name__ == "__main__":
    main()
