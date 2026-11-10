"""geometry.py 的纯函数测试（跨平台）：python tool/remote_adapt/geometry_test.py"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from geometry import Rect, View, fit_size, interpolate, normalize_absolute  # noqa: E402


class GeometryTest(unittest.TestCase):
    def test_fit_size_keeps_aspect_and_never_upscales(self) -> None:
        self.assertEqual(fit_size(3840, 2160, 1568), (1568, 882))
        self.assertEqual(fit_size(1080, 1920, 1568), (882, 1568))
        self.assertEqual(fit_size(800, 600, 1568), (800, 600))

    def test_view_round_trip_on_scaled_full_desktop(self) -> None:
        view = View(Rect(0, 0, 3840, 2160), 1568, 882)
        px, py = view.to_physical(200, 157)
        self.assertEqual((px, py), (491, 385))
        self.assertEqual(view.to_image(px, py), (200, 157))

    def test_view_with_negative_origin_region(self) -> None:
        # 主屏左侧的副屏：虚拟桌面原点为负
        view = View(Rect(-1920, 0, 1920, 1080), 960, 540)
        self.assertEqual(view.to_physical(0, 0), (-1919, 1))
        self.assertEqual(view.to_physical(959, 539), (-1, 1079))

    def test_unscaled_region_is_identity(self) -> None:
        view = View(Rect(100, 200, 80, 80), 80, 80)
        self.assertEqual(view.to_physical(40, 40), (140, 240))

    def test_normalize_absolute_hits_both_edges(self) -> None:
        virtual = Rect(-1920, 0, 5760, 2160)
        self.assertEqual(normalize_absolute(-1920, 0, virtual), (0, 0))
        self.assertEqual(normalize_absolute(3839, 2159, virtual), (65535, 65535))

    def test_interpolate_includes_endpoints(self) -> None:
        pts = interpolate((0, 0), (10, 20), 4)
        self.assertEqual(pts[0], (0, 0))
        self.assertEqual(pts[-1], (10, 20))
        self.assertEqual(len(pts), 5)

    def test_intersect(self) -> None:
        self.assertEqual(Rect(0, 0, 100, 100).intersect(Rect(50, 50, 100, 100)), Rect(50, 50, 50, 50))
        self.assertIsNone(Rect(0, 0, 10, 10).intersect(Rect(20, 20, 5, 5)))


if __name__ == "__main__":
    unittest.main()
