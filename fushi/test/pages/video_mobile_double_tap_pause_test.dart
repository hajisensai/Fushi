import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_asbplayer_config.dart';
import 'package:fushi/src/media/video/video_double_tap_center_action.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// BUG-3310（反馈 #lGxHvuULXI「iOS 视频双击无法暂停」）。
///
/// 用**真实的** vendored 移动控制条（[AdaptiveVideoControls] → `MaterialVideoControls`，
/// 自带 onTap / onDoubleTap / 长按 / 横竖滑识别器）挂在真 [Video] 里，外面套与页面
/// `_buildVideoControlsInner` 同构的宿主层：translucent [Listener]（onPointerUp）+
/// 长按 [GestureDetector]。宿主 pointer-up 用页面同款 400ms / 48px 认双击，落空后问
/// 生产判据 [resolveVideoDoubleTapCenterAction]，开关取自生产
/// [VideoAsbplayerConfig.decode]。
///
/// 证明两件事：
/// 1. fork 的双击识别器在手势竞技场里赢了也吞不掉宿主的 pointer-up（Listener 不进
///    竞技场）——iOS 与 Android 都一样，触摸双击中带确实走到判据；
/// 2. 真正让 iOS 双击静默失效的是配置：电脑上关掉「点击画面播放/暂停」后同步到手机
///    的旧档 `{"tapTogglesPlayback":false}`。修复前判据读这个鼠标单击开关 → none；
///    修复后读独立的 `doubleTapTogglesPlayback`（旧档缺省 = 开）→ 照常暂停。
class _FakePlayer extends Fake implements Player {
  int toggles = 0;

  @override
  PlayerState get state => const PlayerState();

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
  Future<void> playOrPause() async => toggles++;
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

/// 与页面 `_handleVideoPointerUp` 同口径的宿主双击记账（400ms / 48px，看抬起）。
class _HostDoubleTap {
  _HostDoubleTap({required this.config, required this.player});

  final VideoAsbplayerConfig config;
  final _FakePlayer player;
  final List<VideoDoubleTapCenterAction> decisions =
      <VideoDoubleTapCenterAction>[];
  DateTime? _lastAt;
  Offset? _lastPosition;

  void onPointerUp(PointerUpEvent event) {
    final DateTime now = DateTime.now();
    final DateTime? lastAt = _lastAt;
    final Offset? lastPosition = _lastPosition;
    _lastAt = now;
    _lastPosition = event.position;
    if (lastAt == null || lastPosition == null) return;
    if (now.difference(lastAt) > const Duration(milliseconds: 400)) return;
    if ((event.position - lastPosition).distance > 48) return;
    _lastAt = null;
    _lastPosition = null;
    final VideoDoubleTapCenterAction action = resolveVideoDoubleTapCenterAction(
      desktopControls: false,
      touchLikePointer: isTouchLikePointerKind(event.kind),
      doubleTapTogglesPlayback: config.doubleTapTogglesPlayback,
    );
    decisions.add(action);
    if (action == VideoDoubleTapCenterAction.togglePlayback) {
      unawaited(player.playOrPause());
    }
  }
}

void main() {
  const Size phoneLandscape = Size(874, 402);
  const Offset center = Offset(437, 201);

  Future<_HostDoubleTap> pumpPlayer(
    WidgetTester tester, {
    required TargetPlatform platform,
    required String configJson,
  }) async {
    // 移动控制条与页面的移动分支都按 `Theme.of(context).platform` 选，这里同口径。
    await tester.binding.setSurfaceSize(phoneLandscape);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlayer player = _FakePlayer();
    final _HostDoubleTap host = _HostDoubleTap(
      config: VideoAsbplayerConfig.decode(configJson),
      player: player,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Video(
            controller: _FakeVideoController(player),
            wakelock: false,
            pauseUponEnteringBackgroundMode: false,
            subtitleViewConfiguration: const SubtitleViewConfiguration(
              visible: false,
            ),
            controls: (VideoState state) => MaterialVideoControlsTheme(
              normal: const MaterialVideoControlsThemeData(
                seekGesture: true,
                volumeGesture: true,
              ),
              fullscreen: const MaterialVideoControlsThemeData(),
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerUp: host.onPointerUp,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onLongPressStart: (_) {},
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(child: AdaptiveVideoControls(state)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return host;
  }

  Future<void> touchDoubleTap(WidgetTester tester, Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(at + const Offset(6, 4), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // 让 fork 控制条的自动隐藏 Timer 走完。
    await tester.pump(const Duration(seconds: 5));
  }

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name}：电脑同步来的「单击暂停=关」不再吃掉触屏双击暂停', (
      WidgetTester tester,
    ) async {
      final _HostDoubleTap host = await pumpPlayer(
        tester,
        platform: platform,
        configJson: '{"tapTogglesPlayback":false}',
      );
      await touchDoubleTap(tester, center);
      expect(host.decisions, <VideoDoubleTapCenterAction>[
        VideoDoubleTapCenterAction.togglePlayback,
      ]);
      expect(host.player.toggles, 1);
      await unmount(tester);
    });
  }

  testWidgets('iOS：用户显式关掉「双击画面播放/暂停」后双击不改播放态', (WidgetTester tester) async {
    final _HostDoubleTap host = await pumpPlayer(
      tester,
      platform: TargetPlatform.iOS,
      configJson: '{"doubleTapTogglesPlayback":false}',
    );
    await touchDoubleTap(tester, center);
    // 双击仍被宿主认出（fork 识别器没吞掉 pointer-up），只是判据按开关不动作。
    expect(host.decisions, <VideoDoubleTapCenterAction>[
      VideoDoubleTapCenterAction.none,
    ]);
    expect(host.player.toggles, 0);
    await unmount(tester);
  });

  testWidgets('Android：左区触屏双击同样到达宿主 pointer-up（快退快进入口不被 fork 吞掉）', (
    WidgetTester tester,
  ) async {
    // 页面在判据之前先跑 `_handleDoubleTapSeek`（左右三分之一快退快进），它与本修复
    // 无关；这里只钉它的前提——fork 的双击识别器赢下竞技场后，宿主照样认出左区双击。
    final _HostDoubleTap host = await pumpPlayer(
      tester,
      platform: TargetPlatform.android,
      configJson: '',
    );
    await touchDoubleTap(tester, const Offset(80, 201));
    expect(host.decisions, hasLength(1));
    await unmount(tester);
  });
}
