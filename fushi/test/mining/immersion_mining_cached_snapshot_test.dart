import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show FfmpegFailureReporter, MiningMediaCompression;

/// 在线视频制卡的播放器缓冲副本（`CachedMediaSnapshot`）与「看完再制卡」暂存
/// （`stageNote`）在引擎里的契约。
class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;
  int mineCalls = 0;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mineCalls++;
    minedContext = context;
    return const MineOutcome.success(noteId: 7);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Call {
  _Call(this.input, this.startMs, this.endMs, this.headers);

  final String input;
  final int startMs;
  final int endMs;
  final Map<String, String> headers;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mine_snapshot');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  const MiningMediaCompression compression = MiningMediaCompression.compressed;
  const String remote = 'https://media.example/Videos/1/stream?static=true';

  /// 抽取器：记录每次调用；[failOn] 命中的输入返回 null（模拟抽取失败）。
  ({
    List<_Call> gif,
    List<_Call> audio,
    List<double> frameAt,
    ImmersionMiningEngine engine,
  })
  harness({String? failOn}) {
    final List<_Call> gif = <_Call>[];
    final List<_Call> audio = <_Call>[];
    final List<double> frameAt = <double>[];
    final ImmersionMiningEngine engine = ImmersionMiningEngine(
      gifExtractor:
          ({
            required String inputPath,
            required int startMs,
            required int endMs,
            required String outputPath,
            int fps = 8,
            int width = 320,
            MiningAnimatedFormat format = MiningAnimatedFormat.gif,
            bool diagnosticOnly = false,
            FfmpegFailureReporter? onFailure,
            String? tlsPinSha256,
            Map<String, String> httpHeaders = const <String, String>{},
          }) async {
            gif.add(_Call(inputPath, startMs, endMs, httpHeaders));
            if (inputPath == failOn) return null;
            File(outputPath).writeAsStringSync('gif');
            return outputPath;
          },
      audioExtractor:
          ({
            required String inputPath,
            required int startMs,
            required int endMs,
            required String outputPath,
            int? audioStreamIndex,
            int? audioStreamCount,
            FfmpegFailureReporter? onFailure,
            int audioChannels = 1,
            String audioBitrate = '64k',
            String? tlsPinSha256,
            Map<String, String> httpHeaders = const <String, String>{},
          }) async {
            audio.add(_Call(inputPath, startMs, endMs, httpHeaders));
            if (inputPath == failOn) return null;
            File(outputPath).writeAsStringSync('aac');
            return outputPath;
          },
      frameExtractor:
          ({
            required String inputPath,
            required String outputPath,
            double atSeconds = 10.0,
            FfmpegFailureReporter? onFailure,
            String? tlsPinSha256,
            Map<String, String> httpHeaders = const <String, String>{},
            bool diagnosticOnly = false,
          }) async {
            frameAt.add(atSeconds);
            return null;
          },
    );
    return (gif: gif, audio: audio, frameAt: frameAt, engine: engine);
  }

  File snapshotFile() {
    final File f = File('${tmp.path}/snap.mkv')..writeAsStringSync('mkv');
    return f;
  }

  ImmersionMiningRequest request({
    Future<CachedMediaSnapshot?>? snapshot,
    VideoMiningImageMode imageMode = VideoMiningImageMode.gif,
    Future<MineOutcome> Function({
      required String rawPayloadJson,
      required AnkiMiningContext context,
    })?
    stageNote,
  }) => ImmersionMiningRequest(
    source: AnkiMiningSource.video,
    fields: const <String, String>{'expression': '走る'},
    mediaSource: remote,
    mediaSourceHttpHeaders: const <String, String>{'Referer': 'x'},
    clipStartMs: 61200,
    clipEndMs: 63900,
    stillFrameAtMs: 61500,
    sentence: '走り出した。',
    imageMode: imageMode,
    cachedMediaSnapshot: snapshot,
    stageNote: stageNote,
  );

  test('副本可用：两路抽取都读本地副本，时刻换算到副本自己的时间轴', () async {
    final h = harness();
    final _FakeRepo repo = _FakeRepo();
    final File snap = snapshotFile();
    final ImmersionMiningResult res = await h.engine.mine(
      request(
        snapshot: Future<CachedMediaSnapshot?>.value(
          CachedMediaSnapshot(path: snap.path, zeroMs: 55000),
        ),
      ),
      compression: compression,
      tempDir: tmp.path,
      repo: repo,
    );
    expect(res.aborted, isFalse);
    expect(h.gif.single.input, snap.path);
    expect(h.gif.single.startMs, 6200);
    expect(h.gif.single.endMs, 8900);
    // 副本是本地文件：远端的防盗链头不再跟着走。
    expect(h.gif.single.headers, isEmpty);
    expect(h.audio.single.input, snap.path);
    expect(h.audio.single.startMs, 6200);
    expect(h.audio.single.endMs, 8900);
    // 卡面 {clip-timestamp} 仍是播放器轴原值。
    expect(repo.minedContext!.clipStartMs, 61200);
    expect(repo.minedContext!.clipEndMs, 63900);
    // 副本用完即删。
    expect(snap.existsSync(), isFalse);
  });

  test('字幕起始帧封面也换算到副本时间轴', () async {
    final h = harness();
    final File snap = snapshotFile();
    await h.engine.mine(
      request(
        imageMode: VideoMiningImageMode.subtitleStart,
        snapshot: Future<CachedMediaSnapshot?>.value(
          CachedMediaSnapshot(path: snap.path, zeroMs: 55000),
        ),
      ),
      compression: compression,
      tempDir: tmp.path,
      repo: _FakeRepo(),
    );
    expect(h.frameAt.first, closeTo(6.5, 1e-9));
  });

  test('没有副本（缓冲已被挤掉）照旧远端抽取', () async {
    final h = harness();
    final _FakeRepo repo = _FakeRepo();
    await h.engine.mine(
      request(snapshot: Future<CachedMediaSnapshot?>.value(null)),
      compression: compression,
      tempDir: tmp.path,
      repo: repo,
    );
    expect(h.audio.single.input, remote);
    expect(h.audio.single.startMs, 61200);
    expect(h.audio.single.headers, <String, String>{'Referer': 'x'});
    expect(repo.mineCalls, 1);
  });

  test('落盘抛错当作没有副本', () async {
    final h = harness();
    final _FakeRepo repo = _FakeRepo();
    await h.engine.mine(
      request(snapshot: Future<CachedMediaSnapshot?>.error(StateError('x'))),
      compression: compression,
      tempDir: tmp.path,
      repo: repo,
    );
    expect(h.audio.single.input, remote);
    expect(repo.mineCalls, 1);
  });

  test('副本抽不出音频（中止）→ 用远端源再试一次，只落一张卡', () async {
    final File snap = snapshotFile();
    final h = harness(failOn: snap.path);
    final _FakeRepo repo = _FakeRepo();
    final ImmersionMiningResult res = await h.engine.mine(
      request(
        snapshot: Future<CachedMediaSnapshot?>.value(
          CachedMediaSnapshot(path: snap.path, zeroMs: 55000),
        ),
      ),
      compression: compression,
      tempDir: tmp.path,
      repo: repo,
    );
    expect(res.aborted, isFalse);
    expect(h.audio.map((_Call c) => c.input).toList(), <String>[
      snap.path,
      remote,
    ]);
    expect(h.audio.last.startMs, 61200);
    expect(repo.mineCalls, 1);
    expect(snap.existsSync(), isFalse);
  });

  test('stageNote：媒体照常备好，交给暂存而不是 Anki', () async {
    final h = harness();
    final _FakeRepo repo = _FakeRepo();
    AnkiMiningContext? staged;
    String? stagedPayload;
    final ImmersionMiningResult res = await h.engine.mine(
      request(
        stageNote:
            ({
              required String rawPayloadJson,
              required AnkiMiningContext context,
            }) async {
              staged = context;
              stagedPayload = rawPayloadJson;
              // 暂存必须在返回前拿到真实存在的媒体文件。
              expect(File(context.sentenceAudioPath!).existsSync(), isTrue);
              expect(File(context.coverPath!).existsSync(), isTrue);
              return const MineOutcome.success();
            },
      ),
      compression: compression,
      tempDir: tmp.path,
      repo: repo,
    );
    expect(res.aborted, isFalse);
    expect(repo.mineCalls, 0);
    expect(staged!.sentence, '走り出した。');
    expect(staged!.clipStartMs, 61200);
    expect(stagedPayload, contains('走る'));
  });
}
