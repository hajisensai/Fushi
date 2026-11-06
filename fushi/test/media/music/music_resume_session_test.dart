// 音乐逐曲断点续播的写入 / 读取（MusicSession，反馈 QAondMh4M5）：真引擎 + 假后端 + 内存库。
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart'
    show MediaPlayIntent;
import 'package:fushi_core/fushi_core.dart';

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<(String, Duration)> opened = <(String, Duration)>[];

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
    Duration startAt = Duration.zero,
  }) async => opened.add((current.trackUid, startAt));

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];

  void position(int seconds) =>
      controller.add(MusicBackendPosition(Duration(seconds: seconds), null));
}

MusicPlayItem _item(String uid, {int minutes = 30}) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  durationMs: minutes * 60000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel audioSessionChannel = MethodChannel(
    'com.ryanheise.audio_session',
  );

  late FushiDatabase db;
  late _Backend backend;
  late MusicSession session;
  late MusicResumeMode mode;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
    MusicSession.hasSystemMediaSession = false;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    backend = _Backend();
    mode = MusicResumeMode.longTracks;
    session = MusicSession(
      engine: MusicPlayerEngine(backendFactory: () => backend),
      audio: AudioController(),
      audiobook: AudiobookSession(
        audioHandler: () => null,
        showFloatingLyric: () => false,
        showMediaNotification: () => false,
        floatingLyricVisibleLines: () => 1,
        floatingLyricStyle: () => const FloatingLyricStyle(
          fontSize: 16,
          textColor: 0,
          bgColor: 0,
          buttonTextColor: 0,
          buttonBgColor: 0,
          highlightColor: 0,
          activeColor: 0,
        ),
        floatingLyricClickLookup: () => false,
        onFloatingLyricLookup: (_, __, ___) {},
        controlStreams: const AudioControlStreams(
          playIntentStream: Stream<MediaPlayIntent>.empty(),
          seekStream: Stream<Duration>.empty(),
          skipNextStream: Stream<void>.empty(),
          skipPreviousStream: Stream<void>.empty(),
          toggleFloatingLyricStream: Stream<void>.empty(),
        ),
        database: () => null,
        studyIdleTimeout: () => const Duration(minutes: 10),
      ),
      database: () => db,
      showMediaNotification: () => false,
      resumeMode: () => mode,
    );
  });

  tearDown(() async {
    await session.resumeWritesIdle;
    session.dispose();
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  Future<int?> saved(String uid) async {
    await session.resumeWritesIdle;
    return (await db.getMusicResumePoint(uid))?.positionMs;
  }

  test('在播时每 5 秒写一次；换下一首按换下前的位置结算（不节流）', () async {
    await session.engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
    backend.position(61);
    expect(await saved('a'), 61000);
    backend.position(64);
    expect(await saved('a'), 61000, reason: '不到 5 秒不写');
    backend.position(66);
    expect(await saved('a'), 66000);
    backend.position(68);
    await session.engine.skipNext();
    expect(await saved('a'), 68000, reason: '换下时写换下前的精确位置');
  });

  test('再打开同一首从断点起播；读之前先等在途的写落库', () async {
    await session.engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
    backend.position(90);
    await session.engine.skipNext();
    // 不等写落库就切回来：读断点前会先等那笔写。
    await session.engine.jumpTo(0);
    expect(backend.opened.last, ('a', const Duration(seconds: 90)));
  });

  test('恢复没落地时打开期的 0 不写；落地前停止也不把断点冲掉', () async {
    await db.upsertMusicResumePoint('a', positionMs: 600000, updatedAt: 1);
    await session.engine.playQueue(<MusicPlayItem>[_item('a')]);
    expect(backend.opened.last, ('a', const Duration(minutes: 10)));
    backend.position(0);
    expect(await saved('a'), 600000);
    await session.stop();
    expect(await saved('a'), 600000);
  });

  test('暂停时拖动（系统媒体控件 / 耳机 / 进度条）立即写', () async {
    await session.engine.playQueue(<MusicPlayItem>[_item('a')]);
    backend.position(20);
    await session.engine.pause();
    await session.engine.seek(const Duration(minutes: 12));
    expect(await saved('a'), 720000);
  });

  test('flushResumePoint 写穿此刻的位置；听到片尾区删行', () async {
    await session.engine.playQueue(<MusicPlayItem>[_item('a', minutes: 60)]);
    backend.position(100);
    backend.position(102);
    await session.flushResumePoint();
    expect((await db.getMusicResumePoint('a'))?.positionMs, 102000);
    backend.position(59 * 60);
    await session.flushResumePoint();
    expect(await db.getMusicResumePoint('a'), isNull, reason: '读时也会从头放');
  });

  test('长曲目模式下歌曲（< 8 分钟）不记也不续；关掉模式不读断点', () async {
    await session.engine.playQueue(<MusicPlayItem>[_item('song', minutes: 4)]);
    backend.position(70);
    await session.flushResumePoint();
    expect(await db.getMusicResumePoint('song'), isNull);

    await db.upsertMusicResumePoint('a', positionMs: 300000, updatedAt: 1);
    mode = MusicResumeMode.off;
    await session.engine.playQueue(<MusicPlayItem>[_item('a')]);
    expect(backend.opened.last, ('a', Duration.zero));
  });

  test('clearResumePoint 删行', () async {
    await db.upsertMusicResumePoint('a', positionMs: 300000, updatedAt: 1);
    await session.clearResumePoint('a');
    expect(await db.getMusicResumePoint('a'), isNull);
  });
}
