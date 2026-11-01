import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/mining/sentence_audio_source.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, FfmpegFailureReporter;

class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 42);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 引擎里的中置声道取音（反馈 pNF2ZL7Kfc）：走中置抽取器、需要时先探测布局、取不到
/// 就回退整条音轨并通知调用方（不静默）。
void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('front_center_engine');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
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

  /// 记下每次调用的 (哪个抽取器, audioStreamIndex, audioChannels)。
  final List<(String, int?, int)> calls = <(String, int?, int)>[];
  final List<int> probes = <int>[];
  final List<SentenceAudioFallbackReason> fallbacks =
      <SentenceAudioFallbackReason>[];
  setUp(() {
    calls.clear();
    probes.clear();
    fallbacks.clear();
  });

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
      }) async {
        calls.add((name, audioStreamIndex, audioChannels));
        return ok ? outputPath : null;
      };

  AudioChannelLayoutProbe probeFake(String? layout, int? channels) =>
      ({
        required String inputPath,
        required int audioStreamIndex,
        String? tlsPinSha256,
        Map<String, String> httpHeaders = const {},
      }) async {
        probes.add(audioStreamIndex);
        return (layout: layout, channels: channels);
      };

  Future<ImmersionMiningResult> mine({
    required bool frontCenter,
    bool needsProbe = false,
    bool centerOk = true,
    String? probedLayout,
    int? probedChannels,
    _FakeRepo? repo,
  }) =>
      ImmersionMiningEngine(
        gifExtractor: okGif,
        frameExtractor: okFrame,
        audioExtractor: audioFake('whole'),
        frontCenterAudioExtractor: audioFake('center', ok: centerOk),
        channelLayoutProbe: probeFake(probedLayout, probedChannels),
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.video,
          fields: const <String, String>{'expression': '走る'},
          mediaSource: '/fake/video.mkv',
          clipStartMs: 1000,
          clipEndMs: 3000,
          sentence: '走り出した。',
          audioStreamIndex: 1,
          audioStreamCount: 2,
          audioFrontCenter: frontCenter,
          audioFrontCenterNeedsProbe: needsProbe,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo ?? _FakeRepo(),
        onAudioSourceFallback: fallbacks.add,
      );

  test('默认（不取中置）：只走整条音轨抽取器，不探测、不通知', () async {
    final ImmersionMiningResult res = await mine(frontCenter: false);
    expect(res.aborted, isFalse);
    expect(calls, <(String, int?, int)>[('whole', 1, 1)]);
    expect(probes, isEmpty);
    expect(fallbacks, isEmpty);
  });

  test('布局已知含 FC：走中置抽取器，单声道，不探测', () async {
    final _FakeRepo repo = _FakeRepo();
    final ImmersionMiningResult res = await mine(frontCenter: true, repo: repo);
    expect(res.aborted, isFalse);
    expect(calls, <(String, int?, int)>[('center', 1, 1)]);
    expect(probes, isEmpty);
    expect(fallbacks, isEmpty);
    expect(repo.minedContext!.sentenceAudioPath, isNotNull);
  });

  test('布局未知 → 探测同一条轨；探到 5.1 就取中置', () async {
    final ImmersionMiningResult res = await mine(
      frontCenter: true,
      needsProbe: true,
      probedLayout: '5.1',
      probedChannels: 6,
    );
    expect(res.aborted, isFalse);
    expect(probes, <int>[1]);
    expect(calls, <(String, int?, int)>[('center', 1, 1)]);
    expect(fallbacks, isEmpty);
  });

  test('探到立体声 → 回退整条音轨 + noFrontCenter', () async {
    final ImmersionMiningResult res = await mine(
      frontCenter: true,
      needsProbe: true,
      probedLayout: 'stereo',
      probedChannels: 2,
    );
    expect(res.aborted, isFalse);
    expect(calls, <(String, int?, int)>[('whole', 1, 1)]);
    expect(fallbacks, <SentenceAudioFallbackReason>[
      SentenceAudioFallbackReason.noFrontCenter,
    ]);
  });

  test('探测拿不到布局 → 回退整条音轨 + frontCenterUnknown', () async {
    final ImmersionMiningResult res = await mine(
      frontCenter: true,
      needsProbe: true,
    );
    expect(res.aborted, isFalse);
    expect(calls, <(String, int?, int)>[('whole', 1, 1)]);
    expect(fallbacks, <SentenceAudioFallbackReason>[
      SentenceAudioFallbackReason.frontCenterUnknown,
    ]);
  });

  test('中置抽取失败 → 改抽整条音轨 + frontCenterFailed', () async {
    final ImmersionMiningResult res = await mine(
      frontCenter: true,
      centerOk: false,
    );
    expect(res.aborted, isFalse);
    expect(calls, <(String, int?, int)>[('center', 1, 1), ('whole', 1, 1)]);
    expect(fallbacks, <SentenceAudioFallbackReason>[
      SentenceAudioFallbackReason.frontCenterFailed,
    ]);
  });
}
