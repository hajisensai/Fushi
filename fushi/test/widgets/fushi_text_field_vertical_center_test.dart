import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

/// BUG-2973：共享输入框 [FushiTextField] 的文字 / 占位符在框内竖直居中。
///
/// 用户截图（iPhone、Apple 设计系统、自定义主题页）：AI 多行输入框的两行
/// 占位符下沉半行、第二行掉出框外被裁。根因是 Apple 分支的多行框没给
/// CupertinoTextField 显式对齐，它在有占位符时缺省居中，把一行高的编辑区
/// 居中进两行高的占位符栈。这里对 MD3 / Apple × 单行 / 多行 × 有无标题
/// 逐一断言：占位符完整落在输入框内，且它的竖直中心与框的中心差 ≤ 1.5px。
const String _shortHint = '自定义 1';
const String _longHint = '描述想要的主题，例如：暖色纸张阅读、深夜低蓝光、森林绿色调的界面配色方案';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool apple,
}) async {
  tester.view.physicalSize = const Size(420, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    ),
    textTheme: Typography.material2021(
      platform: TargetPlatform.iOS,
    ).englishLike.merge(Typography.material2021().white),
    glass: apple ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: apple,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: <Widget>[child]),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Rect _globalRect(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// 输入框的可见外壳：MD3 是 [InputDecorator]（填充块），Apple 是壳里带
/// 填充色的 [AnimatedContainer]。
Rect _shellRect(WidgetTester tester, {required bool apple}) {
  final Finder shell = apple
      ? find
            .descendant(
              of: find.byType(FushiTextField),
              matching: find.byType(AnimatedContainer),
            )
            .first
      : find.byType(InputDecorator);
  return _globalRect(tester.renderObject<RenderBox>(shell));
}

void main() {
  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';
    for (final ({int minLines, int maxLines, String hint}) c
        in <({int minLines, int maxLines, String hint})>[
          (minLines: 1, maxLines: 1, hint: _shortHint),
          (minLines: 1, maxLines: 2, hint: _longHint),
          (minLines: 2, maxLines: 4, hint: _longHint),
        ]) {
      testWidgets(
        '$ds · minLines=${c.minLines} maxLines=${c.maxLines}：占位符完整在框内且竖直居中',
        (WidgetTester tester) async {
          await _pump(
            tester,
            FushiTextField(
              controller: TextEditingController(),
              hintText: c.hint,
              minLines: c.minLines,
              maxLines: c.maxLines,
            ),
            apple: apple,
          );
          final RenderParagraph hint = tester.renderObject<RenderParagraph>(
            find.text(c.hint),
          );
          final Rect hintRect = _globalRect(hint);
          final Rect shell = _shellRect(tester, apple: apple);
          expect(
            hintRect.top,
            greaterThanOrEqualTo(shell.top),
            reason: '占位符顶边越出输入框',
          );
          expect(
            hintRect.bottom,
            lessThanOrEqualTo(shell.bottom),
            reason: '占位符底边掉出输入框（被裁）：$hintRect vs $shell',
          );
          // 输入区比占位符高时（minLines 撑出的空行 / 正文字号大于占位符字号），
          // 占位符按顶对齐落在输入区上部，允许的偏差是两者高度差的一半。
          final Rect editable = _globalRect(
            tester.renderObject<RenderBox>(find.byType(EditableText)),
          );
          final double slack =
              ((editable.height - hintRect.height).clamp(0, double.infinity)) /
              2;
          expect(
            (hintRect.center.dy - shell.center.dy).abs(),
            lessThanOrEqualTo(1.5 + slack),
            reason: '占位符 $hintRect 偏离框 $shell（输入区 $editable）',
          );
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }

    testWidgets(
      '$ds · 带标题的单行框：输入文字在框内竖直居中',
      (WidgetTester tester) async {
        await _pump(
          tester,
          FushiTextField(
            controller: TextEditingController(text: '暖纸'),
            labelText: '名称',
            hintText: _shortHint,
          ),
          apple: apple,
        );
        final Rect text = _globalRect(
          tester.renderObject<RenderBox>(find.byType(EditableText)),
        );
        final Rect shell = _shellRect(tester, apple: apple);
        expect(text.top, greaterThanOrEqualTo(shell.top));
        expect(text.bottom, lessThanOrEqualTo(shell.bottom));
        if (apple) {
          // Apple 的标题在框外上方，框内只有输入行：严格居中。MD3 填充式
          // 文本框的浮动标题占框内上部，输入行按 M3 规格偏下，只要求不出框。
          expect(
            (text.center.dy - shell.center.dy).abs(),
            lessThanOrEqualTo(1.5),
          );
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
