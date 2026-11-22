// 「模糊 NSFW 封面」开关变化时，音乐会话要立刻重发当前媒体卡（HBK-AUDIT-217）：
// 暂停时没有进度 tick，只靠 tick 重发的话，锁屏会一直挂着开关变化前发布的原图。
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

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
  }) async {}

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
}

/// 不走 `AudioService.init`（测试里没有平台实现，它会起 flutter_cache_manager 抛异步
/// 错）：直接给一个本地 [FushiAudioHandler]，与 init 失败时的退路同形。
class _Audio extends AudioController {
  final FushiAudioHandler handler = FushiAudioHandler(
    onPlayIntent: (_) {},
    onSeek: (_) {},
    onRewind: () {},
    onFastForward: () {},
  );

  @override
  FushiAudioHandler? get audioHandler => handler;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel audioSessionChannel = MethodChannel(
    'com.ryanheise.audio_session',
  );

  late FushiDatabase db;
  late _Audio audio;
  late Directory tmp;
  late File cover;
  late ValueNotifier<bool> blur;
  late StreamController<MediaNsfwSnapshot> nsfw;
  late MusicSession session;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    audio = _Audio();
    tmp = await Directory.systemTemp.createTemp('music_nsfw_blur');
    cover = await File('${tmp.path}/r18.jpg').writeAsBytes(<int>[1, 2, 3]);
    blur = ValueNotifier<bool>(false);
    nsfw = StreamController<MediaNsfwSnapshot>.broadcast();
    session = MusicSession(
      engine: MusicPlayerEngine(backendFactory: _Backend.new),
      audio: audio,
      hasSystemMediaSession: false,
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
      showMediaNotification: () => true,
      watchNsfw: (FushiDatabase _) => nsfw.stream,
      blurNsfwCovers: blur,
    );
  });

  tearDown(() async {
    session.dispose();
    await nsfw.close();
    blur.dispose();
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  test('暂停中打开 / 关闭「模糊 NSFW 封面」：媒体卡立刻去掉 / 补回 NSFW 专辑的封面', () async {
    await db.setMediaNsfw(TagHostKind.musicAlbum, 'r18', true);
    final MediaNsfwSnapshot snap = await MediaNsfwSnapshot.load(db);
    await session.engine.playQueue(<MusicPlayItem>[
      MusicPlayItem(
        trackUid: 't',
        path: '/m/t.flac',
        title: 't',
        albumUid: 'r18',
        coverPath: cover.path,
        durationMs: 60000,
      ),
    ]);
    // 第一次推卡时才开始订阅快照；送一份快照进去（它也会触发一次重发）。
    nsfw.add(snap);
    await pumpEventQueue();
    await session.engine.pause();
    final FushiAudioHandler handler = audio.handler;
    expect(
      handler.mediaItem.value?.artUri,
      Uri.file(cover.path),
      reason: '开关关着：照常给图',
    );

    blur.value = true;
    expect(
      handler.mediaItem.value?.artUri,
      isNull,
      reason: '暂停中没有进度 tick，也要立刻撤掉原图',
    );

    blur.value = false;
    expect(handler.mediaItem.value?.artUri, Uri.file(cover.path));
  });
}
