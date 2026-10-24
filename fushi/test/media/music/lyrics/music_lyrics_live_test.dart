import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 歌词页之外的当前行：桌面歌词窗口与锁屏副标题。解析走真 Rust 库（硬依赖）。
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
  Future<void> dispose() => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

class _Surface implements MusicDesktopLyricsSurface {
  final List<String> log = <String>[];
  bool supported = true;
  bool allowShow = true;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> show() async {
    log.add('show');
    return allowShow;
  }

  @override
  Future<void> hide() async => log.add('hide');

  @override
  Future<void> showBlock(
    String text,
    int currentStart,
    int currentLength,
  ) async => log.add(
    'block:${text.replaceAll('\n', '|')}@$currentStart+$currentLength',
  );

  @override
  Future<void> highlight(int start, int length) async =>
      log.add('hl:$start+$length');

  @override
  Future<void> setPlaying(bool playing) async => log.add('playing:$playing');
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FushiDatabase db;
  late Directory dir;
  late _Backend backend;
  late MusicPlayerEngine engine;
  late _Surface surface;
  late bool desktop;
  late bool lockScreen;
  late ValueNotifier<bool> owns;
  late int released;

  MusicPlayItem item(String name) => MusicPlayItem(
    trackUid: name,
    path: '${dir.path}${Platform.pathSeparator}$name.flac',
    title: name,
    durationMs: 60000,
  );

  MusicLyricsLive live() => MusicLyricsLive(
    engine: engine,
    service: MusicLyricsService(
      database: () => db,
      lrclib: LrclibClient(transport: (Uri _) async => (status: 404, body: '')),
      onlineEnabled: () => false,
      readEmbedded: (String _, int? _) async => const <EmbeddedLyrics>[],
      parse: (Uint8List b, String h, int? d) async =>
          FushiLyrics.parse(b, hint: h, durationMs: d),
    ),
    desktop: surface,
    desktopEnabled: () => desktop,
    mediaSessionEnabled: () => lockScreen,
    sessionOwnerChanged: owns,
    musicOwnsSession: () => owns.value,
    onDesktopReleased: () => released++,
  );

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_lyrics_live_');
    for (final String n in <String>['a', 'b']) {
      File(
        '${dir.path}${Platform.pathSeparator}$n.flac',
      ).writeAsBytesSync(<int>[0]);
    }
    File('${dir.path}${Platform.pathSeparator}a.lrc').writeAsStringSync(
      '[00:01.00]<00:01.00>夜に<00:02.00>駆ける<00:03.00>\n'
      '[00:04.00]<00:04.00>沈む<00:05.00>ように<00:06.00>\n',
    );
    backend = _Backend();
    engine = MusicPlayerEngine(backendFactory: () => backend);
    surface = _Surface();
    desktop = true;
    lockScreen = true;
    owns = ValueNotifier<bool>(true);
    released = 0;
  });

  tearDown(() async {
    engine.dispose();
    owns.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('当前行跟位置走：锁屏副标题 + 桌面窗口双行块 + 已唱高亮', () async {
    final MusicLyricsLive l = live();
    addTearDown(l.dispose);
    await engine.playQueue(<MusicPlayItem>[item('a'), item('b')]);
    await _settle();
    expect(l.timeline, isNotNull);
    expect(l.mediaSessionLine, isNull, reason: '前奏没有当前行');
    expect(surface.log, contains('show'));
    expect(surface.log, contains('block:夜に駆ける|沈むように@-1+0'));

    backend.controller.add(
      const MusicBackendPosition(Duration(milliseconds: 2100), null),
    );
    await _settle();
    expect(l.mediaSessionLine, '夜に駆ける');
    expect(surface.log, contains('block:夜に駆ける|沈むように@0+5'));
    expect(surface.log.last, isNot('hl:0+0'));
    expect(surface.log, contains('hl:0+5'), reason: '2.1 s 时两个音节都唱到了');

    lockScreen = false;
    expect(l.mediaSessionLine, isNull, reason: '锁屏开关关着不给行');
  });

  test('有声书持有会话时让出窗口并回调；设置关掉同样隐藏；没有歌词不弹窗', () async {
    final MusicLyricsLive l = live();
    addTearDown(l.dispose);
    await engine.playQueue(<MusicPlayItem>[item('a'), item('b')]);
    await _settle();
    expect(l.desktopShown, isTrue);

    owns.value = false;
    await _settle();
    expect(l.desktopShown, isFalse);
    expect(surface.log.last, 'hide');
    expect(released, 1);

    owns.value = true;
    await _settle();
    expect(l.desktopShown, isTrue);
    desktop = false;
    l.onSettingsChanged();
    await _settle();
    expect(l.desktopShown, isFalse);

    desktop = true;
    surface.log.clear();
    await engine.skipNext(); // b 没有歌词
    await _settle();
    expect(l.timeline, isNull);
    expect(surface.log, isNot(contains('show')));
  });

  test('两项都关着：不解析歌词', () async {
    desktop = false;
    lockScreen = false;
    final MusicLyricsLive l = live();
    addTearDown(l.dispose);
    await engine.playQueue(<MusicPlayItem>[item('a')]);
    await _settle();
    expect(l.timeline, isNull);
    expect(await db.select(db.musicLyrics).get(), isEmpty);
  });
}
