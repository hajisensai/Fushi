import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_m3e_chrome.dart'
    show videoM3eFloatingColor;
import 'package:fushi/src/media/video/video_side_panel.dart';

void main() {
  testWidgets('VideoTranslucentSidePanel keeps the video area visible',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            const ColoredBox(color: Colors.green),
            VideoTranslucentSidePanel(
              title: 'Speed',
              onClose: () {},
              child: const Text('1.5x'),
            ),
          ],
        ),
      ),
    );

    final Material material = tester.widget<Material>(
      find
          .ancestor(
            of: find.text('Speed'),
            matching: find.byType(Material),
          )
          .first,
    );
    // M3E：浮动面板与播放器悬浮胶囊同一层无色相中性深色表面
    // （videoM3eFloatingColor，#2D2D2D @86%）；画面靠面板四周的留白与面板宽度露出。
    expect(material.color, videoM3eFloatingColor());
    // 面板内容读中性主题：浅色 app 主题下标题也是白字（不是黑压黑）。
    final BuildContext ctx = tester.element(find.text('Speed'));
    expect(Theme.of(ctx).colorScheme.onSurface, Colors.white);
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('1.5x'), findsOneWidget);
    // BUG-254：右上角 X 关闭按钮已删除（关闭改由页面层全屏 barrier 点面板外承载）。
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('VideoTranslucentSidePanel mirrors rounded side on the left',
      (WidgetTester tester) async {
    Future<Material> pumpPanel(Alignment alignment) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 480,
            child: VideoTranslucentSidePanel(
              title: alignment == Alignment.centerLeft ? 'Left' : 'Right',
              alignment: alignment,
              child: const Text('Panel'),
            ),
          ),
        ),
      );
      return tester.widget<Material>(
        find
            .ancestor(
              of: find
                  .text(alignment == Alignment.centerLeft ? 'Left' : 'Right'),
              matching: find.byType(Material),
            )
            .first,
      );
    }

    // 面板不再是「贴边抽屉」：它四边都留 10 的安全间距浮在画面上，所以四个角都
    // 该露出来（PR #800）。旧断言要求只在靠画面那一侧加圆角、外侧留直角——那是
    // 贴边形态的契约，面板改成浮动卡片后它描述的是已经不存在的外观。
    //
    // 镜像这件事因此从「圆角换边」挪到了**位置**上：左对齐贴左、右对齐贴右，两侧
    // 各留同一个 10 的间距；圆角则两边完全一致。两条一起断，退回半圆角抽屉、或
    // 左右间距不对称，都当场红。
    // MD3 Expressive 浮动面板圆角 28（四角一致）。
    const BorderRadius floatingRadius = BorderRadius.all(Radius.circular(28));
    BorderRadiusGeometry? radiusOf(Material m) =>
        (m.shape as RoundedRectangleBorder?)?.borderRadius;

    final Material left = await pumpPanel(Alignment.centerLeft);
    expect(
      radiusOf(left),
      floatingRadius,
      reason: '浮动侧栏四边都有间距，四个角都应是圆角（不是贴边抽屉的半圆角）',
    );
    expect(tester.getTopLeft(find.byType(Material).last).dx, 10,
        reason: '左对齐时面板贴左，留 10 的安全间距');

    final Material right = await pumpPanel(Alignment.centerRight);
    expect(
      radiusOf(right),
      floatingRadius,
      reason: '左右两侧圆角必须一致——镜像体现在位置上，不再体现在圆角换边',
    );
    expect(tester.getTopRight(find.byType(Material).last).dx, 790,
        reason: '右对齐时面板贴右，留同样 10 的安全间距（800 - 10）');
  });
}
