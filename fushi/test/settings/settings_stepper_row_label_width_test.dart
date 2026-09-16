import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

import '../widgets/widget_test_helpers.dart';

// BUG-2550 regression（用户实报：阅读设置里「字号字重显示不全」）。
//
// 阅读器设置面板在手机上宽约 300dp。带图标的 stepper 行行内布局要吃掉
// padding 32 + 图标 42 + 间距 12 + stepper 自身 [kSettingsStepperTrailingWidth]
// （160），标题只剩几十 dp——「字体大小」「字体粗细」「段落间距」全被 ellipsis
// 削成开头一个字。而 [AdaptiveSettingsRow] 的堆叠阈值此前是一个与 trailing 实际
// 宽度无关的经验值（220 × textScale）：行宽卡在阈值上时标题拿到的是
// `220 + 42 − 32 − 42 − 12 − 160 ≈ 16dp`，一个汉字都装不下，却仍判「放得下」。
//
// 关键：这个 bug 抓不到属性层——`Text.maxLines` 是 2（"正确"），坏的是标题拿到的
// 可用宽度。所以守卫拿真实渲染宽度复算标题排不排得下。
//
// 字体注意：widget test 用 Ahem（每个字形宽 = fontSize），对 CJK 的度量与真实
// 字体接近，对西文则高估一倍有余。所以「不截断」这条只用中文真实标题断言；
// 语言无关的部分由下面的「标题最低可读宽度」契约那条覆盖。

/// 标题在自己实际拿到的宽度里是否排不下（= 会被省略号截断）。
///
/// [RenderParagraph] 不暴露 `didExceedMaxLines`，用同一段 span / 同一份排版参数
/// 在**实际渲染宽度**上重跑一次 [TextPainter] 复算。
bool _titleTruncated(RenderParagraph paragraph) {
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    textAlign: paragraph.textAlign,
    maxLines: paragraph.maxLines,
  )..layout(maxWidth: paragraph.size.width);
  final bool exceeded = painter.didExceedMaxLines;
  painter.dispose();
  return exceeded;
}

Future<void> _pumpStepperRow(
  WidgetTester tester, {
  required String title,
  required double width,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    buildTestApp(
      MediaQuery(
        data: MediaQueryData(
          size: Size(width, 720),
          textScaler: TextScaler.linear(textScale),
        ),
        child: SizedBox(
          width: width,
          child: AdaptiveSettingsStepperRow(
            title: title,
            icon: Icons.format_size,
            showIcon: true,
            value: 35,
            step: 1,
            min: 8,
            max: 128,
            format: (double v) => '${v.round()}',
            onChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // 阅读设置面板在手机上的实际内容宽度区间，两端各留一档。
  //
  // 265 是用户那张截图的复现点：旧阈值 `220 + 42 = 262` 刚好放行，标签只剩
  // `265 − 246 = 19dp`，一行一个汉字还多一点——「字体大小」于是只画得出「字」。
  // 坏区间是 262..342（过了阈值、又不够标题读），265 落在最坏的一端。
  const List<double> widths = <double>[260, 265, 300, 320, 340, 360];

  // 这几行的真实标题（`settings_schema_reading.dart` 的 typography 组）。
  const List<String> titles = <String>['字体大小', '字体粗细', '段落间距'];

  // 1x 之外还测放大：用户把系统字体调大时，标题变宽而 stepper 盒子不变
  // （读数走 FittedBox），挤压只会更严重。
  const List<double> textScales = <double>[1, 1.3];

  for (final double textScale in textScales) {
    for (final double width in widths) {
      for (final String title in titles) {
        testWidgets(
          'BUG-2550: stepper row title "$title" stays readable '
          'at ${width}dp / ${textScale}x',
          (WidgetTester tester) async {
            await _pumpStepperRow(
              tester,
              title: title,
              width: width,
              textScale: textScale,
            );
            final RenderParagraph paragraph =
                tester.renderObject<RenderParagraph>(find.text(title));
            expect(
              _titleTruncated(paragraph),
              isFalse,
              reason: '标题 "$title" 在 ${width}dp / ${textScale}x 的行里只拿到 '
                  '${paragraph.size.width.toStringAsFixed(1)}dp，被省略号截断',
            );
          },
        );
      }
    }
  }

  for (final double textScale in textScales) {
    for (final double width in widths) {
      testWidgets(
        'BUG-2550: stepper row title gets at least the minimum readable width '
        'at ${width}dp / ${textScale}x',
        (WidgetTester tester) async {
          const String title = '字体大小';
          await _pumpStepperRow(
            tester,
            title: title,
            width: width,
            textScale: textScale,
          );
          // 量的是**标签列**而不是 `Text`：Text 的 RenderBox 是绘制宽度，短标题
          // 只占自己那几个字，看不出这行到底给了标签多少地方。标签列（Expanded
          // 里的那个 Column）拿的是 tight 约束，宽度就是可用宽。
          final RenderBox labelColumn = tester.renderObject<RenderBox>(
            find
                .ancestor(of: find.text(title), matching: find.byType(Column))
                .first,
          );
          // 契约（语言无关）：行内布局下标签至少拿到
          // [kSettingsRowLabelMinWidth] × 文字缩放；放不下就该堆叠，那时标签
          // 独占整行、宽度只会更大。
          expect(
            labelColumn.size.width,
            greaterThanOrEqualTo(kSettingsRowLabelMinWidth * textScale - 0.5),
            reason: '标签列在 ${width}dp / ${textScale}x 下只拿到 '
                '${labelColumn.size.width.toStringAsFixed(1)}dp，低于最低可读宽度',
          );
        },
      );
    }
  }

  testWidgets(
    'BUG-2550: a wide row keeps the stepper inline (no needless stacking)',
    (WidgetTester tester) async {
      await _pumpStepperRow(tester, title: '字体大小', width: 560);
      final double titleCenterY = tester.getCenter(find.text('字体大小')).dy;
      final double stepperCenterY = tester.getCenter(find.text('35')).dy;
      expect(
        (titleCenterY - stepperCenterY).abs(),
        lessThan(1),
        reason: '宽行里标题与 stepper 仍应同处一行，不该白白堆叠',
      );
    },
  );

  testWidgets(
    'BUG-2550: the declared stepper trailing width matches what it renders',
    (WidgetTester tester) async {
      // 契约的另一半：声明值写错了，堆叠点就会偏。用一个宽到必然行内的行
      // 量 stepper 的真实固有宽度，钉住 [kSettingsStepperTrailingWidth]。
      await _pumpStepperRow(tester, title: '字体大小', width: 800);
      final RenderBox stepper = tester.renderObject<RenderBox>(
        find.ancestor(
          of: find.text('35'),
          matching: find.byType(Wrap),
        ),
      );
      expect(
        stepper.size.width,
        closeTo(kSettingsStepperTrailingWidth, 1),
        reason: 'stepper 实宽 ${stepper.size.width} 与声明的 '
            '$kSettingsStepperTrailingWidth 不符，堆叠判据会偏',
      );
    },
  );
}
