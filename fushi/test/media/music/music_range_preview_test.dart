import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_range_preview.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/range_playback.dart';

/// 记录引擎发给后端的命令；测试手动发后端事件。
class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];

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
  }) async => log.add('open:${current.trackUid}');

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');

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

MusicPlayItem _item(String uid) => MusicPlayItem(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: uid,
  durationMs: 60000,
);

/// 反馈 l8XrV_IfXH：音乐歌词页高级制卡的句子音频试听。结束只认引擎真实事件。
void main() {
  late _Backend backend;
  late MusicPlayerEngine engine;
  late MusicRangePreview preview;

  setUp(() async {
    backend = _Backend();
    engine = MusicPlayerEngine(backendFactory: () => backend);
    await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
    await engine.pause();
    backend.log.clear();
    preview = MusicRangePreview(engine);
  });

  tearDown(() {
    preview.dispose();
    engine.dispose();
  });

  void position(int ms) => backend.controller.add(
    MusicBackendPosition(Duration(milliseconds: ms), null),
  );

  test('跳到起点开播，位置越过终点即暂停并按「播完」结束', () async {
    final RangePlayback playback = await preview.play(
      const Duration(milliseconds: 3500),
      const Duration(milliseconds: 8500),
    );
    expect(backend.log, <String>['seek:3500', 'play']);
    expect(preview.active, isTrue);

    position(6000);
    expect(playback.isEnded, isFalse, reason: '区间内照常播');

    position(8500);
    expect(await playback.ended, RangePlaybackEnd.reachedEnd);
    expect(backend.log.last, 'pause');
    expect(preview.active, isFalse);
  });

  test('显式停止：暂停并按「被打断」结束；之后的位置事件不再影响', () async {
    final RangePlayback playback = await preview.play(
      const Duration(seconds: 1),
      const Duration(seconds: 4),
    );
    await preview.stop();
    expect(await playback.ended, RangePlaybackEnd.interrupted);
    expect(backend.log.last, 'pause');

    backend.log.clear();
    position(5000);
    expect(backend.log, isEmpty, reason: '已结束的试听不再暂停播放器');
  });

  test('被别处暂停 / 换曲：按「被打断」结束', () async {
    final RangePlayback paused = await preview.play(
      const Duration(seconds: 1),
      const Duration(seconds: 4),
    );
    backend.controller.add(const MusicBackendPlaying(false));
    expect(await paused.ended, RangePlaybackEnd.interrupted);

    final RangePlayback skipped = await preview.play(
      const Duration(seconds: 1),
      const Duration(seconds: 4),
    );
    await engine.skipNext();
    expect(await skipped.ended, RangePlaybackEnd.interrupted);
  });

  test('下一段顶掉上一段：上一段按「被打断」结束', () async {
    final RangePlayback first = await preview.play(
      const Duration(seconds: 1),
      const Duration(seconds: 4),
    );
    final RangePlayback second = await preview.play(
      const Duration(seconds: 10),
      const Duration(seconds: 12),
    );
    expect(await first.ended, RangePlaybackEnd.interrupted);
    expect(second.isEnded, isFalse);
    position(12000);
    expect(await second.ended, RangePlaybackEnd.reachedEnd);
  });

  test('空区间：不碰播放器，直接给已结束的句柄', () async {
    final RangePlayback playback = await preview.play(
      const Duration(seconds: 4),
      const Duration(seconds: 4),
    );
    expect(playback.isEnded, isTrue);
    expect(backend.log, isEmpty);
  });
}
