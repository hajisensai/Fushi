import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';

// TODO-1143 行为守卫：远端视频区头部两个固定中文标签（标题「Hibiki 互联」+ 副标题
// 「对端设备视频」）原先塞进同一个 Row 各占一个 Flexible，窄屏（手机）下二者抢同
// 一行宽度互相挤压，被 maxLines:1 + ellipsis 截成「…」。修复把标题与副标题拆成两
// 行：副标题独占第二行整行宽度。
//
// widget 测试字体与真机中日韩字体度量不同，无法可靠复现真机字符级截断；因此这里
// 守两条字体无关的结构不变量：
//   1. 副标题独占第二行（其顶边在标题底边之下）——证明不再与标题同处一行互挤。
//   2. 窄宽（320px）下标题/副标题各自独占整行，均不触发 ellipsis
//      （didExceedMaxLines == false）。
void main() {
  const String title = 'Hibiki 互联';
  const String subtitle = '对端设备视频';

  Widget wrap(double width) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: const RemoteVideoSectionHeader(
              title: title,
              subtitle: subtitle,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'TODO-1143: remote video header stacks subtitle onto its own line so the '
    'two fixed CJK labels no longer share one row and truncate',
    (WidgetTester tester) async {
      await tester.pumpWidget(wrap(320)); // 手机窄宽。
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // (1) 结构：副标题落在标题下方，独占第二行（不再侧向并排互挤）。
      final Rect titleRect = tester.getRect(find.text(title));
      final Rect subtitleRect = tester.getRect(find.text(subtitle));
      expect(subtitleRect.top, greaterThanOrEqualTo(titleRect.bottom),
          reason: '副标题必须独占标题下方的第二行，而非与标题同处一行');

      // (2) 效果：窄宽下两标签各自独占整行，均不被 ellipsis 截断。
      final RenderParagraph titlePara =
          tester.renderObject<RenderParagraph>(find.text(title));
      final RenderParagraph subtitlePara =
          tester.renderObject<RenderParagraph>(find.text(subtitle));
      expect(titlePara.didExceedMaxLines, isFalse,
          reason: '标题独占首行，320px 内不应触发 ellipsis');
      expect(subtitlePara.didExceedMaxLines, isFalse,
          reason: '副标题独占第二行整行，320px 内不应触发 ellipsis');
    },
  );
}
