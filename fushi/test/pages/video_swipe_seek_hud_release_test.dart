import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// BUG-3354（反馈 #J1NJL1a75F「横滑改进度松手那一刻显示的进度变回滑动起始」）。
///
/// 用**真实的** vendored 移动控制条（[AdaptiveVideoControls] → `MaterialVideoControls`）
/// 做一次触屏横滑：HUD 在松手后淡出（AnimatedOpacity），淡出期间仍随 setState 重建。
/// 修复前 HUD 读的是松手即清零的 `swipeDuration`（待提交增量），于是淡出那几帧显示
/// 「起始位置 + 0:00」；seek 本身落点正确。修复后 HUD 读独立的显示增量，松手不清。
class _FakePlayer extends Fake implements Player {
  final List<Duration> seeks = <Duration>[];

  @override
  PlayerState get state => const PlayerState(duration: Duration(minutes: 30));

  @override
  PlayerStream get stream => PlayerStream(
    const Stream<Playlist>.empty(),
    const Stream<bool>.empty(),
    const Stream<bool>.empty(),
    const Stream<Duration>.empty(),
    const Stream<Duration>.empty(),
    const Stream<double>.empty(),
    const Stream<double>.empty(),
    const Stream<double>.empty(),
    const Stream<bool>.empty(),
    const Stream<double>.empty(),
    const Stream<Duration>.empty(),
    const Stream<PlaylistMode>.empty(),
    const Stream<bool>.empty(),
    const Stream<AudioParams>.empty(),
    const Stream<VideoParams>.empty(),
    const Stream<double?>.empty(),
    const Stream<AudioDevice>.empty(),
    const Stream<List<AudioDevice>>.empty(),
    const Stream<Track>.empty(),
    const Stream<Tracks>.empty(),
    const Stream<int?>.empty(),
    const Stream<int?>.empty(),
    const Stream<List<String>>.empty(),
    const Stream<PlayerLog>.empty(),
    const Stream<String>.empty(),
  );

  // 类型由被覆盖的 `Player.platform`（PlatformPlayer?，未从 barrel 导出）推断。
  @override
  // ignore: type_annotate_public_apis, prefer_typing_uninitialized_variables
  var platform;

  @override
  Future<void> seek(Duration duration) async => seeks.add(duration);
}

class _FakeVideoController extends Fake implements VideoController {
  _FakeVideoController(this.player);

  @override
  final Player player;

  @override
  final ValueNotifier<PlatformVideoController?> notifier =
      ValueNotifier<PlatformVideoController?>(null);

  @override
  final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);

  @override
  final ValueNotifier<int?> id = ValueNotifier<int?>(null);

  @override
  final ValueNotifier<Rect?> rect = ValueNotifier<Rect?>(null);
}

void main() {
  const Size phoneLandscape = Size(874, 402);
  const Duration base = Duration(minutes: 15);
  const Duration swipe = Duration(seconds: 42);

  testWidgets('松手后淡出的 HUD 仍显示本次横滑的增量，不回落到 +0', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(phoneLandscape);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlayer player = _FakePlayer();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: Video(
            controller: _FakeVideoController(player),
            wakelock: false,
            pauseUponEnteringBackgroundMode: false,
            subtitleViewConfiguration: const SubtitleViewConfiguration(
              visible: false,
            ),
            controls: (VideoState state) => MaterialVideoControlsTheme(
              normal: MaterialVideoControlsThemeData(
                seekGesture: true,
                relativeSeekBasePosition: () => base,
                horizontalSeekResolver:
                    ({
                      required double dragDx,
                      required double surfaceWidth,
                      required Duration duration,
                      required Duration position,
                    }) => dragDx > 0 ? swipe : Duration.zero,
                seekIndicatorBuilder: (BuildContext _, Duration delta) =>
                    Text('HUD ${(base + delta).inSeconds}'),
              ),
              fullscreen: const MaterialVideoControlsThemeData(),
              child: AdaptiveVideoControls(state),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final TestGesture gesture = await tester.startGesture(
      const Offset(300, 201),
      kind: PointerDeviceKind.touch,
    );
    for (int i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final String target = 'HUD ${(base + swipe).inSeconds}';
    expect(find.text(target), findsOneWidget, reason: '拖动中 HUD 显示目标');

    await gesture.up();
    // 淡出动画的第一帧：HUD 仍在树上（AnimatedOpacity 正在变透明）。
    await tester.pump(const Duration(milliseconds: 16));
    expect(player.seeks, <Duration>[base + swipe], reason: '落点本就正确');
    expect(
      find.text(target),
      findsOneWidget,
      reason: '淡出期间 HUD 必须仍显示刚提交的目标，而不是起始位置',
    );
    expect(find.text('HUD ${base.inSeconds}'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
