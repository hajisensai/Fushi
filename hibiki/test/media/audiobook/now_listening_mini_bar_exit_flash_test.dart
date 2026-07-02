import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/media/audiobook/now_listening_mini_bar.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../../helpers/test_platform_services.dart';

/// TODO-831 行为守卫：关「退出后续播」(audiobookBackgroundPlay=false) 退出有声书时，
/// 书架 [NowListeningMiniBar] 不得「先显一帧播放条再收起」。
///
/// 根因是退出时序：旧实现只在 reader dispose() 才 stop 会话（pop 动画结束后才跑），
/// pop 动画期间下层书架已重建、session 仍存活 → 迷你条显示一帧；dispose 跑 stop 后
/// 才收起 → 一显一隐＝闪。修复把「退出即停」提前到 onSourcePagePop（pop 前 await），
/// 并让 [AudiobookSession.stop] 在第一个 await 前就同步清空会话 + notifyListeners。
///
/// 本测试在 host 上钉住**结果不变量**：一旦会话 stop（同步段一跑完即清空 +
/// 通知），监听 [appProvider] / 会话的迷你条 rebuild 时必须立刻见空会话并收成
/// [SizedBox.shrink]——没有任何「会话已 stop 却仍渲染播放条」的中间可见帧。
/// pop 动画期间下层可见的完整跨页竞态需要真 WebView reader 栈（host 跑不起），
/// 那条原始路径留真机复测；这里覆盖时序契约里可落地的最强一层。
class _MiniBarAppModel extends AppModel {
  _MiniBarAppModel() : super(testPlatformServices());

  // 迷你条 build 在 Windows host 上会进入 `Platform.isWindows` 分支读
  // showFloatingLyric（走 prefsRepo，本未 wire），覆写成关，避免空指针。
  @override
  bool get showFloatingLyric => false;

  // audiobookSession 的后台 surface 回调读 showMediaNotification（走 prefsRepo，
  // 本未 wire），覆写成关让 start/stop 的 surface 路径是 host 安全的惰性空操作。
  @override
  bool get showMediaNotification => false;

  // 退出即停语义：关后台续播。
  @override
  bool get audiobookBackgroundPlay => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Audiobook ab(String key) => Audiobook()
    ..bookKey = key
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';

  File makeFile(String name) {
    final File f = File('${Directory.systemTemp.path}/$name');
    if (!f.existsSync()) f.writeAsBytesSync(const <int>[0]);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    return f;
  }

  void installPlatform() {
    const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _FakePlatform();
    addTearDown(() => JustAudioPlatform.instance = prev);
  }

  SessionPersistCallbacks persist() => SessionPersistCallbacks(
        onPositionWrite: (_, __) async {},
        onDelayPersist: (_) async {},
        onSpeedPersist: (_) async {},
        onVolumePersist: (_) async {},
        onImagePausePersist: (_) async {},
        onFollowAudioPersist: (_) async {},
      );

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    // 悬浮窗在 host 不可用：override 成不支持，所有悬浮窗调用短路。
    FloatingLyricChannel.platformOverride = false;
  });
  tearDown(() {
    FloatingLyricChannel.platformOverride = null;
  });

  testWidgets(
      'mini bar collapses to SizedBox.shrink the same frame the session stops '
      '(no flash of the play bar on exit) — TODO-831', (tester) async {
    installPlatform();
    final _MiniBarAppModel appModel = _MiniBarAppModel();
    // ProviderScope 拥有该 appModel 的生命周期，scope 拆除时会 dispose 它；这里
    // 不再额外 addTearDown(dispose)，否则二次 dispose 触发 ChangeNotifier 断言。

    final AudiobookSession session = appModel.audiobookSession;
    await session.start(
      info: SessionBookInfo(
        bookKey: 'a',
        audiobook: ab('a'),
        title: 'Test Book',
        mediaIdentifier: 'hoshi://book/a',
      ),
      audioFiles: <File>[makeFile('hibiki-minibar-flash.mp3')],
      prefs: const SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: persist(),
    );

    expect(session.book, isNotNull);
    expect(session.controller, isNotNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(body: NowListeningMiniBar()),
          ),
        ),
      ),
    );

    // 初始：活动会话 → 迷你条可见（书名 + 播放条交互层渲染出来）。
    expect(find.text('Test Book'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NowListeningMiniBar),
        matching: find.byType(InkWell),
      ),
      findsWidgets,
      reason: '活动会话时迷你条渲染可点击的播放条',
    );

    // 退出即停：stop 同步段一跑完就清空会话 + notifyListeners（修复前清空被拖到
    // 末尾 await 之后）。await 完成后 pump 一帧让监听者 rebuild。
    await session.stop();
    await tester.pump();

    // 结果不变量：会话已空 → 迷你条收成 SizedBox.shrink，播放条整个消失。
    expect(session.book, isNull);
    expect(session.controller, isNull);
    expect(find.text('Test Book'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NowListeningMiniBar),
        matching: find.byType(InkWell),
      ),
      findsNothing,
      reason: '会话停后迷你条收成 SizedBox.shrink，不再渲染播放条',
    );
  });

  testWidgets('mini bar defers session notifications during tree finalization',
      (tester) async {
    installPlatform();
    final _MiniBarAppModel appModel = _MiniBarAppModel();
    final AudiobookSession session = appModel.audiobookSession;
    await session.start(
      info: SessionBookInfo(
        bookKey: 'a',
        audiobook: ab('a'),
        title: 'Test Book',
        mediaIdentifier: 'hoshi://book/a',
      ),
      audioFiles: <File>[makeFile('hibiki-minibar-locked-tree.mp3')],
      prefs: const SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: persist(),
    );

    Widget harness({required bool includeStopper}) => ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((ref) => appModel),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Column(
                  children: <Widget>[
                    const NowListeningMiniBar(),
                    if (includeStopper) _StopSessionOnDispose(session),
                  ],
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(harness(includeStopper: true));
    expect(find.text('Test Book'), findsOneWidget);

    await tester.pumpWidget(harness(includeStopper: false));
    expect(tester.takeException(), isNull);

    await tester.pump();
    expect(find.text('Test Book'), findsNothing);
  });

  testWidgets('post-frame session notifications request a follow-up frame',
      (tester) async {
    installPlatform();
    final _MiniBarAppModel appModel = _MiniBarAppModel();
    final AudiobookSession session = appModel.audiobookSession;
    await session.start(
      info: SessionBookInfo(
        bookKey: 'a',
        audiobook: ab('a'),
        title: 'Test Book',
        mediaIdentifier: 'hoshi://book/a',
      ),
      audioFiles: <File>[makeFile('hibiki-minibar-post-frame.mp3')],
      prefs: const SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: persist(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(body: NowListeningMiniBar()),
          ),
        ),
      ),
    );
    expect(find.text('Test Book'), findsOneWidget);

    Future<void>? stopping;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      stopping = session.stop();
    });

    await tester.pump();
    expect(stopping, isNotNull);
    final Future<void> pendingStop = stopping!;
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: 'post-frame stop 通知被延后 setState 时必须主动安排下一帧',
    );

    await tester.pump();
    await pendingStop;
    expect(find.text('Test Book'), findsNothing);
  });

  test(
      'AudiobookSession.stop clears book/controller and notifies before the '
      'first await (TODO-831 方案3)', () async {
    installPlatform();
    final _MiniBarAppModel appModel = _MiniBarAppModel();
    addTearDown(appModel.dispose);
    final AudiobookSession session = appModel.audiobookSession;
    await session.start(
      info: SessionBookInfo(
        bookKey: 'a',
        audiobook: ab('a'),
        title: 'Test Book',
        mediaIdentifier: 'hoshi://book/a',
      ),
      audioFiles: <File>[makeFile('hibiki-minibar-notify.mp3')],
      prefs: const SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: persist(),
    );
    expect(session.book, isNotNull);
    expect(session.controller, isNotNull);

    int notifyBefore = 0;
    SessionBookInfo? bookAtNotify;
    AudiobookPlayerController? controllerAtNotify;
    void listener() {
      notifyBefore++;
      bookAtNotify = session.book;
      controllerAtNotify = session.controller;
    }

    session.addListener(listener);
    addTearDown(() => session.removeListener(listener));

    // 触发 stop 但**不 await**：捕捉到第一个 await 边界之前的同步快照。
    final Future<void> stopping = session.stop();

    // 同步段已跑完：book/controller 置空且通知过一次。
    expect(notifyBefore, greaterThanOrEqualTo(1),
        reason: 'stop 同步清空后必须立即 notifyListeners（方案3）');
    expect(bookAtNotify, isNull, reason: '首个 await 前监听者就该见到空 book');
    expect(controllerAtNotify, isNull, reason: '首个 await 前监听者就该见到空 controller');

    await stopping;
    expect(session.isActive, isFalse);
  });
}

class _StopSessionOnDispose extends StatefulWidget {
  const _StopSessionOnDispose(this.session);

  final AudiobookSession session;

  @override
  State<_StopSessionOnDispose> createState() => _StopSessionOnDisposeState();
}

class _StopSessionOnDisposeState extends State<_StopSessionOnDispose> {
  @override
  void dispose() {
    unawaited(widget.session.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _FakePlatform extends JustAudioPlatform {
  _FakePlayer? player;
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _FakePlayer(request.id);
    return player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    await player?.dispose(DisposeRequest());
    return DisposeAllPlayersResponse();
  }
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  void emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    _events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: Duration(milliseconds: ms),
      bufferedPosition: Duration(milliseconds: ms),
      duration: const Duration(seconds: 100),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    emit(request.initialPosition?.inMilliseconds ?? 0,
        ProcessingStateMessage.ready,
        playing: false);
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    emit(request.position?.inMilliseconds ?? 0, ProcessingStateMessage.ready,
        playing: false);
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
          SetWebCrossOriginRequest request) async =>
      SetWebCrossOriginResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}
