import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// BUG-1546：设置行说明文字（subtitle）默认不钳行数（BUG-1184 的契约），但旧实现
/// 在 maxLines 为 null 时仍挂着 `TextOverflow.ellipsis`——引擎对「ellipsis 非空 +
/// maxLines 为空」的段落按**单行**布局（dart:ui `ParagraphStyle.ellipsis` 语义），
/// 于是全部设置行说明被钳成一行省略号（用户实报「字幕遮蔽」等描述显示不全）。
/// 本守卫断言：长说明在窄行宽下真实换行成多行；显式传有限 subtitleMaxLines 时
/// 仍按上限截断（BUG-1184 的逃生口不回退）。
void main() {
  const String longSubtitle = '选择听力练习时如何遮蔽字幕：关闭、模糊（悬停或点击显形）'
      '或隐藏（完全不渲染字幕文本，仅保留时间轴与查词能力，适合精听跟读练习）。';

  Widget host({int? subtitleMaxLines}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: AdaptiveSettingsRow(
              title: '字幕遮蔽',
              subtitle: longSubtitle,
              subtitleMaxLines: subtitleMaxLines,
            ),
          ),
        ),
      ),
    );
  }

  /// 说明文字段落的单行高：按其生效 TextStyle 算（bodySmall 12 × height），
  /// 用作「到底渲染了几行」的几何判据。
  double lineHeightOf(RenderParagraph paragraph) {
    final TextStyle style = paragraph.text.style!;
    return (style.fontSize ?? 12) * (style.height ?? 1.5);
  }

  testWidgets('默认（不钳行数）：长说明整段换行成多行，不再单行省略', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(find.text(longSubtitle));
    final double lineHeight = lineHeightOf(paragraph);
    expect(
      paragraph.size.height,
      greaterThan(lineHeight * 1.5),
      reason: '420 宽下这段说明必然超过一行；只有一行高说明 ellipsis + '
          'maxLines:null 又把段落钳回了单行布局（BUG-1546 回归）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('显式 subtitleMaxLines:2：仍按上限截断（逃生口不回退）',
      (WidgetTester tester) async {
    await tester.pumpWidget(host(subtitleMaxLines: 2));
    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(find.text(longSubtitle));
    final double lineHeight = lineHeightOf(paragraph);
    expect(
      paragraph.size.height,
      allOf(greaterThan(lineHeight * 1.5), lessThan(lineHeight * 2.5)),
      reason: '有限值仍要生效：恰好两行高（多于一行、少于三行）',
    );
    expect(tester.takeException(), isNull);
  });
}
