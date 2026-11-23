import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, FfmpegFailureReporter;

class _Repo implements BaseAnkiRepository {
  AnkiMiningContext? context;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    this.context = context;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  Future<bool?> rendersSynchronizedClip() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 一次句子音频抽取调用的要点。
typedef _AudioCall = ({
  String extractor,
  String inputPath,
  int startMs,
  int endMs,
  String outputPath,
  double? gainDb,
});

/// 视频制卡句子音频跟随播放音量（拍板 d7mXlstcv9-video）：请求里的
/// [ImmersionMiningRequest.audioGainDb] 要落到引擎自己裁出的每一条句子音频上——本地 /
/// 远端 ffmpeg 抽取、中置声道、互联 host 端裁回来的片段；需要增益时不走「原音轨直接
/// 搬进片段」的快路。null = 原始电平（现状）。
void main() {
  late Directory temp;
  late _Repo repo;
  final List<_AudioCall> calls = <_AudioCall>[];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mining_audio_gain_test_');
    repo = _Repo();
    calls.clear();
  });
  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<String?> okGif({
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
    Map<String, String> httpHeaders = const {},
  }) async => outputPath;

  Future<String?> okFrame({
    required String inputPath,
    required String outputPath,
    double atSeconds = 10.0,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
    Map<String, String> httpHeaders = const {},
    bool diagnosticOnly = false,
  }) async => outputPath;

  AudioExtractor audioFake(String name, {bool ok = true}) =>
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
        Map<String, String> httpHeaders = const {},
        double? gainDb,
      }) async {
        calls.add((
          extractor: name,
          inputPath: inputPath,
          startMs: startMs,
          endMs: endMs,
          outputPath: outputPath,
          gainDb: gainDb,
        ));
        if (!ok) return null;
        await File(outputPath).writeAsBytes(<int>[1, 2, 3]);
        return outputPath;
      };

  ImmersionMiningEngine engine({bool audioOk = true}) => ImmersionMiningEngine(
    gifExtractor: okGif,
    frameExtractor: okFrame,
    audioExtractor: audioFake('whole', ok: audioOk),
    frontCenterAudioExtractor: audioFake('center'),
  );

  Future<ImmersionMiningResult> mine(
    ImmersionMiningEngine e,
    ImmersionMiningRequest req,
  ) => e.mine(
    req,
    compression: MiningMediaCompression.compressed,
    tempDir: temp.path,
    repo: repo,
  );

  ImmersionMiningRequest localRequest({
    double? gainDb,
    bool frontCenter = false,
  }) => ImmersionMiningRequest(
    fields: const <String, String>{'expression': '走る'},
    source: AnkiMiningSource.video,
    mediaSource: '/fake/video.mkv',
    clipStartMs: 1000,
    clipEndMs: 3000,
    sentence: '走り出した。',
    audioStreamIndex: 1,
    audioStreamCount: 2,
    audioFrontCenter: frontCenter,
    audioGainDb: gainDb,
  );

  test('本地 / 远端 ffmpeg 抽取：请求的增益原样交给抽取器', () async {
    final ImmersionMiningResult res = await mine(
      engine(),
      localRequest(gainDb: -18.06),
    );
    expect(res.aborted, isFalse);
    expect(calls.single.extractor, 'whole');
    expect(calls.single.gainDb, -18.06);
  });

  test('开关关（audioGainDb null）：抽取器收到 null，原始电平', () async {
    await mine(engine(), localRequest());
    expect(calls.single.gainDb, isNull);
  });

  test('中置声道抽取同样带增益', () async {
    await mine(engine(), localRequest(gainDb: -6.0, frontCenter: true));
    expect(calls.single.extractor, 'center');
    expect(calls.single.gainDb, -6.0);
  });

  test('入队冻结（frozen）与缓冲副本请求（withCachedSnapshot）保留增益', () {
    final ImmersionMiningRequest req = localRequest(gainDb: -9.5);
    expect(req.frozen().audioGainDb, -9.5);
    expect(
      req
          .withCachedSnapshot(
            const CachedMediaSnapshot(path: '/tmp/snap.mkv', zeroMs: 0),
          )
          .audioGainDb,
      -9.5,
    );
  });

  ImmersionMiningRequest hostRequest({double? gainDb}) =>
      ImmersionMiningRequest(
        fields: const <String, String>{'expression': '走る'},
        source: AnkiMiningSource.video,
        mediaSource:
            'https://host.example:38765/api/library/videos/v/stream?token=x',
        clipStartMs: 1000,
        clipEndMs: 3000,
        sentence: '走り出した。',
        audioGainDb: gainDb,
        remoteAudioClipper:
            ({
              required int startMs,
              required int endMs,
              required String outputPath,
            }) async {
              await File(outputPath).writeAsBytes(<int>[7, 7, 7]);
              return outputPath;
            },
      );

  test('互联 host 端裁回来的片段：本机对成品补一遍增益（从 0 起、整段时长）', () async {
    final ImmersionMiningResult res = await mine(
      engine(),
      hostRequest(gainDb: -12.0),
    );
    expect(res.aborted, isFalse);
    final _AudioCall call = calls.single;
    expect(call.inputPath, endsWith('immersion_audio_host.aac'));
    expect(call.startMs, 0);
    expect(call.endMs, 2000);
    expect(call.gainDb, -12.0);
    expect(
      repo.context!.sentenceAudioPath,
      endsWith('immersion_audio_gain.${immersionMiningAudioExtension()}'),
    );
  });

  test('互联 host 端裁 + 无需增益：不再跑抽取器，直接用 host 片段（现状）', () async {
    await mine(engine(), hostRequest());
    expect(calls, isEmpty);
    expect(
      repo.context!.sentenceAudioPath,
      endsWith('immersion_audio_host.aac'),
    );
  });

  test('互联 host 片段补增益失败：不丢卡，用 host 原片段落卡', () async {
    final ImmersionMiningResult res = await mine(
      engine(audioOk: false),
      hostRequest(gainDb: -12.0),
    );
    expect(res.aborted, isFalse);
    expect(calls, hasLength(1));
    expect(
      repo.context!.sentenceAudioPath,
      endsWith('immersion_audio_host.aac'),
    );
  });

  for (final ({double? gainDb, bool direct}) c
      in <({double? gainDb, bool direct})>[
        (gainDb: null, direct: true),
        (gainDb: 0.0, direct: true),
        (gainDb: -18.06, direct: false),
      ]) {
    test('音画同步片段：需要增益时不把原音轨直接搬进片段（$c）', () async {
      final String source = '${temp.path}/source.mkv';
      String? exportedAudio;
      final ImmersionMiningResult res =
          await ImmersionMiningEngine(
            audioExtractor: audioFake('whole'),
            synchronizedVideoExtractor:
                ({
                  required String videoPath,
                  required String audioPath,
                  int audioStartMs = 0,
                  int audioStreamIndex = 0,
                  int audioChannels = 2,
                  required int startMs,
                  required int endMs,
                  required String outputPath,
                  required String? tlsPinSha256,
                  required Map<String, String> httpHeaders,
                  required MiningClipFormat format,
                }) async {
                  exportedAudio = audioPath;
                  await File(outputPath).writeAsBytes(<int>[9]);
                  return VideoClipExportResult.success(outputPath);
                },
          ).mine(
            ImmersionMiningRequest(
              fields: const <String, String>{},
              source: AnkiMiningSource.video,
              mediaSource: source,
              clipStartMs: 850,
              clipEndMs: 3250,
              sentence: 'テスト',
              audioStreamIndex: 1,
              audioStreamCount: 2,
              imageMode: VideoMiningImageMode.videoClip,
              audioGainDb: c.gainDb,
            ),
            compression: MiningMediaCompression.compressed,
            tempDir: temp.path,
            repo: repo,
          );
      expect(res.aborted, isFalse);
      expect(exportedAudio == source, c.direct);
      if (c.direct) {
        expect(calls, isEmpty);
      } else {
        expect(calls.single.gainDb, c.gainDb);
        expect(exportedAudio, calls.single.outputPath);
      }
    });
  }
}
