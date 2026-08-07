import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';

// TODO-1143 行为守卫：宽窗阅读器快捷设置左父菜单固定 208px，长分类标签「布局与显示」
// (选中加粗) 曾被 FushiListItem 默认 titleMaxLines:1 + ellipsis 截断成「布局与…」。
// 修复给 _buildWidePane 的分类项传 titleMaxLines: 2。
//
// widget 测试用固定的测试字体（度量与真机中日韩字体不同），无法在 208px 下可靠复现
// 真机的字符级截断；因此这里守两条字体无关的不变量：
//   1. FushiListItem 真把 titleMaxLines 透传到标题的 RenderParagraph（修复所依赖的
//      机制）——默认 1（会截断），传 2 后放行第二行。
//   2. 用标题的真实文字样式跑 TextPainter：在「单行放不下」的净宽内，titleMaxLines:1
//      会 didExceedMaxLines（触发 ellipsis），titleMaxLines:2 则不会（两行救回）。
void main() {
  const String longLabel = '布局与显示';

  Widget wrap(int titleMaxLines) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 208, // 左父菜单 kHibikiSettingsSupportingPaneWidth。
            child: FushiListItem(
              selected: true,
              selectedShape: FushiListItemSelectedShape.pill,
              leading: const Icon(Icons.view_agenda_outlined),
              title: const Text(longLabel),
              titleMaxLines: titleMaxLines,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
  }

  RenderParagraph titleParagraph(WidgetTester tester) {
    return tester.renderObject<RenderParagraph>(find.text(longLabel));
  }

  testWidgets(
    'TODO-1143: FushiListItem forwards titleMaxLines to the nav label so the '
    'wide-pane fix (2) actually lifts the truncating default (1)',
    (WidgetTester tester) async {
      // 默认（1）——正是截断长标签成「布局与…」的根因。
      await tester.pumpWidget(wrap(1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(titleParagraph(tester).maxLines, 1,
          reason: 'FushiListItem 默认 titleMaxLines:1（截断根因）');

      // 修复值（2）——第二行放行。
      await tester.pumpWidget(wrap(2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final RenderParagraph twoLine = titleParagraph(tester);
      expect(twoLine.maxLines, 2,
          reason: 'titleMaxLines: 2 必须真透传到标题，才能让长标签换行而非省略');

      // 用标题的真实样式在「单行放不下」的净宽内验证截断被两行救回（字体无关：
      // 净宽由该字体自身的单行度量派生）。
      final TextStyle? style = (twoLine.text as TextSpan).style;
      final TextPainter oneLine = TextPainter(
        text: TextSpan(text: longLabel, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final double singleLineWidth = oneLine.width;
      oneLine.dispose();

      // 取一个必然放不下整行的净宽（略窄于单行宽），但足够容纳两行。
      final double tightWidth = singleLineWidth * 0.7;

      bool exceedsAt(int maxLines) {
        final TextPainter p = TextPainter(
          text: TextSpan(text: longLabel, style: style),
          maxLines: maxLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: tightWidth);
        final bool exceeded = p.didExceedMaxLines;
        p.dispose();
        return exceeded;
      }

      expect(exceedsAt(1), isTrue,
          reason: '窄净宽内单行放不下「布局与显示」——默认 1 会 ellipsis 截断');
      expect(exceedsAt(2), isFalse,
          reason: '两行能完整显示「布局与显示」——titleMaxLines: 2 即修复');
    },
  );
}
