import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _RecordingRepo implements BaseAnkiRepository {
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];
  final List<String?> coverPaths = <String?>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    coverPaths.add(context.coverPath);
    payloads.add(
      Map<String, dynamic>.from(
        jsonDecode(rawPayloadJson) as Map<String, dynamic>,
      ),
    );
    return MineOutcome.success(noteId: payloads.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('视频制卡历史快照冻结字段、标题与集定位，不读取换集后状态', () {
    final Map<String, String> fields = <String, String>{
      'expression': 'old expression',
      'reading': 'old reading',
      'glossary': 'old glossary',
    };
    final VideoMiningHistorySnapshot snapshot =
        VideoMiningHistorySnapshot.capture(
          fields: fields,
          sentence: 'old sentence',
          documentTitle: 'Old episode',
          bookKey: 'old-book',
          sectionIndex: 1,
          cueStartMs: 1200,
          cueEndMs: 2450,
          dateKey: '2026-07-29',
        );

    // 模拟任务排队期间 popup fields 与远端当前集都已切到下一集。
    fields
      ..['expression'] = 'new expression'
      ..['reading'] = 'new reading'
      ..['glossary'] = 'new glossary';

    expect(snapshot.expression, 'old expression');
    expect(snapshot.reading, 'old reading');
    expect(snapshot.glossary, 'old glossary');
    expect(snapshot.sentence, 'old sentence');
    expect(snapshot.documentTitle, 'Old episode');
    expect(snapshot.bookKey, 'old-book');
    expect(snapshot.sectionIndex, 1);
    expect(snapshot.positionMs, 1200);
    expect(snapshot.durationMs, 1250);
    expect(snapshot.dateKey, '2026-07-29');
  });

  group('video-30：抽取有界并发、落卡按点击顺序', () {
    late Directory tmp;
    late _GatedExtractors media;
    late _RecordingRepo repo;
    late ImmersionMiningEngine engine;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('immersion_mining_queue');
      media = _GatedExtractors();
      repo = _RecordingRepo();
      engine = ImmersionMiningEngine(
        gifExtractor: media.gif,
        audioExtractor: media.audio,
      );
    });

    tearDown(() async {
      // 任何一条失败都不能把门留着：共享的进程级队列会被下一条测试继承。
      media.releaseAll();
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<ImmersionMiningResult> mineEpisode(
      String source,
      Map<String, String> fields, {
      FutureOr<String>? tempDir,
    }) => engine.mine(
      ImmersionMiningRequest(
        fields: fields,
        clipStartMs: 1000,
        clipEndMs: 2000,
        sentence: source,
        mediaSource: source,
        source: AnkiMiningSource.video,
      ),
      compression: MiningMediaCompression.highFidelity,
      tempDir: tempDir ?? tmp.path,
      repo: repo,
    );

    test('一张卡抽取卡住（远端断流）时下一张照常抽取，落卡仍按点击顺序', () async {
      media.gate('/episode-1.mp4');
      final Completer<String> firstTempDir = Completer<String>();
      final Map<String, String> firstFields = <String, String>{
        'expression': 'episode one',
      };

      final Future<ImmersionMiningResult> first = mineEpisode(
        '/episode-1.mp4',
        firstFields,
        tempDir: firstTempDir.future,
      );
      final Future<ImmersionMiningResult> second = mineEpisode(
        '/episode-2.mp4',
        <String, String>{'expression': 'episode two'},
      );
      // 弹窗字段与当前集在入队之后才变：卡上必须是入队那一刻的内容。
      firstFields['expression'] = 'mutated after enqueue';

      // 第一张连临时目录都还没解析出来，第二张也不必等它。
      await media.started('/episode-2.mp4');
      firstTempDir.complete(tmp.path);
      await media.started('/episode-1.mp4');
      await pumpEventQueue();
      expect(repo.payloads, isEmpty, reason: '第二张抽完了也不能越过还在抽的第一张先落卡');

      media.release('/episode-1.mp4');
      final List<ImmersionMiningResult> results =
          await Future.wait<ImmersionMiningResult>(
            <Future<ImmersionMiningResult>>[first, second],
          );
      expect(results.map((ImmersionMiningResult r) => r.aborted), <bool>[
        false,
        false,
      ]);
      expect(
        repo.payloads.map((Map<String, dynamic> p) => p['expression']),
        <String>['episode one', 'episode two'],
        reason: '按点击顺序落卡，字段用入队时的冻结值',
      );
    });

    test('每张卡抽在自己的私有目录里，落卡后目录随即清掉', () async {
      media.gate('/episode-1.mp4');
      final Future<ImmersionMiningResult> first = mineEpisode(
        '/episode-1.mp4',
        <String, String>{'expression': 'one'},
      );
      final Future<ImmersionMiningResult> second = mineEpisode(
        '/episode-2.mp4',
        <String, String>{'expression': 'two'},
      );
      await media.started('/episode-1.mp4');
      await media.started('/episode-2.mp4');

      final String dirOne = File(media.outputs['/episode-1.mp4']!).parent.path;
      final String dirTwo = File(media.outputs['/episode-2.mp4']!).parent.path;
      expect(dirOne, isNot(dirTwo), reason: '同时在抽的两张卡不得写同一个临时文件');
      expect(File(dirOne).parent.path, tmp.path);
      expect(File(dirTwo).parent.path, tmp.path);

      media.release('/episode-1.mp4');
      await Future.wait<ImmersionMiningResult>(<Future<ImmersionMiningResult>>[
        first,
        second,
      ]);
      expect(repo.coverPaths, <String>[
        media.outputs['/episode-1.mp4']!,
        media.outputs['/episode-2.mp4']!,
      ], reason: '落卡时拿到的是各自目录里的文件');
      expect(tmp.listSync(), isEmpty, reason: '落卡后私有目录必须收掉，不在临时目录里越积越多');
    });

    test('同时抽取的卡数有上限，前一张抽完下一张才接上', () async {
      // 名额按设备现算（桌面 12 核及以上 3 路、其余 2 路，见
      // resolveImmersionExtractionConcurrency）：用同一口径算出本机名额，排「名额 + 1」张，
      // 不把某一档硬写进测试——否则换台核多的机器就变红。
      final int limit = resolveImmersionExtractionConcurrency(
        isMobile: Platform.isAndroid || Platform.isIOS,
        lowMemoryMode: ImmersionMiningEngine.lowMemoryModeReader(),
        processors: Platform.numberOfProcessors,
      );
      expect(limit, greaterThanOrEqualTo(1));
      final List<String> sources = <String>[
        for (int i = 0; i <= limit; i++) '/clip-$i.mp4',
      ];
      final String waiting = sources.last;
      final List<String> admitted = sources.sublist(0, limit);
      for (final String s in sources) {
        media.gate(s);
      }
      final List<Future<ImmersionMiningResult>> jobs =
          <Future<ImmersionMiningResult>>[
            for (final String s in sources)
              mineEpisode(s, <String, String>{'expression': s}),
          ];
      for (final String s in admitted) {
        await media.started(s);
      }
      await pumpEventQueue();
      // 名额按点击顺序发放，但拿到名额后先建私有任务目录（真实磁盘 I/O）才起抽取，
      // 已放行的几张谁先起 ffmpeg 取决于建目录的快慢，不按点击顺序；落卡顺序另由共享
      // 队列保证（见本用例末尾）。这里只钉「放行的恰好是前 limit 张、第 limit+1 张在等」。
      expect(
        media.startedSources,
        unorderedEquals(admitted),
        reason: '第 ${limit + 1} 张要等名额，不能十张卡起十路 ffmpeg',
      );

      // 放掉最后一个占名额的（不是第一个），排队那张才接上：名额是「谁抽完谁让位」。
      media.release(admitted.last);
      await media.started(waiting);
      media.releaseAll();
      await Future.wait<ImmersionMiningResult>(jobs);
      expect(
        repo.payloads.map((Map<String, dynamic> p) => p['expression']),
        sources,
      );
    });

    test('前一张抽取抛错：原样抛给它的调用方，后一张照常在其后落卡', () async {
      media
        ..gate('/broken.mp4')
        ..failAudio('/broken.mp4');
      final Future<ImmersionMiningResult> broken = mineEpisode(
        '/broken.mp4',
        <String, String>{'expression': 'broken'},
      );
      final Future<ImmersionMiningResult> next = mineEpisode(
        '/next.mp4',
        <String, String>{'expression': 'next'},
      );
      await media.started('/next.mp4');
      expect(repo.payloads, isEmpty);

      media.release('/broken.mp4');
      await expectLater(broken, throwsA(isA<StateError>()));
      final ImmersionMiningResult ok = await next;
      expect(ok.aborted, isFalse);
      expect(
        repo.payloads.map((Map<String, dynamic> p) => p['expression']),
        <String>['next'],
      );
      expect(tmp.listSync(), isEmpty, reason: '抽取失败的那张也要把私有目录收掉');
    });
  });
}

/// 按源路径可单独卡住的假抽取器：GIF 抽取在门打开前不返回（模拟远端流断流等超时）。
class _GatedExtractors {
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};
  final Map<String, Completer<void>> _started = <String, Completer<void>>{};
  final Set<String> _failingAudio = <String>{};
  final List<String> startedSources = <String>[];
  final Map<String, String> outputs = <String, String>{};

  void gate(String source) => _gates[source] = Completer<void>();

  void release(String source) {
    final Completer<void>? gate = _gates[source];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void releaseAll() => _gates.keys.toList().forEach(release);

  void failAudio(String source) => _failingAudio.add(source);

  Future<void> started(String source) =>
      _startedOf(source).future.timeout(const Duration(seconds: 5));

  Completer<void> _startedOf(String source) =>
      _started.putIfAbsent(source, () => Completer<void>());

  Future<String?> gif({
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
  }) async {
    startedSources.add(inputPath);
    outputs[inputPath] = outputPath;
    _startedOf(inputPath).complete();
    await _gates[inputPath]?.future;
    return outputPath;
  }

  Future<String?> audio({
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
    if (_failingAudio.contains(inputPath)) {
      throw StateError('audio extractor crashed');
    }
    return outputPath;
  }
}
