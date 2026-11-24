import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 反馈 TinO49VcdQ：首页「今日」格的大字下面那行今日时长在窄窗口里被裁掉下半截。
/// 大字 + 副行要按内容区**实际**高度排：副行要么完整画出，要么整行不画，绝不被
/// 裁掉一部分；格子够高时副行一定在。
void main() {
  const ValueKey<String> timeKey = ValueKey<String>('time-line');

  Widget buildCell({required double height, required double textScale}) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 170,
              height: height,
              child: HomeWidgetFrame(
                title: '今日',
                icon: Icons.bar_chart,
                hueKey: 'today',
                poster: true,
                dense: homeWidgetIsDense(height),
                child: Builder(
                  builder: (BuildContext context) {
                    final TextStyle caption = FushiDesignTokens.of(
                      context,
                    ).type.metadata;
                    return HomeWidgetFigureWithLine(
                      figure: HomeWidgetFigure(
                        value: '3775',
                        unit: '字',
                        large: !homeWidgetIsDense(height),
                      ),
                      line: Row(
                        key: timeKey,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(Icons.schedule, size: 13),
                          const SizedBox(width: 4),
                          Text('27 分钟', maxLines: 1, style: caption),
                        ],
                      ),
                      lineStyle: caption,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final double textScale in <double>[1.0, 1.3]) {
    for (final double height in <double>[76, 96, 104, 120, 140, 180]) {
      testWidgets('格高 $height · 文字缩放 $textScale：时长行完整可见或整行不画，大字不越界', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          buildCell(height: height, textScale: textScale),
        );
        expect(tester.takeException(), isNull);

        final Rect content = tester.getRect(
          find.byType(HomeWidgetFigureWithLine),
        );
        final Rect figure = tester.getRect(find.byType(HomeWidgetFigure));
        expect(figure.top, greaterThanOrEqualTo(content.top - 0.01));
        expect(figure.bottom, lessThanOrEqualTo(content.bottom + 0.01));
        expect(figure.height, greaterThan(0));

        final Finder time = find.byKey(timeKey);
        if (height >= 120 && textScale == 1.0) {
          expect(time, findsOneWidget, reason: '格子够高时时长行一定在');
        }
        if (time.evaluate().isNotEmpty) {
          final Rect line = tester.getRect(time);
          expect(line.top, greaterThanOrEqualTo(figure.bottom));
          expect(line.bottom, lessThanOrEqualTo(content.bottom + 0.01));
          final Rect text = tester.getRect(find.text('27 分钟'));
          expect(text.bottom, lessThanOrEqualTo(content.bottom + 0.01));
          final RenderParagraph paragraph = tester.renderObject(
            find.text('27 分钟'),
          );
          expect(paragraph.didExceedMaxLines, isFalse);
        }
        // 外框里没有把内容裁掉的层（此前的 ClipRect + OverflowBox）。
        expect(
          find.descendant(
            of: find.byType(HomeWidgetFigureWithLine),
            matching: find.byType(OverflowBox),
          ),
          findsNothing,
        );
      });
    }
  }

  // Apple 分区卡（合并 develop 时并进来的 [HomeWidgetFigureWithLine.alignment]）：大字
  // 贴着卡头排，不在内容区里竖向居中；缺省仍竖向居中。
  for (final AlignmentGeometry alignment in <AlignmentGeometry>[
    AlignmentDirectional.centerStart,
    AlignmentDirectional.topStart,
  ]) {
    testWidgets('alignment $alignment：整组按 alignment 摆', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 170,
                height: 200,
                child: HomeWidgetFigureWithLine(
                  figure: const HomeWidgetFigure(value: '12'),
                  line: const Text('27 分钟', key: timeKey),
                  lineStyle: const TextStyle(fontSize: 12),
                  alignment: alignment,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final Rect content = tester.getRect(
        find.byType(HomeWidgetFigureWithLine),
      );
      final Rect figure = tester.getRect(find.byType(HomeWidgetFigure));
      final Rect line = tester.getRect(find.byKey(timeKey));
      if (alignment == AlignmentDirectional.topStart) {
        expect(figure.top, moreOrLessEquals(content.top));
      } else {
        expect(
          figure.top - content.top,
          moreOrLessEquals(content.bottom - line.bottom, epsilon: 0.5),
        );
        expect(figure.top, greaterThan(content.top + 1));
      }
    });
  }
}
