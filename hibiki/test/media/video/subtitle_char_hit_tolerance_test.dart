import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';

void main() {
  // TODO-916 症状④-B：字幕字符命中容差（纯函数 resolveSubtitleCharHit）。
  // 一排 10px 宽的字符，字符间有 4px 间隙（Wrap gap / 描边外缘）。
  List<Rect> row() => <Rect>[
        const Rect.fromLTWH(0, 0, 10, 20), // 0: x[0,10]
        const Rect.fromLTWH(14, 0, 10, 20), // 1: x[14,24]
        const Rect.fromLTWH(28, 0, 10, 20), // 2: x[28,38]
      ];

  test('精确命中：点落在字符矩形内返回该字符', () {
    expect(resolveSubtitleCharHit(row(), const Offset(5, 10)), 0);
    expect(resolveSubtitleCharHit(row(), const Offset(19, 10)), 1);
    expect(resolveSubtitleCharHit(row(), const Offset(33, 10)), 2);
  });

  test('落在字缝内：兜底命中最近字符（半字宽 = 5px 容差内）', () {
    // 字符 0 右缘 x=10、字符 1 左缘 x=14；缝中点 x=12 距两者各 2px < 5px 容差。
    final int hit = resolveSubtitleCharHit(row(), const Offset(12, 10));
    expect(hit, anyOf(0, 1), reason: '字缝内应兜底命中相邻字符之一');
    // 偏向字符 1 一侧（x=13，距 1 仅 1px、距 0 为 3px）→ 命中更近的 1。
    expect(resolveSubtitleCharHit(row(), const Offset(13, 10)), 1);
    // 偏向字符 0 一侧（x=11，距 0 仅 1px）→ 命中更近的 0。
    expect(resolveSubtitleCharHit(row(), const Offset(11, 10)), 0);
  });

  test('描边外缘垂直方向小幅 miss：在容差内兜底', () {
    // 字符 0 顶 y=0，点 y=-3（描边上缘外 3px，水平在字符内 x=5）→ 容差内命中 0。
    expect(resolveSubtitleCharHit(row(), const Offset(5, -3)), 0);
  });

  test('超出容差：返回 -1（不误命中远处字符）', () {
    // x=50 远在所有字符右侧 > 半字宽 → miss。
    expect(resolveSubtitleCharHit(row(), const Offset(50, 10)), -1);
    // y=40 远在下方 > 容差（min 6px）→ miss。
    expect(resolveSubtitleCharHit(row(), const Offset(5, 40)), -1);
  });

  test('Rect.zero（无 RenderBox 的字符）被跳过', () {
    final List<Rect> rects = <Rect>[
      Rect.zero,
      const Rect.fromLTWH(0, 0, 10, 20),
    ];
    expect(resolveSubtitleCharHit(rects, const Offset(5, 10)), 1);
    expect(resolveSubtitleCharHit(rects, const Offset(500, 500)), -1);
  });

  test('空列表返回 -1', () {
    expect(resolveSubtitleCharHit(<Rect>[], const Offset(5, 10)), -1);
  });
}
