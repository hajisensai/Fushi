import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import 'manga_tilted_block_frame_bug5308_fixture.dart';

/// BUG-5308：漫画朗读当前句高亮 / 识别范围框画在轴对齐的块框上，斜排文字的
/// 高亮不跟字转。块级要带上由字格拟合出的有向外框。
void main() {
  final MokuroImage page = bug5308Page();

  test('斜排块：由字格拟合出的有向外框还原整列的转角、边长与中心', () {
    final MokuroOrientedRect? frame = mangaBlockOrientedFrame(
      mangaEffectiveTextRegions(page.blocks[0]),
    );
    expect(frame, isNotNull);
    expect(frame!.rotation, closeTo(kBug5308Tilt, 1e-9));
    expect(frame.width, closeTo(40, 1e-6));
    expect(frame.height, closeTo(120, 1e-6));
    expect(frame.center.dx, closeTo(200, 1e-6));
    expect(frame.center.dy, closeTo(200, 1e-6));
  });

  test('正立块没有有向外框（块框本身就是正框）', () {
    expect(
      mangaBlockOrientedFrame(mangaEffectiveTextRegions(page.blocks[1])),
      isNull,
    );
  });

  test('转角在 ±45° 折叠处两侧的字格按圆周均值合并，不会平均成 0', () {
    const double a = 44 * math.pi / 180;
    const double b = -44 * math.pi / 180; // 与 a 同为一个方向（差 88° ≈ 90°）
    final MokuroOrientedRect? frame =
        mangaBlockOrientedFrame(const <MangaOcrTextRegion>[
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTWH(0, 0, 10, 10),
            utf16Start: 0,
            utf16End: 1,
            rotation: a,
          ),
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTWH(20, 20, 10, 10),
            utf16Start: 1,
            utf16End: 2,
            rotation: b,
          ),
        ]);
    expect(frame!.rotation.abs(), closeTo(45 * math.pi / 180, 1e-9));
  });

  test('overlay：斜块带 data-ocr-frame 与转角变量，正立块不带', () {
    final String html = mangaOcrBoxesHtml(page);
    final List<String> boxes = RegExp(
      r'<p class="ocr-box"[^>]*>',
    ).allMatches(html).map((RegExpMatch m) => m.group(0)!).toList();
    expect(boxes, hasLength(2));
    expect(boxes[0], contains('data-ocr-frame="1"'));
    expect(boxes[0], contains('--ocr-frame-r:-20deg;'));
    expect(boxes[0], contains('--ocr-frame-w:'));
    expect(boxes[1], isNot(contains('data-ocr-frame')));
    expect(boxes[1], isNot(contains('--ocr-frame')));
  });
}
