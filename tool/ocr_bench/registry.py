"""Model registry for the OCR benchmark.

Paths are relative to --models (see README.md for the download list). The two
"shipped" entries are the files the app already downloads into
`<support>/ocr_models/manga-ctc/`; pass that folder as --shipped.
"""

from __future__ import annotations

from pathlib import Path

from ppocr import Detector, Recognizer

# name -> (root, onnx, dictionary)
RECOGNIZERS: dict[str, tuple[str, str, str]] = {
    "kellenok_v0.2": ("shipped", "kellenok_manga_rec_v0.2.onnx", "ppocrv6_small_rec.yml"),
    "kellenok_v0.2_fp16": ("models", "kel/manga_rec_v0.2_fp16.onnx", "kel/ppocrv6_dict.txt"),
    "ppocrv6_small": ("models", "v6_small_rec/inference.onnx", "v6_small_rec/inference.yml"),
    "ppocrv5_mobile": ("models", "v5_mobile_rec/inference.onnx", "v5_mobile_rec/inference.yml"),
    "ppocrv5_server": ("models", "v5_server_rec/inference.onnx", "v5_server_rec/inference.yml"),
}

# name -> (root, onnx, PaddleX postprocess defaults: thresh, box_thresh, unclip)
DETECTORS: dict[str, tuple[str, str, tuple[float, float, float]]] = {
    "ppocrv6_small_det": ("shipped", "ppocrv6_small_det.onnx", (0.2, 0.45, 1.4)),
    "kellenok_det_v0.2": ("models", "kel/manga_det_v0.2.onnx", (0.2, 0.45, 1.4)),
    "ppocrv5_mobile_det": ("models", "v5_mobile_det/inference.onnx", (0.3, 0.6, 1.5)),
    "ppocrv5_server_det": ("models", "v5_server_det/inference.onnx", (0.3, 0.6, 1.5)),
}


def _root(kind: str, models: Path, shipped: Path) -> Path:
    return shipped if kind == "shipped" else models


NO_KANA = "+nokana"


def load_recognizer(name: str, models: Path, shipped: Path, threads: int) -> Recognizer:
    """`<name>+nokana` loads the same model with kana classes masked (zh mode)."""
    base = name.removesuffix(NO_KANA)
    kind, onnx, dict_path = RECOGNIZERS[base]
    root = _root(kind, models, shipped)
    return Recognizer(name, root / onnx, root / dict_path, threads, suppress_kana=name.endswith(NO_KANA))


def load_detector(name: str, models: Path, shipped: Path, threads: int, resize_long: int | None) -> Detector:
    kind, onnx, (thresh, box_thresh, unclip) = DETECTORS[name]
    return Detector(
        name, _root(kind, models, shipped) / onnx, threads,
        thresh=thresh, box_thresh=box_thresh, unclip=unclip, resize_long=resize_long,
    )


def model_bytes(name: str, models: Path, shipped: Path) -> int:
    name = name.removesuffix(NO_KANA)
    if name in RECOGNIZERS:
        kind, onnx, _ = RECOGNIZERS[name]
    else:
        kind, onnx, _ = DETECTORS[name]
    return (_root(kind, models, shipped) / onnx).stat().st_size
