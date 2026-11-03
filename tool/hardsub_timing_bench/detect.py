"""帧差定字幕区间的原型：以查词那一帧为锚，向前 / 向后找字幕像素发生变化的帧。

流程（每次查词一次，按需、不预处理整片）：
1. ffmpeg 解码 [t-W, t+W] 内字幕所在区域（上 / 下带），缩到 640 宽灰度；
2. 锚帧上取「文字像素」：亮且紧挨着暗描边的像素（fill），以及它外圈的暗描边（ring）；
3. 每帧算锚点文字像素的保持率 s = min(fill 保持率, ring 保持率)；
4. 从锚帧往两边走，s 连续 K 帧低于阈值处即为字幕边界。
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass

import cv2
import numpy as np

FPS: float = 24000 / 1001
W_OUT: int = 640
BAND_FRAC: float = 0.30


@dataclass
class Params:
    window: float = 8.0
    bright: int = 150  # 文字填充最低亮度
    contrast: int = 90  # 填充与邻域最暗像素的差
    fill_tol: int = 35
    ring_tol: int = 45
    thresh: float = 0.55
    persist: int = 2  # 连续低于阈值的帧数
    min_pixels: int = 15
    drop_static: bool = True  # 去掉整窗都不变的像素（静态背景结构）
    stable_k: int = 4  # 锚帧前后 k 帧内都不变的像素才算字（去掉运动背景）；0 关闭
    # auto：纯像素特征（不用 OCR）；ocrbox：限制在 OCR 行框内（默认，最佳）；
    # ocrbox2：框内亮 / 暗分位像素（已证伪，留作对照）；glyph：精确字形（理论上限）
    mode: str = "ocrbox"
    box_pad: int = 3


@dataclass
class Detection:
    start: float | None
    end: float | None
    n_frames: int
    decode_s: float
    analyze_s: float
    fill_pixels: int
    hit_window_edge: bool


def decode_band(video: str, t0: float, dur: float, band: str, src_w: int = 1280, src_h: int = 720) -> np.ndarray:
    bh: int = int(src_h * BAND_FRAC)
    y: int = 0 if band == "top" else src_h - bh
    h_out: int = int(round(bh * W_OUT / src_w / 2)) * 2
    cmd: list[str] = [
        "ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-i", video, "-t", f"{dur:.3f}", "-an",
        "-vf", f"crop={src_w}:{bh}:0:{y},scale={W_OUT}:{h_out}:flags=area,format=gray",
        "-f", "rawvideo", "-",
    ]
    raw: bytes = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, h_out, W_OUT)


def text_masks(g: np.ndarray, p: Params) -> tuple[np.ndarray, np.ndarray]:
    k: np.ndarray = np.ones((5, 5), np.uint8)
    local_min: np.ndarray = cv2.erode(g, k)
    fill: np.ndarray = (g >= p.bright) & (g.astype(np.int16) - local_min >= p.contrast)
    near: np.ndarray = cv2.dilate(fill.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    ring: np.ndarray = near & ~fill & (g <= 90)
    return fill, ring


def line_boxes(ref: np.ndarray, pad: int) -> np.ndarray:
    """模拟 OCR 行框：按行投影切出每一行文字的外接矩形，返回框内为 True 的掩码。"""
    on: np.ndarray = ref > 40
    rows: np.ndarray = np.flatnonzero(on.any(axis=1))
    box: np.ndarray = np.zeros_like(on)
    if len(rows) == 0:
        return box
    runs: list[list[int]] = [[int(rows[0]), int(rows[0])]]
    for r in rows[1:]:
        if r - runs[-1][1] <= 3:
            runs[-1][1] = int(r)
        else:
            runs.append([int(r), int(r)])
    h, w = on.shape
    for r0, r1 in runs:
        cols: np.ndarray = np.flatnonzero(on[r0 : r1 + 1].any(axis=0))
        box[max(0, r0 - pad) : min(h, r1 + pad + 1), max(0, cols[0] - pad) : min(w, cols[-1] + pad + 1)] = True
    return box


def detect(
    video: str,
    t: float,
    band: str,
    duration: float,
    p: Params | None = None,
    ref_video: str | None = None,
) -> Detection:
    import time

    p = p or Params()
    t0: float = max(0.0, t - p.window)
    t1: float = min(duration, t + p.window)
    ts: float = time.perf_counter()
    frames: np.ndarray = decode_band(video, t0, t1 - t0, band)
    td: float = time.perf_counter()
    first: float = np.ceil(t0 * FPS - 1e-6) / FPS
    times: np.ndarray = first + np.arange(len(frames)) / FPS
    a: int = int(np.argmin(np.abs(times - t)))
    ga: np.ndarray = frames[a]
    fill, ring = text_masks(ga, p)
    if p.mode != "auto":
        assert ref_video
        ref: np.ndarray = decode_band(ref_video, max(0.0, float(times[a]) - 0.002), 1.5 / FPS, band)[0]
        if p.mode == "ocrbox":
            box: np.ndarray = line_boxes(ref, p.box_pad)
            fill &= box
            ring &= box
        elif p.mode == "ocrbox2":
            # 有字框就不再要求高对比：框内最亮 / 最暗的分位像素分别当作字芯 / 描边，不挑字色。
            box = line_boxes(ref, p.box_pad)
            if box.any():
                vals: np.ndarray = ga[box]
                hi_v, lo_v = np.percentile(vals, 85), np.percentile(vals, 20)
                fill = box & (ga >= hi_v)
                ring = box & (ga <= lo_v)
            else:
                fill = ring = box
        else:
            fill = ref > 128
            ring = cv2.dilate(fill.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool) & ~fill
    if p.stable_k > 0:
        lo_k: int = max(0, a - p.stable_k)
        hi_k: int = min(len(frames), a + p.stable_k + 1)
        dev: np.ndarray = np.abs(frames[lo_k:hi_k].astype(np.int16) - ga).max(axis=0)
        fill &= dev < p.fill_tol
        ring &= dev < p.ring_tol
    if p.drop_static:
        # 首尾两帧都与锚帧相同的像素视为静态背景（字幕不会横跨整个 2W 窗口）。
        for e in (frames[0], frames[-1]):
            same: np.ndarray = np.abs(e.astype(np.int16) - ga) < p.fill_tol
            fill &= ~same
            ring &= ~same
    nfill: int = int(fill.sum())
    if nfill < p.min_pixels or ring.sum() < p.min_pixels // 2:
        return Detection(None, None, len(frames), td - ts, time.perf_counter() - td, nfill, False)
    diff: np.ndarray = np.abs(frames.astype(np.int16) - ga.astype(np.int16))
    s_fill: np.ndarray = (diff[:, fill] < p.fill_tol).mean(axis=1)
    s_ring: np.ndarray = (diff[:, ring] < p.ring_tol).mean(axis=1)
    s: np.ndarray = np.minimum(s_fill, s_ring)
    low: np.ndarray = s < p.thresh

    def walk(step: int) -> tuple[int, bool]:
        i: int = a
        run: int = 0
        while 0 <= i + step < len(frames):
            i += step
            run = run + 1 if low[i] else 0
            if run >= p.persist:
                return i - step * (p.persist - 1), False
        return i + step, True

    lo, edge_lo = walk(-1)
    hi, edge_hi = walk(+1)
    start: float = times[lo + 1] if lo + 1 < len(times) else times[-1]
    end: float = times[hi] if hi < len(times) else times[-1] + 1 / FPS
    return Detection(float(start), float(end), len(frames), td - ts, time.perf_counter() - td, nfill, edge_lo or edge_hi)
