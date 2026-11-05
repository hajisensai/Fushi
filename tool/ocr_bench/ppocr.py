"""PP-OCR det/rec runners for the OCR benchmark (ONNX Runtime, CPU).

Preprocessing mirrors the app so numbers transfer:
- rec: `packages/fushi_engine/lib/ocr/ppocr_line_recognizer.dart` (BGR, height 48,
  width ceil(48*w/h) with a 320 minimum, (x/255-0.5)/0.5, right zero padding,
  CTC greedy decode). Vertical lines are rotated 90 degrees counter-clockwise
  first, like `ctc_column_ocr_recognizer.dart`.
- det: `ppocr_line_detector.dart` (BGR + ImageNet mean/std, DB postprocess). The
  input size is configurable because the app runs det inside a block crop, while
  the video path needs a whole-frame resize (PaddleOCR's `resize_long`).
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort
import pyclipper


def make_session(path: Path, threads: int) -> ort.InferenceSession:
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    opts.intra_op_num_threads = threads
    opts.inter_op_num_threads = 1
    return ort.InferenceSession(str(path), opts, providers=["CPUExecutionProvider"])


def load_vocab(dict_path: Path) -> list[str]:
    """Return the CTC vocabulary: blank + dictionary + space.

    Accepts a PaddleX `inference.yml` (PostProcess.character_dict) or a plain
    one-symbol-per-line txt file.
    """
    if dict_path.suffix in (".yml", ".yaml"):
        import yaml  # PyYAML ships with most Python installs used here

        with dict_path.open(encoding="utf-8") as f:
            cfg = yaml.safe_load(f)
        chars = [str(c) for c in cfg["PostProcess"]["character_dict"]]
    else:
        with dict_path.open(encoding="utf-8") as f:
            chars = [line.rstrip("\r\n") for line in f]
    return ["blank", *chars, " "]


@dataclass
class RecResult:
    text: str
    confidence: float
    ms: float


def is_kana(ch: str) -> bool:
    o = ord(ch[0]) if ch else 0
    return 0x3040 <= o <= 0x30FF or 0x31F0 <= o <= 0x31FF or 0xFF66 <= o <= 0xFF9F


class Recognizer:
    def __init__(self, name: str, onnx: Path, dict_path: Path, threads: int = 4, suppress_kana: bool = False):
        self.name = name
        self.session = make_session(onnx, threads)
        self.vocab = load_vocab(dict_path)
        self.input_name = self.session.get_inputs()[0].name
        classes = self.session.get_outputs()[0].shape[-1]
        if isinstance(classes, int) and classes != len(self.vocab):
            raise ValueError(f"{name}: model has {classes} classes, vocab {len(self.vocab)}")
        # Chinese text never contains kana: masking those classes before the
        # argmax lets the next-best (Chinese) class win instead.
        self.mask = np.array([i for i, ch in enumerate(self.vocab) if i > 0 and is_kana(ch)], np.int64) \
            if suppress_kana else None

    @staticmethod
    def preprocess(bgr: np.ndarray, vertical: bool) -> np.ndarray:
        if vertical:
            bgr = cv2.rotate(bgr, cv2.ROTATE_90_COUNTERCLOCKWISE)
        h, w = bgr.shape[:2]
        target_w = max(1, math.ceil(48 * w / max(1, h)))
        resized = cv2.resize(bgr, (target_w, 48), interpolation=cv2.INTER_LINEAR)
        width = max(320, target_w)
        x = np.zeros((1, 3, 48, width), np.float32)
        x[0, :, :, :target_w] = ((resized.astype(np.float32) / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)
        return x

    def recognize(self, bgr: np.ndarray, vertical: bool = False) -> RecResult:
        x = self.preprocess(bgr, vertical)
        start = time.perf_counter()
        probs = self.session.run(None, {self.input_name: x})[0][0]
        if self.mask is not None:
            probs = probs.copy()
            probs[:, self.mask] = 0.0
        ms = (time.perf_counter() - start) * 1000
        idx = probs.argmax(axis=1)
        conf = probs.max(axis=1)
        out: list[str] = []
        scores: list[float] = []
        prev = -1
        for i, c in zip(idx, conf):
            if i != prev and i != 0:
                out.append(self.vocab[i])
                scores.append(float(c))
            prev = i
        return RecResult("".join(out).strip(), float(np.mean(scores)) if scores else 0.0, ms)


@dataclass
class DetBox:
    x0: int
    y0: int
    x1: int
    y1: int
    score: float

    @property
    def vertical(self) -> bool:
        # Same ratio as kPpLineVerticalRatio in ppocr_line_detector.dart.
        return (self.y1 - self.y0) >= 1.5 * (self.x1 - self.x0)


class Detector:
    """DB text detector returning axis-aligned boxes in source pixels."""

    def __init__(
        self,
        name: str,
        onnx: Path,
        threads: int = 4,
        thresh: float = 0.2,
        box_thresh: float = 0.45,
        unclip: float = 1.4,
        resize_long: int | None = 960,
    ):
        self.name = name
        self.session = make_session(onnx, threads)
        self.input_name = self.session.get_inputs()[0].name
        self.thresh = thresh
        self.box_thresh = box_thresh
        self.unclip = unclip
        self.resize_long = resize_long
        self.last_ms = 0.0

    def _input_size(self, w: int, h: int) -> tuple[int, int]:
        if self.resize_long:
            ratio = self.resize_long / max(w, h)
        else:
            ratio = 64 / min(w, h) if min(w, h) < 64 else 1.0
        rw = max(32, int(round(w * ratio / 32)) * 32)
        rh = max(32, int(round(h * ratio / 32)) * 32)
        return rw, rh

    def detect(self, bgr: np.ndarray) -> list[DetBox]:
        h, w = bgr.shape[:2]
        rw, rh = self._input_size(w, h)
        resized = cv2.resize(bgr, (rw, rh), interpolation=cv2.INTER_LINEAR).astype(np.float32) / 255.0
        mean = np.array([0.485, 0.456, 0.406], np.float32)
        std = np.array([0.229, 0.224, 0.225], np.float32)
        x = ((resized - mean) / std).transpose(2, 0, 1)[None]
        start = time.perf_counter()
        prob = self.session.run(None, {self.input_name: x})[0][0, 0]
        self.last_ms = (time.perf_counter() - start) * 1000
        mask = (prob > self.thresh).astype(np.uint8)
        contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        sx, sy = w / rw, h / rh
        boxes: list[DetBox] = []
        for c in contours[:1000]:
            if cv2.contourArea(c) < 4:
                continue
            filled = np.zeros_like(mask)
            cv2.drawContours(filled, [c], -1, 1, -1)
            score = float(prob[filled > 0].mean())
            if score < self.box_thresh:
                continue
            rect = cv2.minAreaRect(c)
            poly = cv2.boxPoints(rect)
            area = cv2.contourArea(poly)
            length = cv2.arcLength(poly, True)
            if length <= 0:
                continue
            dist = area * self.unclip / length
            off = pyclipper.PyclipperOffset()
            off.AddPath([tuple(p) for p in poly.astype(np.int64)], pyclipper.JT_ROUND, pyclipper.ET_CLOSEDPOLYGON)
            grown = off.Execute(dist)
            if not grown:
                continue
            pts = np.array(grown[0], np.float32)
            x0, y0 = pts.min(axis=0)
            x1, y1 = pts.max(axis=0)
            box = DetBox(
                int(max(0, x0 * sx)), int(max(0, y0 * sy)),
                int(min(w, x1 * sx)), int(min(h, y1 * sy)), score,
            )
            if box.x1 - box.x0 >= 3 and box.y1 - box.y0 >= 3:
                boxes.append(box)
        return boxes
