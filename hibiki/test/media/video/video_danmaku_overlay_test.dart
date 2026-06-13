import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_overlay.dart';

VideoDanmakuItem _item(int startMs, String text) => VideoDanmakuItem(
      startMs: startMs,
      text: text,
      mode: VideoDanmakuMode.scroll,
      colorArgb: 0xFFFFFFFF,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 400, height: 200, child: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('VideoDanmakuOverlay is IgnorePointer and caps rendered widgets',
      (WidgetTester tester) async {
    int positionMs = 1000;
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[
          _item(0, 'first'),
          _item(10, 'second'),
        ],
        enabled: true,
        maxActive: 1,
        positionMs: () => positionMs,
      ),
    );

    final IgnorePointer ignorePointer = tester.widget<IgnorePointer>(
      find.byKey(const Key('video-danmaku-ignore-pointer')),
    );
    expect(ignorePointer.ignoring, isTrue);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing,
        reason: 'maxActive should cap render count before widgets are built');

    positionMs = 10000;
    await tester.pump();
    expect(find.text('first'), findsNothing,
        reason: 'seek/tick rebuild must not keep stale active comments');
  });

  testWidgets('disabled overlay renders nothing but keeps pointer passthrough',
      (WidgetTester tester) async {
    await _pump(
      tester,
      VideoDanmakuOverlay(
        items: <VideoDanmakuItem>[_item(0, 'hidden')],
        enabled: false,
        maxActive: 20,
        positionMs: () => 1000,
      ),
    );

    final IgnorePointer ignorePointer = tester.widget<IgnorePointer>(
      find.byKey(const Key('video-danmaku-ignore-pointer')),
    );
    expect(ignorePointer.ignoring, isTrue);
    expect(find.text('hidden'), findsNothing);
  });
}
