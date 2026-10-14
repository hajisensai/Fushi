import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/advanced_mining/manga_crop_geometry.dart';

/// 漫画裁切框纯几何（高级制卡 · 漫画图片分区）。控件只把指针 / 按键翻译成这些
/// 调用，边界情形（翻转、越界、最小尺寸、Tab 越界放行）全在这里钉死。
void main() {
  void expectRect(Rect actual, Rect expected) {
    expect(actual.left, closeTo(expected.left, 1e-9), reason: 'left');
    expect(actual.top, closeTo(expected.top, 1e-9), reason: 'top');
    expect(actual.right, closeTo(expected.right, 1e-9), reason: 'right');
    expect(actual.bottom, closeTo(expected.bottom, 1e-9), reason: 'bottom');
  }

  const Rect base = Rect.fromLTRB(0.3, 0.3, 0.6, 0.7);

  group('cropRectFromDrag', () {
    test('任意方向拖出的框都是正向矩形', () {
      const Rect want = Rect.fromLTRB(0.2, 0.3, 0.5, 0.6);
      expectRect(
        cropRectFromDrag(const Offset(0.2, 0.3), const Offset(0.5, 0.6)),
        want,
      );
      expectRect(
        cropRectFromDrag(const Offset(0.5, 0.6), const Offset(0.2, 0.3)),
        want,
      );
      expectRect(
        cropRectFromDrag(const Offset(0.5, 0.3), const Offset(0.2, 0.6)),
        want,
      );
      expectRect(
        cropRectFromDrag(const Offset(0.2, 0.6), const Offset(0.5, 0.3)),
        want,
      );
    });

    test('拖出页面外的点夹回页面', () {
      expectRect(
        cropRectFromDrag(const Offset(-0.2, 0.5), const Offset(1.4, 1.2)),
        const Rect.fromLTRB(0, 0.5, 1, 1),
      );
    });

    test('零尺寸以中心扩到最小尺寸，贴边时整体平移回页面', () {
      expectRect(
        cropRectFromDrag(const Offset(0.5, 0.5), const Offset(0.5, 0.5)),
        const Rect.fromLTRB(0.48, 0.48, 0.52, 0.52),
      );
      expectRect(
        cropRectFromDrag(const Offset(0, 1), const Offset(0, 1)),
        const Rect.fromLTRB(0, 0.96, 0.04, 1),
      );
    });
  });

  group('moveCropRect', () {
    test('平移不改尺寸', () {
      expectRect(
        moveCropRect(base, const Offset(0.1, -0.1)),
        const Rect.fromLTRB(0.4, 0.2, 0.7, 0.6),
      );
    });

    test('撞边停在边上，尺寸不被压缩', () {
      expectRect(
        moveCropRect(base, const Offset(1, 1)),
        const Rect.fromLTRB(0.7, 0.6, 1, 1),
      );
      expectRect(
        moveCropRect(base, const Offset(-1, -1)),
        const Rect.fromLTRB(0, 0, 0.3, 0.4),
      );
    });
  });

  group('resizeCropRect', () {
    const Offset d = Offset(0.05, 0.1);
    const Map<MangaCropHandle, Rect> want = <MangaCropHandle, Rect>{
      MangaCropHandle.topLeft: Rect.fromLTRB(0.35, 0.4, 0.6, 0.7),
      MangaCropHandle.top: Rect.fromLTRB(0.3, 0.4, 0.6, 0.7),
      MangaCropHandle.topRight: Rect.fromLTRB(0.3, 0.4, 0.65, 0.7),
      MangaCropHandle.right: Rect.fromLTRB(0.3, 0.3, 0.65, 0.7),
      MangaCropHandle.bottomRight: Rect.fromLTRB(0.3, 0.3, 0.65, 0.8),
      MangaCropHandle.bottom: Rect.fromLTRB(0.3, 0.3, 0.6, 0.8),
      MangaCropHandle.bottomLeft: Rect.fromLTRB(0.35, 0.3, 0.6, 0.8),
      MangaCropHandle.left: Rect.fromLTRB(0.35, 0.3, 0.6, 0.7),
    };
    for (final MangaCropHandle h in MangaCropHandle.values) {
      test('$h 只动对应的边，对边固定', () {
        expectRect(resizeCropRect(base, h, d), want[h]!);
      });
    }

    test('不能翻转越过对边：夹到最小尺寸', () {
      expectRect(
        resizeCropRect(base, MangaCropHandle.right, const Offset(-1, 0)),
        const Rect.fromLTRB(0.3, 0.3, 0.34, 0.7),
      );
      expectRect(
        resizeCropRect(base, MangaCropHandle.topLeft, const Offset(1, 1)),
        const Rect.fromLTRB(0.56, 0.66, 0.6, 0.7),
      );
      expectRect(
        resizeCropRect(base, MangaCropHandle.bottom, const Offset(0, -1)),
        const Rect.fromLTRB(0.3, 0.3, 0.6, 0.34),
      );
    });

    test('拖出页面外夹在页面边上', () {
      expectRect(
        resizeCropRect(base, MangaCropHandle.bottomRight, const Offset(2, 2)),
        const Rect.fromLTRB(0.3, 0.3, 1, 1),
      );
      expectRect(
        resizeCropRect(base, MangaCropHandle.topLeft, const Offset(-2, -2)),
        const Rect.fromLTRB(0, 0, 0.6, 0.7),
      );
    });
  });

  group('hitTestCropHandle / cropRectContains', () {
    const Rect px = Rect.fromLTWH(100, 100, 200, 100);

    test('命中各手柄', () {
      expect(
        hitTestCropHandle(px, const Offset(101, 99), slop: 12),
        MangaCropHandle.topLeft,
      );
      expect(
        hitTestCropHandle(px, const Offset(200, 100), slop: 12),
        MangaCropHandle.top,
      );
      expect(
        hitTestCropHandle(px, const Offset(300, 150), slop: 12),
        MangaCropHandle.right,
      );
      expect(
        hitTestCropHandle(px, const Offset(300, 200), slop: 12),
        MangaCropHandle.bottomRight,
      );
      expect(hitTestCropHandle(px, const Offset(200, 150), slop: 12), isNull);
    });

    test('小框上角与边中点命中圈重叠时角优先', () {
      const Rect tiny = Rect.fromLTWH(100, 100, 16, 16);
      // 离上边中点 (108,100) 更近，但仍在左上角的命中圈内。
      expect(
        hitTestCropHandle(tiny, const Offset(106, 100), slop: 12),
        MangaCropHandle.topLeft,
      );
    });

    test('框内 / 框外', () {
      expect(cropRectContains(px, const Offset(150, 150)), isTrue);
      expect(cropRectContains(px, const Offset(300, 200)), isTrue);
      expect(cropRectContains(px, const Offset(301, 150)), isFalse);
    });
  });

  group('cyclePanelIndex', () {
    const List<Rect> panels = <Rect>[
      Rect.fromLTRB(0, 0, 1, 0.3),
      Rect.fromLTRB(0, 0.3, 0.5, 0.6),
      Rect.fromLTRB(0.5, 0.3, 1, 0.6),
    ];

    test('当前不是分镜：前进从第一个开始，后退从最后一个开始', () {
      expect(cyclePanelIndex(panels, null), 0);
      expect(cyclePanelIndex(panels, const Rect.fromLTRB(0, 0, 1, 1)), 0);
      expect(cyclePanelIndex(panels, null, backward: true), 2);
    });

    test('依次前进 / 后退，越过两端返回 null 交还焦点遍历', () {
      expect(cyclePanelIndex(panels, panels[0]), 1);
      expect(cyclePanelIndex(panels, panels[1]), 2);
      expect(cyclePanelIndex(panels, panels[2]), isNull);
      expect(cyclePanelIndex(panels, panels[2], backward: true), 1);
      expect(cyclePanelIndex(panels, panels[0], backward: true), isNull);
    });

    test('容差内相等也算同一个分镜', () {
      const Rect near = Rect.fromLTRB(0, 0.3 + 1e-8, 0.5, 0.6);
      expect(cyclePanelIndex(panels, near), 2);
    });

    test('没有分镜返回 null', () {
      expect(cyclePanelIndex(const <Rect>[], null), isNull);
    });
  });

  test('cropOutputPixels 按原页像素取整且至少 1', () {
    expect(
      cropOutputPixels(
        const Rect.fromLTRB(0.5, 0.25, 1, 0.75),
        const Size(1640, 2336),
      ),
      (width: 820, height: 1168),
    );
    expect(
      cropOutputPixels(
        const Rect.fromLTRB(0, 0, 0.0001, 0.0001),
        const Size(100, 100),
      ),
      (width: 1, height: 1),
    );
  });

  group('containRect', () {
    test('竖页放进方框：高度撑满、水平居中', () {
      expectRect(
        containRect(const Size(100, 200), const Size(400, 400)),
        const Rect.fromLTWH(100, 0, 200, 400),
      );
    });

    test('横页放进方框：宽度撑满、垂直居中', () {
      expectRect(
        containRect(const Size(200, 100), const Size(400, 400)),
        const Rect.fromLTWH(0, 100, 400, 200),
      );
    });

    test('尺寸未知返回零矩形', () {
      expect(containRect(Size.zero, const Size(400, 400)), Rect.zero);
      expect(containRect(const Size(1, 1), Size.zero), Rect.zero);
    });
  });
}
