import 'dart:async';

import 'package:audio_service/audio_service.dart' as ag;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_background_media_session.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';

/// 拍板台 42UUu_kcwD-media：视频后台放声音时挂进系统媒体会话，与有声书 / 音乐按
/// 「后开播的认领、被抢的暂停」共用同一个 audio_service 会话。

class _FakeTarget extends ChangeNotifier implements VideoMediaSessionTarget {
  @override
  bool isPlaying = true;
  @override
  int positionMs = 0;
  @override
  int? durationMs = 600000;
  @override
  double speed = 1.0;
  final List<String> calls = <String>[];

  @override
  Future<void> play() async {
    calls.add('play');
    isPlaying = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    isPlaying = false;
    notifyListeners();
  }

  @override
  Future<void> seekMs(int positionMs) async => calls.add('seek:$positionMs');

  @override
  Future<void> seekRelativeMs(int deltaMs) async => calls.add('rel:$deltaMs');

  @override
  Future<void> skipCue({required bool forward}) async =>
      calls.add(forward ? 'next' : 'prev');
}

class _FakeFocus implements VideoAudioFocus {
  int activations = 0;
  final StreamController<AudioInterruptionEvent> interruptionsCtrl =
      StreamController<AudioInterruptionEvent>.broadcast(sync: true);
  final StreamController<void> noisyCtrl = StreamController<void>.broadcast(
    sync: true,
  );

  @override
  Future<void> activate() async => activations++;

  @override
  Stream<AudioInterruptionEvent> get interruptions => interruptionsCtrl.stream;

  @override
  Stream<void> get becomingNoisy => noisyCtrl.stream;
}

class _Controls {
  final StreamController<MediaPlayIntent> play =
      StreamController<MediaPlayIntent>.broadcast(sync: true);
  final StreamController<Duration> seek = StreamController<Duration>.broadcast(
    sync: true,
  );
  final StreamController<void> next = StreamController<void>.broadcast(
    sync: true,
  );
  final StreamController<void> prev = StreamController<void>.broadcast(
    sync: true,
  );
  final StreamController<void> rewind = StreamController<void>.broadcast(
    sync: true,
  );
  final StreamController<void> forward = StreamController<void>.broadcast(
    sync: true,
  );

  VideoMediaSessionControls get controls => VideoMediaSessionControls(
    playIntents: play.stream,
    seeks: seek.stream,
    skipNext: next.stream,
    skipPrevious: prev.stream,
    rewind: rewind.stream,
    fastForward: forward.stream,
  );
}

FushiAudioHandler _handler() => FushiAudioHandler(
  onPlayIntent: (_) {},
  onSeek: (_) {},
  onRewind: () {},
  onFastForward: () {},
  onToggleFloatingLyric: () {},
);

const VideoMediaSessionInfo _info = VideoMediaSessionInfo(
  title: '第3話',
  subtitle: 'ゆるキャン△',
);

void main() {
  group('AudioController 会话仲裁', () {
    late AudioController audio;
    setUp(() => audio = AudioController());
    tearDown(() => audio.dispose());

    test('抢别人持有的会话 → 被抢方的回调被调；让回 none 不算抢', () {
      final List<String> preempted = <String>[];
      audio.seat(MediaSessionOwner.audiobook).onPreempted = () =>
          preempted.add('audiobook');
      audio.seat(MediaSessionOwner.music).onPreempted = () =>
          preempted.add('music');
      audio.claimSession(MediaSessionOwner.audiobook);
      expect(preempted, isEmpty, reason: '从 none 认领不算抢');
      audio.claimSession(MediaSessionOwner.video);
      expect(preempted, <String>['audiobook']);
      audio.claimSession(MediaSessionOwner.none);
      audio.claimSession(MediaSessionOwner.music);
      expect(preempted, <String>['audiobook'], reason: '让回 none 再认领不算抢');
      audio.claimSession(MediaSessionOwner.music);
      expect(preempted, <String>['audiobook'], reason: '重复认领自己不回调');
    });

    test('控制流只发给持有方；有声书在无人持有时也收', () async {
      final StreamController<int> src = StreamController<int>.broadcast(
        sync: true,
      );
      final List<String> got = <String>[];
      audio
          .streamFor(src.stream, MediaSessionOwner.audiobook)
          .listen((int v) => got.add('audiobook$v'));
      audio
          .streamFor(src.stream, MediaSessionOwner.video)
          .listen((int v) => got.add('video$v'));
      audio
          .streamFor(src.stream, MediaSessionOwner.music)
          .listen((int v) => got.add('music$v'));
      src.add(1);
      audio.claimSession(MediaSessionOwner.video);
      src.add(2);
      audio.claimSession(MediaSessionOwner.music);
      src.add(3);
      expect(got, <String>['audiobook1', 'video2', 'music3']);
      await src.close();
    });

    test('座位：release 只在自己正式持有时让回 none', () {
      final MediaSessionSeat video = audio.seat(MediaSessionOwner.video);
      expect(video.claim(), isTrue);
      expect(video.claim(), isFalse);
      audio.claimSession(MediaSessionOwner.music);
      video.release();
      expect(audio.sessionOwner.value, MediaSessionOwner.music);
      expect(audio.seat(MediaSessionOwner.audiobook).held, isFalse);
      audio.claimSession(MediaSessionOwner.none);
      expect(audio.seat(MediaSessionOwner.audiobook).held, isTrue);
      expect(audio.seat(MediaSessionOwner.audiobook).claimed, isFalse);
    });
  });

  group('VideoBackgroundMediaSession', () {
    late AudioController audio;
    late _FakeTarget target;
    late _FakeFocus focus;
    late _Controls controls;
    late FushiAudioHandler handler;
    late DateTime now;
    bool full = true;

    VideoBackgroundMediaSession build() => VideoBackgroundMediaSession(
      seat: audio.seat(MediaSessionOwner.video),
      handler: () async => handler,
      controls: controls.controls,
      fullNotification: () => full,
      focus: focus,
      now: () => now,
    );

    setUp(() {
      audio = AudioController();
      target = _FakeTarget();
      focus = _FakeFocus();
      controls = _Controls();
      handler = _handler();
      now = DateTime(2026, 11, 23, 12);
      full = true;
    });
    tearDown(() => audio.dispose());

    test('engage：认领会话、抢走有声书（暂停）、挂完整卡片且没有悬浮字幕键', () async {
      int audiobookPaused = 0;
      audio.seat(MediaSessionOwner.audiobook).onPreempted = () =>
          audiobookPaused++;
      audio.claimSession(MediaSessionOwner.audiobook);
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      expect(session.engaged, isTrue);
      expect(audio.sessionOwner.value, MediaSessionOwner.video);
      expect(audiobookPaused, 1);
      expect(focus.activations, 1);
      final ag.MediaItem? item = handler.mediaItem.value;
      expect(item?.title, '第3話');
      expect(item?.artist, 'ゆるキャン△');
      expect(item?.duration, const Duration(minutes: 10));
      final ag.PlaybackState state = handler.playbackState.value;
      expect(state.playing, isTrue);
      expect(state.controls, contains(ag.MediaControl.skipToNext));
      expect(
        state.controls.where(
          (ag.MediaControl c) => c.action == ag.MediaAction.custom,
        ),
        isEmpty,
        reason: '后台视频没有悬浮字幕可开',
      );
      await session.release();
    });

    test('「显示媒体通知」关着 → 最简形态（照推播放态，Android 才有前台服务）', () async {
      full = false;
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      expect(handler.mediaItem.value?.artist, isNull);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.controls, hasLength(1));
      await session.release();
    });

    test('锁屏 / 耳机控制发到视频播放器', () async {
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      controls.play.add(MediaPlayIntent.toggle);
      controls.play.add(MediaPlayIntent.play);
      controls.play.add(MediaPlayIntent.play); // 蓝牙重连补发的 PLAY：保持播放
      controls.seek.add(const Duration(seconds: 42));
      controls.next.add(null);
      controls.prev.add(null);
      controls.rewind.add(null);
      controls.forward.add(null);
      expect(target.calls, <String>[
        'pause',
        'play',
        'play',
        'seek:42000',
        'next',
        'prev',
        'rel:-5000',
        'rel:5000',
      ]);
      await session.release();
    });

    test('来电打断暂停、结束续播；用户中途亲手按过就不替他续', () async {
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      focus.interruptionsCtrl.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      expect(target.isPlaying, isFalse);
      focus.interruptionsCtrl.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(target.isPlaying, isTrue);
      focus.interruptionsCtrl.add(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(target.isPlaying, isTrue, reason: '压低音量不暂停');
      focus.interruptionsCtrl.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      controls.play.add(MediaPlayIntent.pause);
      focus.interruptionsCtrl.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(target.isPlaying, isFalse);
      await session.release();
    });

    test('耳机拔出 → 暂停', () async {
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      focus.noisyCtrl.add(null);
      expect(target.isPlaying, isFalse);
      await session.release();
    });

    test('被音乐抢走 → 视频暂停、不再收控制、不撤对方的卡', () async {
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      audio.claimSession(MediaSessionOwner.music);
      expect(target.isPlaying, isFalse);
      expect(session.engaged, isFalse);
      handler.setMediaItemInfo(title: 'music');
      target.calls.clear();
      controls.play.add(MediaPlayIntent.play);
      expect(target.calls, isEmpty);
      await session.release();
      expect(handler.mediaItem.value?.title, 'music');
      expect(audio.sessionOwner.value, MediaSessionOwner.music);
    });

    test('refreshInfo：卡片信息后到（封面异步探测完）按最新信息重推；没挂着时不推', () async {
      final VideoBackgroundMediaSession session = build();
      session.refreshInfo();
      expect(handler.mediaItem.value, isNull, reason: '未 engage 不得推卡');
      VideoMediaSessionInfo info = _info;
      await session.engage(target, () => info);
      expect(handler.mediaItem.value?.artUri, isNull);
      final Uri cover = Uri.file('/covers/yurucamp.jpg');
      info = VideoMediaSessionInfo(
        title: _info.title,
        subtitle: _info.subtitle,
        artUri: cover,
      );
      session.refreshInfo();
      expect(handler.mediaItem.value?.artUri, cover);
      await session.release();
      info = const VideoMediaSessionInfo(title: 'stale');
      session.refreshInfo();
      expect(handler.mediaItem.value, isNull, reason: '让出后不得再推卡');
    });

    test('release：撤卡（Android 随之结束前台服务）并让回 none', () async {
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      await session.release();
      expect(handler.mediaItem.value, isNull);
      expect(handler.playbackState.value.playing, isFalse);
      expect(audio.sessionOwner.value, MediaSessionOwner.none);
      target.calls.clear();
      controls.play.add(MediaPlayIntent.pause);
      expect(target.calls, isEmpty);
    });

    test('新页面接手后，旧页面离场不撤新页面的卡', () async {
      final VideoBackgroundMediaSession first = build();
      final VideoBackgroundMediaSession second = build();
      final _FakeTarget other = _FakeTarget();
      await first.engage(target, () => _info);
      await second.engage(
        other,
        () => const VideoMediaSessionInfo(title: '第4話'),
      );
      expect(first.engaged, isFalse);
      await first.release();
      expect(handler.mediaItem.value?.title, '第4話');
      expect(audio.sessionOwner.value, MediaSessionOwner.video);
      audio.claimSession(MediaSessionOwner.audiobook);
      expect(other.isPlaying, isFalse, reason: '被抢回调仍登记在新页面上');
      await second.release();
    });

    test('进度 tick 不逐拍重推播放态，跳转 / 暂停才推', () async {
      final VideoBackgroundMediaSession session = build();
      await session.engage(target, () => _info);
      final List<ag.PlaybackState> pushed = <ag.PlaybackState>[];
      final StreamSubscription<ag.PlaybackState> sub = handler.playbackState
          .skip(1)
          .listen(pushed.add);
      now = now.add(const Duration(seconds: 1));
      target.positionMs = 1000;
      target.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(pushed, isEmpty);
      target.positionMs = 90000;
      target.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(pushed, hasLength(1));
      await target.pause();
      await Future<void>.delayed(Duration.zero);
      expect(pushed, hasLength(2));
      expect(pushed.last.playing, isFalse);
      await sub.cancel();
      await session.release();
    });
  });

  group('videoMediaSessionNeedsPush', () {
    final DateTime t0 = DateTime(2026, 11, 23);
    VideoMediaSessionSnapshot snap({
      bool playing = true,
      int pos = 0,
      double speed = 1.0,
      bool full = true,
      int atMs = 0,
    }) => (
      playing: playing,
      positionMs: pos,
      speed: speed,
      full: full,
      at: t0.add(Duration(milliseconds: atMs)),
    );

    test('按外推进度判漂移', () {
      expect(videoMediaSessionNeedsPush(null, snap()), isTrue);
      expect(
        videoMediaSessionNeedsPush(snap(), snap(pos: 5000, atMs: 5000)),
        isFalse,
      );
      expect(
        videoMediaSessionNeedsPush(
          snap(speed: 2.0),
          snap(speed: 2.0, pos: 10000, atMs: 5000),
        ),
        isFalse,
        reason: '倍速按速度外推',
      );
      expect(
        videoMediaSessionNeedsPush(snap(), snap(pos: 30000, atMs: 5000)),
        isTrue,
      );
      expect(
        videoMediaSessionNeedsPush(
          snap(playing: false, pos: 100),
          snap(playing: false, pos: 100, atMs: 60000),
        ),
        isFalse,
        reason: '暂停态不外推',
      );
      expect(videoMediaSessionNeedsPush(snap(), snap(playing: false)), isTrue);
      expect(videoMediaSessionNeedsPush(snap(), snap(speed: 1.5)), isTrue);
      expect(videoMediaSessionNeedsPush(snap(), snap(full: false)), isTrue);
    });
  });
}
