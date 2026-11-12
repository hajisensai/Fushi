import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_now_playing_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 音乐条与「正在听书」条共用的 [FushiNowPlayingBar]：两形态的排布、条身 / 播放键 /
/// 额外动作的接线、滚动收起后的「先展开再进入」。
void main() {
  const Key barKey = ValueKey<String>('bar');
  const Key playKey = ValueKey<String>('play');
  const Key actionKey = ValueKey<String>('action');

  late int taps;
  late int plays;
  late int mores;
  late int prevs;

  setUp(() {
    taps = 0;
    plays = 0;
    mores = 0;
    prevs = 0;
  });

  Widget bar({bool withMore = true}) => FushiNowPlayingBar(
    barKey: barKey,
    playButtonKey: playKey,
    title: 'Song Title',
    subtitle: 'Singer · Album',
    coverBuilder: (BuildContext context, double size) =>
        ColoredBox(color: Theme.of(context).colorScheme.primary),
    isPlaying: false,
    onPlayPause: () => plays++,
    onTap: () => taps++,
    previous: FushiNowPlayingSkip(
      icon: FushiIcons.skipPrevious,
      tooltip: 'Previous',
      onPressed: () => prevs++,
    ),
    next: const FushiNowPlayingSkip(icon: FushiIcons.skipNext, tooltip: 'Next'),
    actions: <Widget>[
      FushiIconButtonControl(
        key: actionKey,
        tooltip: 'Queue',
        onPressed: () {},
        icon: const FushiIcon(FushiIcons.playlist),
      ),
    ],
    onMore: withMore ? () => mores++ : null,
  );

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    required Widget child,
    bool? collapsed,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: collapsed == null
                ? child
                : FushiNowPlayingCollapse(collapsed: collapsed, child: child),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('compact: title is a single text, body / play keys are wired', (
    WidgetTester tester,
  ) async {
    await pump(tester, width: 400, child: bar());
    // 出血大字画在 CustomPaint 里，不是第二个 Text。
    expect(find.text('Song Title'), findsOneWidget);
    expect(find.text('Singer · Album'), findsOneWidget);
    // 窄屏放不下 + 有「更多」菜单：额外动作收起。
    expect(find.byKey(actionKey), findsNothing);
    expect(find.byTooltip('Previous'), findsOneWidget);

    await tester.tap(find.byKey(playKey));
    await tester.tap(find.byTooltip('Previous'));
    await tester.tap(find.text('Song Title'));
    await tester.pump();
    expect(plays, 1);
    expect(prevs, 1);
    expect(taps, 1);

    await tester.longPress(find.text('Song Title'));
    await tester.pump();
    expect(mores, 1);
  });

  testWidgets('compact without a more menu keeps the actions inline', (
    WidgetTester tester,
  ) async {
    await pump(tester, width: 400, child: bar(withMore: false));
    expect(find.byKey(actionKey), findsOneWidget);
  });

  testWidgets('compact collapsed shrinks to cover + play; first tap peeks', (
    WidgetTester tester,
  ) async {
    await pump(tester, width: 400, child: bar(), collapsed: true);
    expect(find.text('Song Title'), findsNothing);
    expect(find.byKey(playKey), findsOneWidget);

    await tester.tap(find.byKey(barKey), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));
    expect(taps, 0, reason: '收起时第一下只展开');
    expect(find.text('Song Title'), findsOneWidget);
  });

  testWidgets('docked shows transport and actions inline', (
    WidgetTester tester,
  ) async {
    await pump(tester, width: 1200, child: bar());
    expect(find.text('Song Title'), findsOneWidget);
    expect(find.text('Singer · Album'), findsOneWidget);
    expect(find.byKey(actionKey), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
  });

  testWidgets('docked collapsed: title + play only, tap pins it open first', (
    WidgetTester tester,
  ) async {
    await pump(tester, width: 1200, child: bar(), collapsed: true);
    expect(find.text('Song Title'), findsOneWidget);
    expect(find.text('Singer · Album'), findsNothing);
    expect(find.byKey(actionKey), findsNothing);

    await tester.tap(find.text('Song Title'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(taps, 0, reason: '收起时第一下只展开');
    expect(find.text('Singer · Album'), findsOneWidget);
    expect(find.byKey(actionKey), findsOneWidget);

    await tester.tap(find.text('Singer · Album'));
    await tester.pump();
    expect(taps, 1);
  });
}
