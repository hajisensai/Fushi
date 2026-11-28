import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 ONOhm9EOY3：首页「最近添加」的高格子里，书封扇形（绕底边中点斜放）最左
/// 那本的左上角与下角探出色块、被圆角裁掉。扇形里每一本在静止与悬停两个姿态下
/// 都必须整张落在色块里——规整块与高格子都要成立。
void main() {
  const ValueKey<String> blockKey = ValueKey<String>('block');
  const List<ValueKey<String>> coverKeys = <ValueKey<String>>[
    ValueKey<String>('cover-0'),
    ValueKey<String>('cover-1'),
    ValueKey<String>('cover-2'),
  ];

  /// 封面经姿态变换后四个角的外接框（全局坐标）。
  Rect paintedBounds(WidgetTester tester, Finder cover) {
    final RenderBox box = tester.renderObject<RenderBox>(cover);
    final List<Offset> corners = <Offset>[
      box.localToGlobal(Offset.zero),
      box.localToGlobal(Offset(box.size.width, 0)),
      box.localToGlobal(Offset(0, box.size.height)),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    ];
    Rect out = Rect.fromPoints(corners.first, corners.first);
    for (final Offset c in corners) {
      out = out.expandToInclude(Rect.fromPoints(c, c));
    }
    return out;
  }

  for (final (String name, Size size, int count) in <(String, Size, int)>[
    ('最近添加高格子 · 三本', const Size(420, 440), 3),
    ('最近添加高格子 · 两本', const Size(420, 440), 2),
    ('最近添加高格子 · 一本', const Size(420, 440), 1),
    ('规整块 · 三本', const Size(470, 280), 3),
  ]) {
    testWidgets('书封扇形（$name）：静止 / 悬停每一本都整张在色块内', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(600, 600) * 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: SizedBox(
                  key: blockKey,
                  width: size.width,
                  height: size.height,
                  child: FushiCoverBlock(
                    title: 'BanG Dream! It\'s MyGO!!!!!',
                    art: FushiCoverBlockArt.book,
                    covers: <Widget>[
                      for (int i = 0; i < count; i++)
                        ColoredBox(
                          key: coverKeys[i],
                          color: const Color(0xFF3366AA),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final Rect block = tester.getRect(find.byKey(blockKey));

      void expectInside(String pose) {
        for (int i = 0; i < count; i++) {
          final Rect painted = paintedBounds(tester, find.byKey(coverKeys[i]));
          final String why = '$pose 第 $i 本 $painted / $block';
          expect(painted.left, greaterThanOrEqualTo(block.left), reason: why);
          expect(painted.top, greaterThanOrEqualTo(block.top), reason: why);
          expect(painted.right, lessThanOrEqualTo(block.right), reason: why);
          expect(painted.bottom, lessThanOrEqualTo(block.bottom), reason: why);
        }
      }

      expectInside('rest');
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byKey(blockKey)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expectInside('hover');
    });
  }
}
