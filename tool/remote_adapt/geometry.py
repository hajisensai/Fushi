"""截图视图与物理坐标之间的换算（纯函数，跨平台可测）。

截图会被缩小后交给 Claude；Claude 在缩小图上读出的坐标要换回物理屏幕像素才能点。
一次截图对应一个 `View`：物理区域 (left, top, width, height) 被缩放成 image_w x image_h。
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Rect:
    left: int
    top: int
    width: int
    height: int

    @property
    def right(self) -> int:
        return self.left + self.width

    @property
    def bottom(self) -> int:
        return self.top + self.height

    def intersect(self, other: "Rect") -> "Rect | None":
        left = max(self.left, other.left)
        top = max(self.top, other.top)
        right = min(self.right, other.right)
        bottom = min(self.bottom, other.bottom)
        if right <= left or bottom <= top:
            return None
        return Rect(left, top, right - left, bottom - top)

    def contains(self, x: int, y: int) -> bool:
        return self.left <= x < self.right and self.top <= y < self.bottom


@dataclass(frozen=True)
class View:
    """一次截图：物理区域 `region` 缩放成 image_w x image_h 的图。"""

    region: Rect
    image_w: int
    image_h: int

    @property
    def scale(self) -> float:
        """图像像素 / 物理像素（≤1 表示缩小）。"""
        return self.image_w / self.region.width

    def to_physical(self, x: float, y: float) -> tuple[int, int]:
        """图像坐标 → 物理屏幕坐标（取像素中心，四舍五入）。"""
        sx = self.region.width / self.image_w
        sy = self.region.height / self.image_h
        px = self.region.left + int((x + 0.5) * sx)
        py = self.region.top + int((y + 0.5) * sy)
        return (
            min(max(px, self.region.left), self.region.right - 1),
            min(max(py, self.region.top), self.region.bottom - 1),
        )

    def to_image(self, px: int, py: int) -> tuple[int, int]:
        """物理屏幕坐标 → 图像坐标。"""
        return (
            int((px - self.region.left) * self.image_w / self.region.width),
            int((py - self.region.top) * self.image_h / self.region.height),
        )


def fit_size(width: int, height: int, max_edge: int) -> tuple[int, int]:
    """等比缩放到长边不超过 max_edge（不放大）。"""
    if max_edge <= 0 or max(width, height) <= max_edge:
        return width, height
    if width >= height:
        return max_edge, max(1, round(height * max_edge / width))
    return max(1, round(width * max_edge / height)), max_edge


def normalize_absolute(x: int, y: int, virtual: Rect) -> tuple[int, int]:
    """物理坐标 → SendInput MOUSEEVENTF_ABSOLUTE|VIRTUALDESK 的 0..65535 归一化坐标。"""
    nx = round((x - virtual.left) * 65535 / max(1, virtual.width - 1))
    ny = round((y - virtual.top) * 65535 / max(1, virtual.height - 1))
    return min(max(nx, 0), 65535), min(max(ny, 0), 65535)


def interpolate(
    start: tuple[int, int], end: tuple[int, int], steps: int
) -> list[tuple[int, int]]:
    """start→end 的 steps+1 个点（含两端），用于拖动 / 滑动。"""
    steps = max(1, steps)
    return [
        (
            round(start[0] + (end[0] - start[0]) * i / steps),
            round(start[1] + (end[1] - start[1]) * i / steps),
        )
        for i in range(steps + 1)
    ]
