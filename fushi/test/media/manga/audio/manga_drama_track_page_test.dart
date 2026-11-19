import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:fushi_engine/tts/manga_audio/manga_drama_track.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_backend.dart'
    show buildMangaClipArgs;
import 'package:fushi/src/media/manga/audio/manga_drama_track_page.dart';
import 'package:fushi/src/media/manga/audio/manga_drama_track_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_drama_track_service.dart';

/// 设计 §9 末段：广播剧 / 动画音轨 → ASR（假转录）→ 按页匹配 → 登记成有声成品。
MokuroBlock _block(String text) => MokuroBlock(
  rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
  isVertical: true,
  fontSize: 24,
  zIndex: 0,
  lines: <String>[text],
);

MokuroPayload _payload() => MokuroPayload(
  images: <MokuroImage>[
    MokuroImage(
      url: 'p0.jpg',
      size: const MokuroSize(100, 100),
      blocks: <MokuroBlock>[_block('昨日の夜に駅前で会った'), _block('え？')],
    ),
    MokuroImage(
      url: 'p1.jpg',
      size: const MokuroSize(100, 100),
      blocks: <MokuroBlock>[_block('雨なんて降っていなかった')],
    ),
  ],
);

MangaDramaVolume _volume({
  MangaDramaUnitSource source = MangaDramaUnitSource.ocr,
}) => MangaDramaVolume(
  bookKey: 'manga-1',
  pageCount: 2,
  units: mangaDramaUnitsFromOcr(_payload()),
  unitSource: source,
  ocrSignature: 'sig',
  language: AsrLanguage.japanese,
);

MangaDramaOutcome _outcome() => MangaDramaOutcome(
  manifest: MangaRenderManifest(
    pageCount: 2,
    lines: const <MangaRenderedLine>[],
    continuous: true,
  ),
  track: MangaDramaTrack(
    segments: const <MangaDramaSegment>[],
    stats: const MangaDramaStats(
      cues: 7,
      matchedCues: 4,
      shortCues: 2,
      backwardCues: 1,
      matchableUnits: 2,
      shortUnits: 1,
      coveredUnits: 1,
      segments: 5,
      highlightedSegments: 3,
    ),
  ),
);

class _FakeBackend implements MangaDramaTrackBackend {
  _FakeBackend({this.volume, this.picks = const <List<String>>[]});

  final MangaDramaVolume? volume;
  final List<List<String>> picks;
  int _pickIndex = 0;
  Exception? failWith;
  List<String>? ranWith;
  Completer<void>? gate;

  @override
  Future<MangaDramaVolume?> loadVolume(String bookKey) async => volume;

  @override
  Future<List<String>> pickAudioFiles(BuildContext context) async =>
      _pickIndex < picks.length ? picks[_pickIndex++] : const <String>[];

  @override
  Future<MangaDramaOutcome> run({
    required MangaDramaVolume volume,
    required List<String> audioPaths,
    required TtsRenderCancelToken cancel,
    MangaDramaProgress? onProgress,
  }) async {
    ranWith = audioPaths;
    onProgress?.call(MangaDramaPhase.transcribing, 1, audioPaths.length);
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    cancel.throwIfCancelled();
    final Exception? fail = failWith;
    if (fail != null) throw fail;
    return _outcome();
  }
}

Widget _wrap(_FakeBackend backend, {MangaDramaTrackTasks? tasks}) =>
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: MangaDramaTrackPanel(
            bookKey: 'manga-1',
            backend: backend,
            tasks: tasks ?? MangaDramaTrackTasks(),
          ),
        ),
      ),
    );

/// 假 ASR：计划里模型就绪与否可控；转录直接写一份 SRT 交回。
class _FakeAsr implements AsrTranscriptionService {
  _FakeAsr({required this.ready, required this.srt, this.pause = false});

  final bool ready;
  final File srt;
  final bool pause;
  final List<List<String>> started = <List<String>>[];
  _FakeRunning? running;

  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async => AsrTranscribePlan(
    language: language,
    variant: AsrEncoderVariant.int8,
    expectedProvider: OnnxExecutionProvider.cpu,
    modelStatus: AsrModelStatus(
      ready: ready,
      diskBytes: 0,
      totalBytes: 0,
      obtainedBytes: 0,
    ),
  );

  @override
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
    List<AsrSegmentSpan>? segments,
  }) async {
    started.add(audioPaths);
    return running = _FakeRunning(srt: srt, pause: pause);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRunning implements AsrRunningTranscription {
  _FakeRunning({required this.srt, required this.pause});

  final File srt;
  final bool pause;
  bool pauseRequested = false;
  bool disposed = false;

  static const AsrTranscribeProgress _progress = AsrTranscribeProgress(
    fileIndex: 0,
    filesTotal: 1,
    processedMs: 0,
    totalMs: 0,
    speechMs: 0,
    segmentsDone: 0,
    elapsed: Duration.zero,
  );

  @override
  Stream<AsrTranscribeEvent> run() async* {
    if (pause) {
      yield const AsrTranscribePausedEvent(_progress);
      return;
    }
    yield AsrTranscribeFinishedEvent(
      AsrTranscribeResult(
        srtPath: srt.path,
        segmentsPath: '',
        cueCount: 2,
        segmentCount: 2,
        totalMs: 5000,
        fileDurationsMs: const <int>[5000],
      ),
    );
  }

  @override
  void requestPause({bool discardPending = false}) => pauseRequested = true;

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('chooseMangaDramaUnits', () {
    test('演出稿与当前 OCR 一致且有会发声的行 → 用演出稿', () {
      final MokuroPayload payload = _payload();
      final MangaAudioScript script = MangaAudioScript(
        engineSignature: mangaPayloadOcrSignature(payload),
        lines: <MangaScriptLine>[
          MangaScriptLine(
            page: 1,
            blocks: const <int>[0],
            speaker: 'A',
            kind: CastLineKind.spoken,
          ),
        ],
      );
      final ({List<MangaDramaUnit> units, MangaDramaUnitSource source}) got =
          chooseMangaDramaUnits(script, payload);
      expect(got.source, MangaDramaUnitSource.script);
      expect(got.units.single.page, 1);
      expect(got.units.single.text, '雨なんて降っていなかった');
    });

    test('演出稿过期（OCR 改过）或没有行 → 每个 OCR 块一个单元', () {
      final MokuroPayload payload = _payload();
      final MangaAudioScript stale = MangaAudioScript(
        engineSignature: 'old',
        lines: <MangaScriptLine>[
          MangaScriptLine(
            page: 0,
            blocks: const <int>[0],
            speaker: 'A',
            kind: CastLineKind.spoken,
          ),
        ],
      );
      for (final MangaAudioScript s in <MangaAudioScript>[
        stale,
        MangaAudioScript(),
      ]) {
        final ({List<MangaDramaUnit> units, MangaDramaUnitSource source}) got =
            chooseMangaDramaUnits(s, payload);
        expect(got.source, MangaDramaUnitSource.ocr);
        expect(got.units.length, 3);
      }
    });
  });

  test('buildMangaClipArgs：endMs 为 null 时剪到文件末尾（不带 -t），视频只取音轨', () {
    final List<String> args = buildMangaClipArgs(
      sourcePath: 'ep1.mkv',
      startMs: 61000,
      endMs: null,
      outputPath: 'o.m4a',
    );
    expect(args, isNot(contains('-t')));
    expect(args.sublist(0, 5), <String>[
      '-y',
      '-ss',
      '61.000',
      '-i',
      'ep1.mkv',
    ]);
    expect(args, contains('-vn'));
  });

  group('appMangaDramaTranscriber（假 ASR）', () {
    late Directory dir;
    late File srt;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('manga_drama_asr_');
      srt = File('${dir.path}/out.srt');
      await srt.writeAsString(
        '1\n00:00:01,000 --> 00:00:02,500\n昨日の夜に駅前で会った\n\n'
        '2\n00:00:03,000 --> 00:00:04,000\n雨なんて降っていなかった\n\n',
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('转录结果的 SRT → 带文件下标的 cue', () async {
      final _FakeAsr asr = _FakeAsr(ready: true, srt: srt);
      final MangaDramaTranscriber transcribe = appMangaDramaTranscriber(
        language: AsrLanguage.japanese,
        createService: () => asr,
      );
      final List<MangaDramaCue> cues = await transcribe(
        'track2.flac',
        1,
        TtsRenderCancelToken(),
      );
      expect(asr.started.single, <String>['track2.flac']);
      expect(asr.running!.disposed, isTrue);
      expect(cues.length, 2);
      expect(cues.first.fileIndex, 1);
      expect(cues.first.startMs, 1000);
      expect(cues.first.endMs, 2500);
      expect(cues.last.text, '雨なんて降っていなかった');
    });

    test('模型没就绪 → MangaDramaAsrUnavailable，不启动识别', () async {
      final _FakeAsr asr = _FakeAsr(ready: false, srt: srt);
      final MangaDramaTranscriber transcribe = appMangaDramaTranscriber(
        language: AsrLanguage.japanese,
        createService: () => asr,
      );
      await expectLater(
        transcribe('a.mp3', 0, TtsRenderCancelToken()),
        throwsA(isA<MangaDramaAsrUnavailable>()),
      );
      expect(asr.started, isEmpty);
    });

    test('识别暂停（取消）→ TtsRenderCancelled，并释放识别会话', () async {
      final _FakeAsr asr = _FakeAsr(ready: true, srt: srt, pause: true);
      final MangaDramaTranscriber transcribe = appMangaDramaTranscriber(
        language: AsrLanguage.japanese,
        createService: () => asr,
      );
      final TtsRenderCancelToken cancel = TtsRenderCancelToken();
      await expectLater(
        transcribe('a.mp3', 0, cancel),
        throwsA(isA<TtsRenderCancelled>()),
      );
      expect(asr.running!.disposed, isTrue);
    });
  });

  test('mangaDramaErrorMessage：取消不算失败，其余映射到对应提示', () {
    expect(mangaDramaErrorMessage(const TtsRenderCancelled()), isNull);
    expect(
      mangaDramaErrorMessage(const MangaDramaAsrUnavailable()),
      t.manga_audio_drama_error_asr,
    );
    expect(
      mangaDramaErrorMessage(const MangaDramaFfmpegMissing()),
      t.manga_audio_drama_error_ffmpeg,
    );
    expect(
      mangaDramaErrorMessage(const MangaDramaEmptyTranscript()),
      t.manga_audio_drama_error_empty,
    );
    expect(
      mangaDramaErrorMessage(StateError('boom')),
      t.manga_audio_drama_error_failed(error: 'Bad state: boom'),
    );
  });

  group('MangaDramaTrackPanel', () {
    testWidgets('没有可用 OCR 时只提示先识别', (WidgetTester tester) async {
      await tester.pumpWidget(_wrap(_FakeBackend()));
      await tester.pumpAndSettle();
      expect(find.text(t.manga_audio_error_no_ocr), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_drama_start')),
        findsNothing,
      );
    });

    testWidgets('加文件、调顺序、发起 → 进度 → 匹配统计', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(
        volume: _volume(),
        picks: <List<String>>[
          <String>['/a/disc1.flac'],
          <String>['/a/disc2.flac', '/a/disc1.flac'],
        ],
      );
      await tester.pumpWidget(_wrap(backend));
      await tester.pumpAndSettle();
      expect(
        find.text(t.manga_audio_drama_units_ocr(count: 3)),
        findsOneWidget,
      );
      expect(find.text(t.manga_audio_drama_files_empty), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_add')));
      await tester.pumpAndSettle();
      // 重复选的文件不再加一遍。
      expect(find.text('disc1.flac'), findsOneWidget);
      expect(find.text('disc2.flac'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_up_1')));
      await tester.pumpAndSettle();

      backend.gate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_start')));
      await tester.pump();
      expect(
        find.text(mangaDramaPhaseLabel(MangaDramaPhase.transcribing, 1, 2)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('manga_drama_cancel')),
        findsOneWidget,
      );
      backend.gate!.complete();
      await tester.pumpAndSettle();

      expect(backend.ranWith, <String>['/a/disc2.flac', '/a/disc1.flac']);
      expect(
        find.byKey(const ValueKey<String>('manga_drama_result')),
        findsOneWidget,
      );
      expect(find.text('50%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_drama_stat_backward')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('manga_drama_cancel')),
        findsNothing,
      );
    });

    testWidgets('ASR 不可用 → 显示原因，不显示统计', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(
        volume: _volume(),
        picks: <List<String>>[
          <String>['/a/ep1.mkv'],
        ],
      )..failWith = const MangaDramaAsrUnavailable();
      await tester.pumpWidget(_wrap(backend));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_start')));
      await tester.pumpAndSettle();
      expect(find.text(t.manga_audio_drama_error_asr), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_drama_result')),
        findsNothing,
      );
    });

    testWidgets('取消 → 不报错、按钮复原', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(
        volume: _volume(),
        picks: <List<String>>[
          <String>['/a/ep1.mkv'],
        ],
      );
      await tester.pumpWidget(_wrap(backend));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_add')));
      await tester.pumpAndSettle();
      backend.gate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_start')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_drama_cancel')),
      );
      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('manga_drama_error')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('manga_drama_result')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('manga_drama_cancel')),
        findsNothing,
      );
    });

    testWidgets('离开页面任务照跑；回来挂上进度，结束后显示结果并全局通知', (WidgetTester tester) async {
      final List<MangaDramaTask> settled = <MangaDramaTask>[];
      final MangaDramaTrackTasks tasks = MangaDramaTrackTasks(
        onSettled: settled.add,
      );
      final _FakeBackend backend = _FakeBackend(
        volume: _volume(),
        picks: <List<String>>[
          <String>['/a/ep1.mkv'],
        ],
      );
      await tester.pumpWidget(_wrap(backend, tasks: tasks));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_add')));
      await tester.pumpAndSettle();
      backend.gate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey<String>('manga_drama_start')));
      await tester.pump();

      // 离开页面：只摘监听，任务不取消。
      await tester.pumpWidget(const SizedBox.shrink());
      final MangaDramaTask task = tasks.runningFor('manga-1')!;
      expect(task.cancelRequested, isFalse);

      // 回到页面：挂上运行中的任务，文件与进度都在。
      await tester.pumpWidget(_wrap(backend, tasks: tasks));
      await tester.pump();
      expect(find.text('ep1.mkv'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_drama_cancel')),
        findsOneWidget,
      );

      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(task.status, MangaDramaTaskStatus.completed);
      expect(settled, <MangaDramaTask>[task]);
      expect(
        find.byKey(const ValueKey<String>('manga_drama_result')),
        findsOneWidget,
      );
    });
  });

  group('MangaDramaTrackTasks', () {
    test('同卷重复发起被拒；显式取消生效且结局是 cancelled', () async {
      final MangaDramaTrackTasks tasks = MangaDramaTrackTasks();
      final _FakeBackend backend = _FakeBackend(volume: _volume())
        ..gate = Completer<void>();
      final MangaDramaTask task = tasks.start(
        volume: _volume(),
        audioPaths: const <String>['/a/ep1.mkv'],
        run: backend.run,
      );
      expect(
        () => tasks.start(
          volume: _volume(),
          audioPaths: const <String>['/a/ep2.mkv'],
          run: backend.run,
        ),
        throwsA(isA<MangaDramaTaskBusy>()),
      );
      expect(tasks.cancel('manga-1'), isTrue);
      expect(tasks.cancel('manga-1'), isFalse);
      backend.gate!.complete();
      await task.finished;
      expect(task.status, MangaDramaTaskStatus.cancelled);
      expect(task.error, isNull);
      expect(tasks.isRunning('manga-1'), isFalse);
    });
  });
}
