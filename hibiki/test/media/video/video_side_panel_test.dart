import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_side_panel.dart';

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
    expect(material.color, isNotNull);
    expect(material.color!.a, lessThan(1));
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

    final Material left = await pumpPanel(Alignment.centerLeft);
    expect(
      left.borderRadius,
      const BorderRadiusDirectional.horizontal(end: Radius.circular(8)),
      reason: '左侧面板贴左边，内侧应是右边圆角',
    );
    expect(tester.getTopLeft(find.byType(Material).last).dx, 10);

    final Material right = await pumpPanel(Alignment.centerRight);
    expect(
      right.borderRadius,
      const BorderRadiusDirectional.horizontal(start: Radius.circular(8)),
      reason: '右侧面板贴右边，内侧应是左边圆角',
    );
    expect(tester.getTopRight(find.byType(Material).last).dx, 790);
  });
}
