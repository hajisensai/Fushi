import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart'
    show FushiPageTitleTier;
import 'package:material_ui/material_ui.dart';

/// BUG-5611：二级页页头大字（设置子页、音乐 / 媒体服务器二级页）的页名不能被
/// 自己的段落边界裁掉下伸部（「Page background」的 g）。
///
/// RenderParagraph 只在「排版尺寸超出自身尺寸」或「超出 maxLines」时按自身边界
/// 裁切（overflow = ellipsis）。页名行高紧（0.98 / 1.05），字形下伸部本来就伸出
/// 行盒；以前段落被按理论行盒（字号 × 行高）卡高，引擎把段落高取整后（54.6 →
/// 55）判溢出、裁切，下伸部就被切掉。
void main() {
  // FlutterTest 字体：ascent 0.75em、descent 0.25em。
  const double naturalDescentEm = 0.25;

  RenderParagraph titleParagraph(WidgetTester tester, String title) =>
      tester.renderObject<RenderParagraph>(find.text(title));

  Future<void> pumpHeader(
    WidgetTester tester, {
    required Size size,
    required String title,
    required double progress,
    FushiPageTitleTier tier = FushiPageTitleTier.section,
    bool titleInBody = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: FushiMastheadHeader(
              title: title,
              titleTier: tier,
              progress: progress,
              titleInBody: titleInBody,
              titleReveal: 1,
              subtitle: const Text('Per-module backdrops'),
              onBack: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final FushiPageTitleTier tier in FushiPageTitleTier.values) {
    for (final Size size in const <Size>[Size(402, 874), Size(1400, 900)]) {
      for (final double progress in const <double>[0, 0.3, 0.5, 1]) {
        testWidgets(
          '${tier.name} ${size.width.toInt()} 宽 p=$progress：页名段落不溢出、不裁切',
          (WidgetTester tester) async {
            const String title = 'Page background';
            await pumpHeader(
              tester,
              size: size,
              title: title,
              progress: progress,
              tier: tier,
            );
            final RenderParagraph p = titleParagraph(tester, title);
            expect(p.didExceedMaxLines, isFalse);
            expect(p.textSize.height, lessThanOrEqualTo(p.size.height));
            expect(p.textSize.width, lessThanOrEqualTo(p.size.width));
          },
        );
      }
    }
  }

  testWidgets('titleInBody 裸图标行：页名段落不溢出、不裁切', (WidgetTester tester) async {
    const String title = 'Page background';
    await pumpHeader(
      tester,
      size: const Size(402, 874),
      title: title,
      progress: 1,
      titleInBody: true,
    );
    final RenderParagraph p = titleParagraph(tester, title);
    expect(p.textSize.height, lessThanOrEqualTo(p.size.height));
  });

  testWidgets('两行仍放不下出省略号：段落下沿盖住末行自然下伸量', (WidgetTester tester) async {
    // 一个长词放不进窄窗两行：走省略号兜底，段落按自身边界裁切。页名档行高
    // 0.98 < FlutterTest 字体的自然行高 1.0，按行高压缩后的下沿比字形下伸部
    // 高；段落下沿必须按字体自然下伸量排，才不会切掉末行的下伸部。
    const String title =
        'Pgqypgqypgqypgqypgqypgqypgqy pgqypgqypgqypgqypgqypgqypgqy '
        'pgqypgqypgqypgqypgqypgqypgqy';
    await pumpHeader(
      tester,
      size: const Size(402, 874),
      title: title,
      progress: 0,
      tier: FushiPageTitleTier.page,
    );
    final RenderParagraph p = titleParagraph(tester, title);
    expect(p.didExceedMaxLines, isTrue, reason: '此用例要走省略号兜底');
    final double font = p.text.style!.fontSize!;
    final double lineHeight = font * p.text.style!.height!;
    final double lastBaseline =
        p.computeDistanceToActualBaseline(TextBaseline.alphabetic) + lineHeight;
    expect(
      p.size.height,
      greaterThanOrEqualTo(lastBaseline + naturalDescentEm * font - 0.01),
    );
  });
}
