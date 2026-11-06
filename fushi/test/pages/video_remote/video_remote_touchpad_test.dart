import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_remote_touchpad_gestures.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_touchpad.dart';
import 'package:material_ui/material_ui.dart';

/// 触控板：整屏手势 → 遥控操作；做不了的操作不闪图标。
void main() {
  late List<VideoRemotePadAction> actions;
  late bool accept;

  Widget host({
    VoidCallback? onExit,
    bool caretActive = false,
    bool caretAvailable = false,
  }) => MaterialApp(
    theme: buildFushiFallbackTheme(
      Brightness.light,
    ).copyWith(platform: TargetPlatform.android),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: VideoRemoteTouchpad(
      line: '娘は助けてくれた村人に',
      playing: true,
      onAction: (VideoRemotePadAction action) {
        actions.add(action);
        return accept;
      },
      onExit: onExit ?? () {},
      caretActive: caretActive,
      caretAvailable: caretAvailable,
    ),
  );

  setUp(() {
    actions = <VideoRemotePadAction>[];
    accept = true;
  });

  Finder surface() =>
      find.byKey(const ValueKey<String>('video-remote-touchpad-surface'));
  Finder flash() =>
      find.byKey(const ValueKey<String>('video-remote-touchpad-flash'));

  Future<void> tapSurface(WidgetTester tester) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(surface()),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
  }

  testWidgets('a tap toggles playback once the double-tap window passes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    expect(find.text('娘は助けてくれた村人に'), findsOneWidget);
    await tapSurface(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(actions, isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(actions, <VideoRemotePadAction>[VideoRemotePadAction.playPause]);
    expect(flash(), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(flash(), findsNothing);
  });

  testWidgets('a double tap replays the line', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tapSurface(tester);
    await tester.pump(const Duration(milliseconds: 80));
    await tapSurface(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(actions, <VideoRemotePadAction>[VideoRemotePadAction.replayLine]);
  });

  testWidgets('swipes move between lines and change the volume', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    final Offset center = tester.getCenter(surface());
    for (final Offset delta in <Offset>[
      const Offset(-160, 0),
      const Offset(160, 0),
      const Offset(0, -160),
      const Offset(0, 160),
    ]) {
      final TestGesture gesture = await tester.startGesture(center);
      await gesture.moveBy(delta / 2);
      await gesture.moveBy(delta / 2);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(actions, <VideoRemotePadAction>[
      VideoRemotePadAction.nextLine,
      VideoRemotePadAction.previousLine,
      VideoRemotePadAction.volumeUp,
      VideoRemotePadAction.volumeDown,
    ]);
  });

  testWidgets('a refused action does not flash', (WidgetTester tester) async {
    accept = false;
    await tester.pumpWidget(host());
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(surface()),
    );
    await gesture.moveBy(const Offset(-160, 0));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(actions, <VideoRemotePadAction>[VideoRemotePadAction.nextLine]);
    expect(flash(), findsNothing);
  });

  testWidgets('the exit button leaves the touchpad', (
    WidgetTester tester,
  ) async {
    int exits = 0;
    await tester.pumpWidget(host(onExit: () => exits++));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-remote-touchpad-exit')),
    );
    expect(exits, 1);
    expect(actions, isEmpty);
  });

  testWidgets('holding starts choosing a word when the computer supports it', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(caretAvailable: true));
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(surface()),
    );
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(actions, <VideoRemotePadAction>[VideoRemotePadAction.caretEnter]);
  });

  testWidgets(
    'while choosing, drags step, taps look up at once, two fingers go back',
    (WidgetTester tester) async {
      await tester.pumpWidget(host(caretActive: true, caretAvailable: true));
      expect(
        find.byKey(const ValueKey<String>('video-remote-touchpad-hint-caret')),
        findsOneWidget,
      );
      final Offset center = tester.getCenter(surface());

      // 18 slop + 28×2：两格向右，再拖回一格。
      final TestGesture drag = await tester.startGesture(center);
      await drag.moveBy(const Offset(40, 0));
      await drag.moveBy(const Offset(34, 0));
      await drag.moveBy(const Offset(-30, 0));
      await drag.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(actions, <VideoRemotePadAction>[
        VideoRemotePadAction.caretRight,
        VideoRemotePadAction.caretRight,
        VideoRemotePadAction.caretLeft,
      ]);
      // 逐格挪不闪图标。
      expect(flash(), findsNothing);

      actions.clear();
      await tapSurface(tester);
      await tester.pump();
      expect(actions, <VideoRemotePadAction>[
        VideoRemotePadAction.caretActivate,
      ]);

      actions.clear();
      final TestGesture first = await tester.startGesture(center, pointer: 7);
      final TestGesture second = await tester.startGesture(
        center + const Offset(90, 0),
        pointer: 8,
      );
      await tester.pump(const Duration(milliseconds: 60));
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(actions, <VideoRemotePadAction>[VideoRemotePadAction.caretBack]);
    },
  );

  test('gesture → action mapping', () {
    expect(videoRemotePadActionFor(VideoRemotePadGesture.longPress), isNull);
    expect(
      videoRemotePadActionFor(
        VideoRemotePadGesture.longPress,
        caretAvailable: true,
      ),
      VideoRemotePadAction.caretEnter,
    );
    expect(
      videoRemotePadActionFor(VideoRemotePadGesture.longPress, caret: true),
      VideoRemotePadAction.caretLongPress,
    );
    expect(
      videoRemotePadActionFor(VideoRemotePadGesture.flickLeft, caret: true),
      isNull,
    );
    expect(
      videoRemotePadActionFor(VideoRemotePadGesture.stepDown, caret: true),
      VideoRemotePadAction.caretDown,
    );
    expect(videoRemotePadActionFor(VideoRemotePadGesture.twoFingerTap), isNull);
  });
}
