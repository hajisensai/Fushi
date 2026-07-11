import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reading_statistics_page.dart';

/// 回归守卫：手机窄屏统计页「好多显示不全的字」。
///
/// 统计页的小格子（[StatMiniTile] / [StatSummaryTile]）过去把 [Text] 钉死
/// `maxLines: 1`，手机上 1/3~1/2 卡片宽放不下中文标签或「速度·日期」复合值，
/// 就被省略号裁掉。修复放开到 2 行换行。本测试在窄约束下渲染真实生产 widget，
/// 断言换行后未溢出 maxLines（完整可读），并用「窄屏高度 > 单行基线高度」佐证
/// 该宽度确实放不下单行——即若回退成 `maxLines: 1` 必被裁，测试会失败。
void main() {
  RenderParagraph paragraphOf(WidgetTester tester, String text) {
    return tester.renderObject<RenderParagraph>(find.text(text));
  }

  Future<void> pumpTile(WidgetTester tester, Widget child, double width) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('StatSummaryTile 窄屏复合值换行不被裁', (WidgetTester tester) async {
    const String value = '12345 字/小时 · 06-07';
    const String label = '最快的一天';
    const Widget tile = StatSummaryTile(label: label, value: value);

    // 单行基线：极宽约束下复合值必然只占 1 行。
    await pumpTile(tester, tile, 1000);
    final double singleLineHeight = paragraphOf(tester, value).size.height;

    // 手机半宽速度摘要格：单行放不下，需换到 2 行（测试字体全宽 CJK 下 W≈291，
    // 可用宽=box-gap(8)=192∈(W/2, W) → 恰好 2 行且放得下）。
    await pumpTile(tester, tile, 200);
    final RenderParagraph valuePara = paragraphOf(tester, value);

    expect(valuePara.didExceedMaxLines, isFalse, reason: '复合数值应换行显示完整，不被省略号裁掉');
    expect(valuePara.size.height, greaterThan(singleLineHeight),
        reason: '窄屏该值已换行（高于单行基线），单行必被裁——证明 2 行是修复关键');

    expect(paragraphOf(tester, label).didExceedMaxLines, isFalse);
  });

  testWidgets('StatMiniTile 窄屏长标签换行不被裁', (WidgetTester tester) async {
    const String label = '加权平均阅读速度';
    const String value = '12345 字/时';
    const Widget tile = StatMiniTile(label: label, value: value);

    await pumpTile(tester, tile, 1000);
    final double singleLineHeight = paragraphOf(tester, label).size.height;

    // 三宫格每格宽度量级；MiniTile 水平开销=gap(8)+card*2(40)=48，
    // 可用宽=130-48=82∈(W/2, W)（标签 W≈99）→ 恰好 2 行且放得下。
    await pumpTile(tester, tile, 130);
    final RenderParagraph labelPara = paragraphOf(tester, label);

    expect(labelPara.didExceedMaxLines, isFalse, reason: '中文标签应换行显示完整，不被省略号裁掉');
    expect(labelPara.size.height, greaterThan(singleLineHeight),
        reason: '窄格该标签已换行，单行必被裁');
  });
}
