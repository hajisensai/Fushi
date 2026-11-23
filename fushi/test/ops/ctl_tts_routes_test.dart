import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show Audiobook, AudiobookRepository;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart'
    show
        MangaRenderItem,
        mangaCandidateFileName,
        mangaLocalAudioSourcePath,
        mangaStagedFileName;
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show registerMangaAudio;
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_tts_routes.dart';
import 'package:fushi/src/ops/ctl_tts_support.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_tts.dart';

import '../helpers/test_platform_services.dart';

/// 只覆盖漫画有声路由用到的 AppModel 面：库、数据目录、模块门、只读态。
class _TtsTestModel extends AppModel {
  _TtsTestModel(this._db, this._dir) : super(testPlatformServices());

  final FushiDatabase _db;
  final Directory _dir;
  final Set<ModuleId> disabled = <ModuleId>{};

  @override
  FushiDatabase get database => _db;

  @override
  Directory get databaseDirectory => _dir;

  @override
  bool get isMigrationReadonly => false;

  @override
  bool moduleEnabled(ModuleId module) => !disabled.contains(module);
}

class _Ref implements WidgetRef {
  _Ref(this.model);
  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

/// 一直跑到被取消的制作端口（生成任务停在 running）。
class _HangingRunner implements TtsRenderRunner {
  int runs = 0;

  @override
  Future<({bool verified, List<TtsRenderFlag> flags})> run(
    TtsRenderJob job, {
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) {
    runs++;
    final Completer<({bool verified, List<TtsRenderFlag> flags})> done =
        Completer<({bool verified, List<TtsRenderFlag> flags})>();
    cancel.onCancel(() {
      if (!done.isCompleted) done.completeError(const TtsRenderCancelled());
    });
    return done.future;
  }
}

/// 假标注：等测试放行后往第 3 页写一句（像真运行体一样随时落盘），查取消。
class _FakeAnnotator {
  _FakeAnnotator(this.model);

  final AppModel model;
  final Completer<void> gate = Completer<void>();
  int calls = 0;

  Future<MangaAnnotateRunSummary> call(
    MangaAnnotateRequest request,
    MangaAnnotateTaskSink sink,
    bool Function() isCancelled,
  ) async {
    calls++;
    final MangaAudioScriptStore store = mangaAudioScriptStoreFor(model);
    final MangaAudioScript script = await store.load(request.bookKey);
    script.lines.add(
      MangaScriptLine(
        page: 2,
        blocks: const <int>[0],
        speaker: '花子',
        kind: CastLineKind.spoken,
      ),
    );
    script.annotatedPages.add(2);
    await store.save(request.bookKey, script);
    sink.progress(MangaAnnotatePhase.pages, 1, 1);
    await gate.future;
    if (isCancelled()) throw const MangaAnnotateAbort('cancelled');
    return const MangaAnnotateRunSummary(
      annotatedPages: <int>[2],
      failedPages: <int>[],
      rejectedLines: 0,
      reviewedLines: 0,
    );
  }
}

/// 只会整形本地音频的假后端：输出 = `shaped:<源文件内容>`，时长 = 1500；源文件内容是
/// `bad` 时整形失败。
class _FakeLocalBackend implements MangaRenderBackend {
  @override
  int get parallelism => 1;

  @override
  String get shapeVersion => 'test-shape';

  @override
  Future<int> shapeLocalAudio({
    required String sourcePath,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    final String content = await File(sourcePath).readAsString();
    if (content == 'bad') throw const MangaLineFailure('encode_failed');
    await File(outputPath).writeAsString('shaped:$content');
    return 1500;
  }

  @override
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required CastLineDirection direction,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => throw UnsupportedError('local only');

  @override
  Future<String?> directionKey({
    required String voice,
    required CastLineDirection direction,
  }) async => null;

  @override
  Future<int> cutClip({
    required MangaAudiobookClip clip,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => throw UnsupportedError('local only');

  @override
  Future<int> writeSilence({required int ms, required String outputPath}) =>
      throw UnsupportedError('local only');

  @override
  Future<void> prepare({
    required List<MangaRenderItem> items,
    required TtsRenderCancelToken cancel,
  }) async {}

  @override
  bool get canCloneNarrator => false;

  @override
  Future<bool> prepareNarrator({
    required MangaNarratorVoice narrator,
    required TtsRenderCancelToken cancel,
  }) async => false;
}

Map<String, Object?> _block(String text) => <String, Object?>{
  'box': <int>[0, 0, 10, 10],
  'vertical': true,
  'font_size': 12,
  'lines': <String>[text],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String bookKey = 'vol-1';
  const String wire = 'book:vol-1';
  const String item = '$kTtsMangaCtlRoot/:key';

  late FushiDatabase db;
  late Directory tmp;
  late _TtsTestModel model;
  late OpContext context;
  late _FakeAnnotator annotator;
  late MangaAnnotateTasks tasks;
  late TtsRenderQueue queue;
  late _HangingRunner renderRunner;
  late TtsRenderQueue Function() queueOf;
  late bool consent;
  late List<({String lineId, int seed})> regenerated;
  late List<CtlRoute> routes;
  late OpCatalog catalog;

  Future<void> writeScript(MangaAudioScript script) =>
      mangaAudioScriptStoreFor(model).save(bookKey, script);

  Future<MangaAudioScript> readScript() =>
      mangaAudioScriptStoreFor(model).load(bookKey);

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('ctl_tts_');
    model = _TtsTestModel(db, Directory(p.join(tmp.path, 'db')));
    final Directory volDir = Directory(p.join(tmp.path, 'vol'))
      ..createSync(recursive: true);
    File(p.join(volDir.path, 'manga.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'ocr': <String, Object?>{
          'engine': 'test',
          'engine_signature': 'sig-1',
          'schema_version': 1,
        },
        'pages': <Object?>[
          <String, Object?>{
            'url': 'p0.jpg',
            'width': 100,
            'height': 100,
            'blocks': <Object?>[_block('おはよう'), _block('元気？')],
          },
          <String, Object?>{
            'url': 'p1.jpg',
            'width': 100,
            'height': 100,
            'blocks': <Object?>[_block('翌朝。')],
          },
          <String, Object?>{
            'url': 'p2.jpg',
            'width': 100,
            'height': 100,
            'blocks': <Object?>[_block('やあ')],
          },
        ],
      }),
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: '第1巻',
        epubPath: 'manga.json',
        extractDir: volDir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
        format: const Value<String>('manga'),
      ),
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'novel',
        title: '小説',
        epubPath: 'x.epub',
        extractDir: '/x/novel',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
      ),
    );
    await writeScript(
      MangaAudioScript(
        engineSignature: 'sig-1',
        roster: <String, TtsCastCharacter>{
          '太郎': const TtsCastCharacter(name: '太郎'),
        },
        lines: <MangaScriptLine>[
          MangaScriptLine(
            page: 0,
            blocks: const <int>[0],
            speaker: '太郎',
            kind: CastLineKind.spoken,
          ),
          MangaScriptLine(
            page: 0,
            blocks: const <int>[1],
            speaker: kTtsUnknown,
            kind: CastLineKind.spoken,
          ),
          MangaScriptLine(
            page: 1,
            blocks: const <int>[0],
            speaker: kTtsNarrator,
            kind: CastLineKind.narration,
          ),
        ],
        annotatedPages: <int>{0, 1},
      ),
    );

    annotator = _FakeAnnotator(model);
    tasks = MangaAnnotateTasks(runner: annotator.call);
    renderRunner = _HangingRunner();
    queueOf = () => queue;
    queue = TtsRenderQueue(
      store: File(p.join(tmp.path, 'jobs.json')),
      workRoot: Directory(p.join(tmp.path, 'work')),
      runner: renderRunner,
    );
    consent = false;
    regenerated = <({String lineId, int seed})>[];
    context = OpContext(ref: _Ref(model));
    debugOverrideTtsCtlDeps(
      context,
      TtsCtlDeps(
        app: () => model,
        annotateTasks: () => tasks,
        renderQueue: () => queueOf(),
        provider: () => AiProviderConfig(
          id: 'p1',
          presetId: 'openai',
          name: 'Test',
          baseUrl: Uri.parse('https://example.invalid'),
        ),
        hasUploadConsent: () async => consent,
        recordUploadConsent: () async => consent = true,
        voices: () => const <TtsVoicePreset>[
          TtsVoicePreset(id: 'v1', providerId: 'edge', name: 'Voice 1'),
          TtsVoicePreset(id: 'v2', providerId: 'edge', name: 'Voice 2'),
        ],
        activeVoice: () => 'v1',
        regenerate:
            (
              MangaAudioVolume volume, {
              required String lineId,
              required int seed,
              required String voice,
            }) async {
              regenerated.add((lineId: lineId, seed: seed));
              final String file = mangaCandidateFileName(lineId, seed);
              // 与真生成端一致：候选先写暂存名，保留时才发布成 [file]。
              final File out = File(
                p.join(
                  mangaRenderManifestFile(model, bookKey).parent.path,
                  mangaStagedFileName(file),
                ),
              );
              await out.writeAsString('new-$seed');
              return MangaRegenerateCandidate(
                lineId: lineId,
                seed: seed,
                file: file,
                durationMs: 900,
                voice: voice,
                text: 'おはよう',
                shape: 'test-shape',
              );
            },
        stopPlayback: (List<String> keys) async {},
        localAudioBackend: () async => _FakeLocalBackend(),
      ),
    );
    routes = buildTtsCtlRoutes(context);
    catalog = OpCatalog.build(
      routes,
      describeTtsOps(OpDescribeKit(context, routes)),
    );
  });

  tearDown(() async {
    if (!annotator.gate.isCompleted) annotator.gate.complete();
    for (final MangaAnnotateTask t in tasks.running) {
      await t.finished;
    }
    await queue.close();
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{'key': wire},
    Map<String, Object?> body = const <String, Object?>{},
  }) => routes
      .singleWhere((CtlRoute r) => r.method == method && r.pattern == pattern)
      .handler(
        CtlCall(method: method, path: pattern, params: params, body: body),
      );

  /// 像操作目录那样执行一个可撤销操作：capture → 路由 → record，载荷 JSON 往返（与
  /// 记进操作记录表一致），返回结果与撤销闭包。
  Future<(Object?, Future<OpUndoOutcome> Function())> runOp(
    String id, {
    Map<String, String> params = const <String, String>{'key': wire},
    Map<String, Object?> body = const <String, Object?>{},
  }) async {
    final FushiOp op = catalog[id]!;
    final CtlCall c = CtlCall(
      method: op.route.method,
      path: op.route.pattern,
      params: params,
      body: body,
    );
    final OpUndo undo = op.undo!;
    final Map<String, Object?> before =
        await undo.capture?.call(c) ?? const <String, Object?>{};
    final Object? result = await op.route.handler(c);
    final OpUndoRecord record = undo.record(c, before, result);
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(record.payload)) as Map<String, Object?>;
    return (result, () => undo.revert(payload));
  }

  /// 等到 [condition] 成立（任务 / 队列落盘是真 IO，不能只转微任务）。
  Future<void> until(bool Function() condition) async {
    for (int i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: '等待超时');
  }

  Matcher failure(int status) => throwsA(
    isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
  );

  test('读：摘要带角色表与计数，某页的行带文字；键不对 400 / 404 / 422，模块关 422', () async {
    final Map<String, Object?> summary =
        (await call('GET', item))! as Map<String, Object?>;
    expect(summary['key'], wire);
    expect(summary['pages'], 3);
    expect(summary['lines'], 3);
    expect(summary['unknownSpeakerLines'], 1);
    expect(summary['needsReannotation'], isFalse);
    expect(summary['rendered'], isFalse);
    expect(
      (summary['roster']! as List<Object?>).single,
      containsPair('name', '太郎'),
    );

    final Map<String, Object?> page =
        (await call(
              'GET',
              '$item/pages/:page',
              params: <String, String>{'key': wire, 'page': '1'},
            ))!
            as Map<String, Object?>;
    final List<Object?> lines = page['lines']! as List<Object?>;
    expect(lines, hasLength(2));
    expect(lines.first, containsPair('text', 'おはよう'));
    expect(lines.first, containsPair('id', 'p0b0'));
    expect(lines.last, containsPair('speaker', 'unknown'));
    await expectLater(
      call(
        'GET',
        '$item/pages/:page',
        params: <String, String>{'key': wire, 'page': '4'},
      ),
      failure(400),
    );

    await expectLater(
      call('GET', item, params: <String, String>{'key': 'vol-1'}),
      failure(400),
    );
    await expectLater(
      call('GET', item, params: <String, String>{'key': 'book:nope'}),
      failure(404),
    );
    await expectLater(
      call('GET', item, params: <String, String>{'key': 'book:novel'}),
      failure(422),
    );
    model.disabled.add(ModuleId.manga);
    await expectLater(call('GET', item), failure(422));
  });

  test('改一句：说话人要在角色表里（新角色要表态）；改完落盘、记为手改；撤销放回整页', () async {
    await expectLater(
      call(
        'PUT',
        '$item/lines/:line',
        params: <String, String>{'key': wire, 'line': 'p0b1'},
        body: <String, Object?>{'speaker': '花子'},
      ),
      failure(400),
    );
    await expectLater(
      call(
        'PUT',
        '$item/lines/:line',
        params: <String, String>{'key': wire, 'line': 'p0b1'},
      ),
      failure(400),
    );
    await expectLater(
      call(
        'PUT',
        '$item/lines/:line',
        params: <String, String>{'key': wire, 'line': 'p9b9'},
        body: <String, Object?>{'kind': 'shout'},
      ),
      failure(404),
    );

    final (Object? result, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.line.edit',
      params: <String, String>{'key': wire, 'line': 'p0b1'},
      body: <String, Object?>{
        'speaker': '花子',
        'newCharacter': true,
        'kind': 'thought',
        'beat': 400,
        'position': 1,
        'fixes': <String, Object?>{'1': '元気?'},
      },
    );
    expect((result! as Map<String, Object?>)['addedCharacter'], '花子');
    MangaAudioScript script = await readScript();
    final List<MangaScriptLine> page0 = script.linesOnPage(0);
    expect(page0.map((MangaScriptLine l) => l.lineId), <String>[
      'p0b1',
      'p0b0',
    ]);
    expect(page0.first.speaker, '花子');
    expect(page0.first.kind, CastLineKind.thought);
    expect(page0.first.beatMs, 400);
    expect(page0.first.textFixes, <int, String>{1: '元気?'});
    expect(page0.first.source, TtsCastSource.user);
    expect(script.roster.keys, contains('花子'));

    expect((await undo()).status, OpUndoStatus.done);
    script = await readScript();
    expect(script.linesOnPage(0).map((MangaScriptLine l) => l.lineId), <String>[
      'p0b0',
      'p0b1',
    ]);
    expect(script.linesOnPage(0).last.speaker, kTtsUnknown);
    expect(script.roster.keys, isNot(contains('花子')));

    // 撤销之后又被改过：不覆盖。
    final (_, Future<OpUndoOutcome> Function() undo2) = await runOp(
      'tts.manga.line.edit',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'say': 'おっす'},
    );
    await call(
      'PUT',
      '$item/lines/:line',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'say': ''},
    );
    expect((await undo2()).status, OpUndoStatus.superseded);
  });

  test('改一句的语气 / 强度：校验词表与范围；强度要跟着语气；none 清掉；撤销放回', () async {
    for (final Map<String, Object?> bad in <Map<String, Object?>>[
      <String, Object?>{'emotion': 'happy'},
      <String, Object?>{'emotion': 'anger', 'intensity': 101},
      <String, Object?>{'emotion': 'anger', 'intensity': -2},
      <String, Object?>{'intensity': 50},
    ]) {
      await expectLater(
        call(
          'PUT',
          '$item/lines/:line',
          params: <String, String>{'key': wire, 'line': 'p0b0'},
          body: bad,
        ),
        failure(400),
      );
    }

    final (Object? result, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.line.edit',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'emotion': 'anger', 'intensity': 80},
    );
    final Map<String, Object?> line =
        (result! as Map<String, Object?>)['line']! as Map<String, Object?>;
    expect(line['emotion'], 'anger');
    expect(line['intensity'], 80);
    MangaScriptLine edited = (await readScript()).lineById('p0b0')!;
    expect(edited.emotion, CastEmotion.anger);
    expect(edited.intensity, 80);
    expect(edited.source, TtsCastSource.user);

    // 只清强度（-1，与操作目录同口径）：语气留着。
    await call(
      'PUT',
      '$item/lines/:line',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'intensity': -1},
    );
    edited = (await readScript()).lineById('p0b0')!;
    expect(edited.emotion, CastEmotion.anger);
    expect(edited.intensity, isNull);

    // none 清掉语气（强度随之清掉）。
    final (_, Future<OpUndoOutcome> Function() undoClear) = await runOp(
      'tts.manga.line.edit',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'emotion': 'none'},
    );
    edited = (await readScript()).lineById('p0b0')!;
    expect(edited.emotion, isNull);
    expect(edited.intensity, isNull);

    expect((await undoClear()).status, OpUndoStatus.done);
    expect((await readScript()).lineById('p0b0')!.emotion, CastEmotion.anger);
    // 第一次改之后这一页又被改过：不覆盖。
    expect((await undo()).status, OpUndoStatus.superseded);
  });

  test('改一句的语气说明：写入 / 出现在行 JSON；非文字 400；空串清掉；撤销放回', () async {
    await expectLater(
      call(
        'PUT',
        '$item/lines/:line',
        params: <String, String>{'key': wire, 'line': 'p0b0'},
        body: <String, Object?>{'tone': 3},
      ),
      failure(400),
    );
    final (Object? result, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.line.edit',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'tone': '  おずおずと '},
    );
    final Map<String, Object?> line =
        (result! as Map<String, Object?>)['line']! as Map<String, Object?>;
    expect(line['tone'], 'おずおずと');
    MangaScriptLine edited = (await readScript()).lineById('p0b0')!;
    expect(edited.tone, 'おずおずと');
    expect(edited.direction.tone, 'おずおずと');
    expect(edited.source, TtsCastSource.user);

    expect((await undo()).status, OpUndoStatus.done);
    expect((await readScript()).lineById('p0b0')!.tone, isNull);

    await call(
      'PUT',
      '$item/lines/:line',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'tone': '声を落として'},
    );
    await call(
      'PUT',
      '$item/lines/:line',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'tone': ''},
    );
    edited = (await readScript()).lineById('p0b0')!;
    expect(edited.tone, isNull);
  });

  test('改某角色：改名带走行与声音；声音要在列表里；撤销整份放回', () async {
    await expectLater(
      call(
        'PUT',
        '$item/characters/:name',
        params: <String, String>{'key': wire, 'name': '太郎'},
        body: <String, Object?>{'voice': 'nope'},
      ),
      failure(400),
    );
    await expectLater(
      call(
        'PUT',
        '$item/characters/:name',
        params: <String, String>{'key': wire, 'name': '誰'},
        body: <String, Object?>{'voice': 'v1'},
      ),
      failure(404),
    );
    await expectLater(
      call(
        'PUT',
        '$item/characters/:name',
        params: <String, String>{'key': wire, 'name': '太郎'},
        body: <String, Object?>{'voice': 'v1', 'scope': 'series'},
      ),
      failure(422),
    );

    final (Object? result, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.character.edit',
      params: <String, String>{'key': wire, 'name': '太郎'},
      body: <String, Object?>{'rename': '次郎', 'voice': 'v2'},
    );
    expect(result, containsPair('renamedLines', 1));
    MangaAudioScript script = await readScript();
    expect(script.lines.first.speaker, '次郎');
    expect(script.roster.keys, <String>['次郎']);
    expect(script.roster['次郎']!.aliases, contains('太郎'));
    expect(script.voices.byCharacter, <String, String>{'次郎': 'v2'});

    await runOp(
      'tts.manga.character.edit',
      params: <String, String>{'key': wire, 'name': 'narrator'},
      body: <String, Object?>{'voice': 'v1'},
    );
    expect((await readScript()).voices.narrationVoice, 'v1');
    // 之后又被改过（叙述声音）：第一次的撤销不覆盖。
    expect((await undo()).status, OpUndoStatus.superseded);

    final (_, Future<OpUndoOutcome> Function() undoKind) = await runOp(
      'tts.manga.character.edit',
      params: <String, String>{'key': wire, 'name': '次郎'},
      body: <String, Object?>{'voice': 'v1', 'kind': 'thought'},
    );
    script = await readScript();
    expect(script.voices.byCharacterKind['次郎'], <CastLineKind, String>{
      CastLineKind.thought: 'v1',
    });
    expect((await undoKind()).status, OpUndoStatus.done);
    expect((await readScript()).voices.byCharacterKind, isEmpty);
  });

  test('标注：没同意上传 422；表态后后台跑、期间改句 409；撤销取消任务并放回标注前的演出稿', () async {
    await expectLater(call('POST', '$item/annotate'), failure(422));
    expect(annotator.calls, 0);

    final (Object? result, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.annotate',
      body: <String, Object?>{
        'pages': <int>[3],
        'consentUpload': true,
      },
    );
    expect(consent, isTrue);
    expect(result, containsPair('taskId', wire));
    expect(result, containsPair('status', 'running'));
    await until(() => tasks.taskFor(bookKey)?.progressDone == 1);
    expect(annotator.calls, 1);

    final Map<String, Object?> status =
        (await call('GET', '$item/status'))! as Map<String, Object?>;
    expect(status['annotate'], containsPair('status', 'running'));
    expect(
      await catalog['tts.manga.annotate']!.taskStatus!(wire).then(
        (OpTaskStatus s) => s.terminal,
      ),
      isFalse,
    );
    await expectLater(
      call(
        'PUT',
        '$item/lines/:line',
        params: <String, String>{'key': wire, 'line': 'p0b0'},
        body: <String, Object?>{'kind': 'shout'},
      ),
      failure(409),
    );
    await expectLater(call('POST', '$item/annotate'), failure(409));
    expect((await readScript()).linesOnPage(2), hasLength(1));

    final Future<OpUndoOutcome> undone = undo();
    await until(() => tasks.taskFor(bookKey)!.cancelRequested);
    annotator.gate.complete();
    expect((await undone).status, OpUndoStatus.done);
    expect(tasks.taskFor(bookKey)!.status, MangaAnnotateTaskStatus.cancelled);
    final MangaAudioScript script = await readScript();
    expect(script.linesOnPage(2), isEmpty);
    expect(script.annotatedPages, <int>{0, 1});
  });

  test('标注跑完后被手改过：撤销不覆盖', () async {
    consent = true;
    final (_, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.annotate',
    );
    annotator.gate.complete();
    await tasks.taskFor(bookKey)!.finished;
    expect(tasks.taskFor(bookKey)!.status, MangaAnnotateTaskStatus.completed);
    final OpTaskStatus done = await catalog['tts.manga.annotate']!.taskStatus!(
      wire,
    );
    expect(done.terminal && done.succeeded, isTrue);
    await call(
      'PUT',
      '$item/lines/:line',
      params: <String, String>{'key': wire, 'line': 'p2b0'},
      body: <String, Object?>{'kind': 'shout'},
    );
    expect((await undo()).status, OpUndoStatus.superseded);
    expect((await readScript()).linesOnPage(2).single.kind, CastLineKind.shout);
  });

  test('单句重生成：没生成过 422；生成过则换成新种子并保留；撤销放回旧音频与旧种子', () async {
    await expectLater(
      call(
        'POST',
        '$item/lines/:line/regenerate',
        params: <String, String>{'key': wire, 'line': 'p0b0'},
      ),
      failure(422),
    );

    final File manifestFile = mangaRenderManifestFile(model, bookKey);
    await manifestFile.parent.create(recursive: true);
    await File(
      p.join(manifestFile.parent.path, 'p0b0.m4a'),
    ).writeAsString('old-audio');
    await MangaRenderManifest(
      pageCount: 3,
      engineSignature: 'sig-1',
      lines: <MangaRenderedLine>[
        const MangaRenderedLine(
          lineId: 'p0b0',
          page: 0,
          blocks: <int>[0],
          speaker: '太郎',
          kind: CastLineKind.spoken,
          beatMs: 0,
          file: 'p0b0.m4a',
          durationMs: 1200,
          text: 'おはよう',
          voice: 'v1',
          seed: 0,
        ),
      ],
    ).save(manifestFile);

    final (Object? result, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.line.regenerate',
      params: <String, String>{'key': wire, 'line': 'p0b0'},
      body: <String, Object?>{'seed': 42},
    );
    expect(regenerated.single, (lineId: 'p0b0', seed: 42));
    expect(result, containsPair('seed', 42));
    MangaRenderManifest manifest = (await MangaRenderManifest.load(
      manifestFile,
    ))!;
    expect(manifest.lines.single.file, mangaCandidateFileName('p0b0', 42));
    expect(manifest.lines.single.durationMs, 900);
    expect((await readScript()).lineById('p0b0')!.seed, 42);
    expect(
      File(p.join(manifestFile.parent.path, 'p0b0.m4a')).existsSync(),
      isFalse,
    );
    // 重生成之后独立改了停顿与念的文字（HBK-AUDIT-208）：撤销只放回音频与种子。
    final MangaAudioScript edited = await readScript();
    edited.replaceLine(
      'p0b0',
      (MangaScriptLine l) => l.copyWith(beatMs: 900, say: 'こんばんは'),
    );
    await writeScript(edited);

    expect((await undo()).status, OpUndoStatus.done);
    manifest = (await MangaRenderManifest.load(manifestFile))!;
    expect(manifest.lines.single.file, 'p0b0.m4a');
    expect(manifest.lines.single.durationMs, 1200);
    expect((await readScript()).lineById('p0b0')!.beatMs, 900);
    expect((await readScript()).lineById('p0b0')!.say, 'こんばんは');
    expect(
      File(p.join(manifestFile.parent.path, 'p0b0.m4a')).readAsStringSync(),
      'old-audio',
    );
    expect(
      File(
        p.join(manifestFile.parent.path, mangaCandidateFileName('p0b0', 42)),
      ).existsSync(),
      isFalse,
    );
    expect((await readScript()).lineById('p0b0')!.seed, isNull);
    // 已撤销过：清单这句不再是那次的候选文件。
    expect((await undo()).status, OpUndoStatus.superseded);
  });

  test('整卷生成：演出稿空 422；排进队列、期间重生成 409；取消后撤销重新排上', () async {
    final MangaAudioScript empty = await readScript();
    await writeScript(
      MangaAudioScript(engineSignature: 'sig-1', roster: empty.roster),
    );
    await expectLater(
      call('POST', '$item/render'),
      throwsA(
        isA<CtlFailure>().having(
          (CtlFailure f) => f.code,
          'code',
          'manga_script_empty',
        ),
      ),
    );
    await writeScript(empty);
    await expectLater(
      call('POST', '$item/render', body: <String, Object?>{'voice': 'x'}),
      failure(400),
    );

    final Map<String, Object?> queued =
        (await call('POST', '$item/render'))! as Map<String, Object?>;
    expect(queued['taskId'], wire);
    expect(queued['render'], containsPair('voice', 'v1'));
    await until(() => renderRunner.runs == 1);
    final Map<String, Object?> again =
        (await call('POST', '$item/render'))! as Map<String, Object?>;
    expect(again['alreadyQueued'], isTrue);
    await expectLater(
      call(
        'POST',
        '$item/lines/:line/regenerate',
        params: <String, String>{'key': wire, 'line': 'p0b0'},
      ),
      failure(409),
    );
    expect(
      (await catalog['tts.manga.render']!.taskStatus!(wire)).terminal,
      isFalse,
    );

    final (_, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.render-cancel',
    );
    await until(
      () => queue.latestFor(bookKey)!.status == TtsRenderJobStatus.cancelled,
    );
    expect(
      (await catalog['tts.manga.render']!.taskStatus!(wire)).succeeded,
      isFalse,
    );
    await expectLater(call('POST', '$item/render/cancel'), failure(404));

    expect((await undo()).status, OpUndoStatus.done);
    await until(() => renderRunner.runs == 2);
    expect(queue.latestFor(bookKey)!.isTerminal, isFalse);
  });

  /// 在 [dir] 下写一份外部做好的成品：清单 + 每句一个音频（[missing] 里的不写）。
  Future<File> writeExternalManifest(
    String dir, {
    int pageCount = 3,
    String? signature = 'sig-1',
    List<String> lineIds = const <String>['p0b0', 'p0b1'],
    Set<String> missing = const <String>{},
  }) async {
    final Directory root = Directory(p.join(tmp.path, dir))
      ..createSync(recursive: true);
    for (final String id in lineIds) {
      if (!missing.contains(id)) {
        File(p.join(root.path, '$id.m4a')).writeAsStringSync('audio-$id');
      }
    }
    final File file = File(p.join(root.path, 'manifest.json'));
    await MangaRenderManifest(
      pageCount: pageCount,
      engineSignature: signature,
      lines: <MangaRenderedLine>[
        for (int i = 0; i < lineIds.length; i++)
          MangaRenderedLine(
            lineId: lineIds[i],
            page: 0,
            blocks: <int>[i],
            speaker: '太郎',
            kind: CastLineKind.spoken,
            beatMs: 0,
            file: '${lineIds[i]}.m4a',
            durationMs: 1000 + i,
            text: 'line $i',
          ),
      ],
    ).save(file);
    return file;
  }

  Matcher coded(int status, String code, [String? inMessage]) => throwsA(
    isA<CtlFailure>()
        .having((CtlFailure f) => f.status, 'status', status)
        .having((CtlFailure f) => f.code, 'code', code)
        .having(
          (CtlFailure f) => f.message ?? '',
          'message',
          contains(inMessage ?? ''),
        ),
  );

  Future<Object?> importManifest(String manifest, {bool confirm = false}) =>
      call(
        'POST',
        '$item/import',
        body: <String, Object?>{
          'manifest': manifest,
          if (confirm) 'confirm': true,
        },
      );

  test('导入成品：相对路径 400；读不出 / 页数 / OCR / 缺音频各自 422 带原因；不写库', () async {
    await expectLater(importManifest('rel/manifest.json'), failure(400));
    await expectLater(
      importManifest(p.join(tmp.path, 'nope', 'manifest.json')),
      coded(422, 'manga_audio_invalid'),
    );
    final File pages = await writeExternalManifest('pages', pageCount: 5);
    await expectLater(
      importManifest(pages.path),
      coded(422, 'manga_audio_page_mismatch', '5 页'),
    );
    final File ocr = await writeExternalManifest('ocr', signature: 'sig-old');
    await expectLater(
      importManifest(ocr.path),
      coded(422, 'manga_audio_ocr_mismatch'),
    );
    final File gap = await writeExternalManifest(
      'gap',
      missing: <String>{'p0b1'},
    );
    await expectLater(
      importManifest(gap.path),
      coded(422, 'manga_audio_missing_audio', 'p0b1.m4a'),
    );
    expect(await db.getAudiobookByBookKey(bookKey), isNull);
  });

  test('导入成品：首次直接登记；已有成品不带 confirm 409，带了才替换；撤销逐级放回', () async {
    final File first = await writeExternalManifest('first');
    final (
      Object? r1,
      Future<OpUndoOutcome> Function() undoFirst,
    ) = await runOp(
      'tts.manga.import',
      body: <String, Object?>{'manifest': first.path},
    );
    expect(r1, containsPair('replaced', false));
    expect(r1, containsPair('lines', 2));
    expect(r1, containsPair('durationMs', 2001));
    AudiobookRow? row = await db.getAudiobookByBookKey(bookKey);
    expect(row!.alignmentFormat, kMangaAlignmentFormat);
    expect(row.alignmentPath, first.absolute.path);
    expect(await db.getCuesForBook(bookKey), hasLength(2));

    final File second = await writeExternalManifest(
      'second',
      lineIds: <String>['p0b0', 'p0b1', 'p2b0'],
    );
    await expectLater(
      importManifest(second.path),
      coded(409, 'manga_audio_exists', first.absolute.path),
    );
    expect(
      (await db.getAudiobookByBookKey(bookKey))!.alignmentPath,
      first.absolute.path,
    );

    final (
      Object? r2,
      Future<OpUndoOutcome> Function() undoSecond,
    ) = await runOp(
      'tts.manga.import',
      body: <String, Object?>{'manifest': second.path, 'confirm': true},
    );
    expect(r2, containsPair('replaced', true));
    expect(r2, containsPair('previous', first.absolute.path));
    expect(await db.getCuesForBook(bookKey), hasLength(3));

    // 后一次还在：先撤前一次会覆盖后来的导入 → superseded，不动。
    expect((await undoFirst()).status, OpUndoStatus.superseded);
    expect(await db.getCuesForBook(bookKey), hasLength(3));

    expect((await undoSecond()).status, OpUndoStatus.done);
    row = await db.getAudiobookByBookKey(bookKey);
    expect(row!.alignmentPath, first.absolute.path);
    expect(jsonDecode(row.audioPathsJson!) as List<dynamic>, hasLength(2));
    final List<AudioCueRow> cues = await db.getCuesForBook(bookKey);
    expect(cues.map((AudioCueRow c) => c.cueText), <String>[
      'line 0',
      'line 1',
    ]);

    // 再撤第一次：回到没有登记。
    expect((await undoFirst()).status, OpUndoStatus.done);
    expect(await db.getAudiobookByBookKey(bookKey), isNull);
    expect(await db.getCuesForBook(bookKey), isEmpty);
    // 音频文件是原地引用，撤销不删。
    expect(File(p.join(first.parent.path, 'p0b0.m4a')).existsSync(), isTrue);
  });

  test('导入成品：本卷在生成时 409', () async {
    final File file = await writeExternalManifest('busy');
    await queue.enqueue(
      bookKey: bookKey,
      title: 't',
      presetId: 'v1',
      kind: TtsRenderJobKind.manga,
    );
    await expectLater(importManifest(file.path), failure(409));
  });

  /// 本机生成过的成品：p0b0（太郎）/ p0b1（不明）/ p1b0（旁白）三句，各有音频，已入库。
  Future<File> writeRendered() async {
    final File manifestFile = mangaRenderManifestFile(model, bookKey);
    await manifestFile.parent.create(recursive: true);
    final List<(String, int, List<int>, String, CastLineKind)> rows =
        <(String, int, List<int>, String, CastLineKind)>[
          ('p0b0', 0, <int>[0], '太郎', CastLineKind.spoken),
          ('p0b1', 0, <int>[1], kTtsUnknown, CastLineKind.spoken),
          ('p1b0', 1, <int>[0], kTtsNarrator, CastLineKind.narration),
        ];
    for (final (String id, _, _, _, _) in rows) {
      await File(
        p.join(manifestFile.parent.path, '$id.m4a'),
      ).writeAsString('old-$id');
    }
    final MangaRenderManifest manifest = MangaRenderManifest(
      pageCount: 3,
      engineSignature: 'sig-1',
      lines: <MangaRenderedLine>[
        for (final (
              String id,
              int page,
              List<int> blocks,
              String who,
              CastLineKind kind,
            )
            in rows)
          MangaRenderedLine(
            lineId: id,
            page: page,
            blocks: blocks,
            speaker: who,
            kind: kind,
            beatMs: 0,
            file: '$id.m4a',
            durationMs: 1200,
            text: 'text $id',
            voice: 'v1',
            seed: 0,
            shape: 'test-shape',
          ),
      ],
    );
    await manifest.save(manifestFile);
    await registerMangaAudio(
      db,
      bookKey: bookKey,
      manifestFile: manifestFile,
      manifest: manifest,
    );
    return manifestFile;
  }

  File localWav(String name, String content) =>
      File(p.join(tmp.path, 'wavs', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  Future<List<AudioCueRow>> cues() async => (await db.getCuesForBook(bookKey))
    ..sort(
      (AudioCueRow a, AudioCueRow b) => a.audioFileIndex - b.audioFileIndex,
    );

  test('按句换本地音频：没生成过 422；预检逐句给原因、不改；有错不带 dryRun 422', () async {
    final File good = localWav('a.wav', 'wav-a');
    await expectLater(
      call(
        'POST',
        '$item/lines/replace',
        body: <String, Object?>{
          'files': <String, String>{'p0b0': good.path},
        },
      ),
      coded(422, 'manga_not_rendered'),
    );
    final File manifestFile = await writeRendered();
    final String before = await manifestFile.readAsString();
    await expectLater(call('POST', '$item/lines/replace'), failure(400));

    final Object? dry = await call(
      'POST',
      '$item/lines/replace',
      body: <String, Object?>{
        'dryRun': true,
        'files': <String, String>{
          'p0b0': good.path,
          'p0b1': 'rel/b.wav',
          'p1b0': p.join(tmp.path, 'wavs', 'missing.wav'),
          'p2b0': localWav('c.txt', 'x').path,
        },
      },
    );
    final List<Object?> lines = (dry! as Map)['lines'] as List<Object?>;
    expect((dry as Map)['ok'], isFalse);
    Map<Object?, Object?> lineOf(String id) => lines
        .cast<Map<Object?, Object?>>()
        .singleWhere((Map<Object?, Object?> l) => l['line'] == id);
    expect(lineOf('p0b0')['ok'], isTrue);
    expect(lineOf('p0b0')['currentDurationMs'], 1200);
    expect(lineOf('p0b1')['code'], 'path_not_absolute');
    expect(lineOf('p1b0')['code'], 'file_missing');
    expect(lineOf('p2b0')['code'], 'line_missing');

    await expectLater(
      call(
        'POST',
        '$item/lines/replace',
        body: <String, Object?>{
          'files': <String, String>{
            'p0b0': good.path,
            'p1b0': p.join(tmp.path, 'wavs', 'missing.wav'),
          },
        },
      ),
      coded(422, 'manga_audio_replace_invalid', 'p1b0'),
    );
    // 整形失败也是全有或全无。
    await expectLater(
      call(
        'POST',
        '$item/lines/replace',
        body: <String, Object?>{
          'files': <String, String>{
            'p0b0': good.path,
            'p1b0': localWav('bad.wav', 'bad').path,
          },
        },
      ),
      coded(422, 'manga_audio_replace_failed', 'p1b0'),
    );
    expect(await manifestFile.readAsString(), before);
    expect(
      (await readScript()).lineById('p0b0')!.audio,
      isA<MangaSynthesized>(),
    );
  });

  test('按句换本地音频：清单 / 演出稿 / 库里 cue 时长与音频路径一起换，续听位置换算到同一句；撤销放回', () async {
    final File manifestFile = await writeRendered();
    await AudiobookRepository(
      db,
    ).updatePositionMs(bookKey: bookKey, positionMs: 2400 + 600);
    final File mapping = File(p.join(tmp.path, 'wavs', 'map.json'))
      ..createSync(recursive: true);
    localWav('b.wav', 'wav-b');
    mapping.writeAsStringSync(
      jsonEncode(<String, String>{
        'p0b0': localWav('a.wav', 'wav-a').path,
        'p1b0': 'b.wav',
      }),
    );

    final (Object? result, Future<OpUndoOutcome> Function() undo) = await runOp(
      'tts.manga.lines.replace',
      body: <String, Object?>{'mapping': mapping.path},
    );
    expect(result, containsPair('replaced', 2));
    final MangaRenderManifest manifest = (await MangaRenderManifest.load(
      manifestFile,
    ))!;
    final MangaRenderedLine l0 = manifest.lines[0];
    expect(l0.file, startsWith('p0b0.f'));
    expect(l0.voice, startsWith('file:'));
    expect(l0.durationMs, 1500);
    expect(
      File(p.join(manifestFile.parent.path, l0.file)).readAsStringSync(),
      'shaped:wav-a',
    );
    expect(
      File(p.join(manifestFile.parent.path, 'p0b0.m4a')).existsSync(),
      isFalse,
    );
    final MangaLineAudioSource audio = (await readScript())
        .lineById('p0b0')!
        .audio;
    expect(audio, isA<MangaLocalAudio>());
    expect((audio as MangaLocalAudio).name, 'a.wav');
    expect(
      File(
        mangaLocalAudioSourcePath(manifestFile.parent.path, audio),
      ).readAsStringSync(),
      'wav-a',
    );
    List<AudioCueRow> rows = await cues();
    expect(rows.map((AudioCueRow c) => c.endMs), <int>[1500, 1200, 1500]);
    final Audiobook? book = await AudiobookRepository(
      db,
    ).findByBookKey(bookKey);
    expect(book!.audioPaths![0], endsWith(l0.file));
    // 断点原在第 3 句（p1b0）的 600 ms 处；第 1 句换了不归零，第 3 句自己也换了 →
    // 从第 3 句开头接着听。
    expect(await AudiobookRepository(db).readPositionMs(bookKey), 1500 + 1200);

    // 换音之后独立把停顿设成 900 ms、改了说话人（HBK-AUDIT-208）：撤销换音只放回音源，
    // 不抹掉这些编辑。
    final MangaAudioScript edited = await readScript();
    edited.replaceLine(
      'p0b0',
      (MangaScriptLine l) => l.copyWith(beatMs: 900, speaker: kTtsNarrator),
    );
    await writeScript(edited);

    expect((await undo()).status, OpUndoStatus.done);
    expect((await readScript()).lineById('p0b0')!.beatMs, 900);
    expect((await readScript()).lineById('p0b0')!.speaker, kTtsNarrator);
    final MangaRenderManifest back = (await MangaRenderManifest.load(
      manifestFile,
    ))!;
    expect(back.lines[0].file, 'p0b0.m4a');
    expect(back.lines[0].durationMs, 1200);
    expect(
      File(p.join(manifestFile.parent.path, 'p0b0.m4a')).readAsStringSync(),
      'old-p0b0',
    );
    expect(
      File(p.join(manifestFile.parent.path, l0.file)).existsSync(),
      isFalse,
    );
    expect(
      (await readScript()).lineById('p0b0')!.audio,
      isA<MangaSynthesized>(),
    );
    rows = await cues();
    expect(rows.map((AudioCueRow c) => c.endMs), <int>[1200, 1200, 1200]);
    expect((await undo()).status, OpUndoStatus.superseded);
  });

  test('按句换本地音频 / 单句重生成：登记的是外部导入的清单时 409', () async {
    await writeRendered();
    final File external = await writeExternalManifest('ext');
    await importManifest(external.path, confirm: true);
    await expectLater(
      call(
        'POST',
        '$item/lines/replace',
        body: <String, Object?>{
          'files': <String, String>{'p0b0': localWav('a.wav', 'wav-a').path},
        },
      ),
      coded(409, 'manga_audio_external'),
    );
    await expectLater(
      call(
        'POST',
        '$item/lines/:line/regenerate',
        params: <String, String>{'key': wire, 'line': 'p0b0'},
      ),
      coded(409, 'manga_audio_external'),
    );
  });

  test('按角色批量重生成：门检查之后别处排上了这一卷的任务 → 409，不记撤销、撤销也不取消别人的任务', () async {
    await writeRendered();
    // 入口的「没在生成」检查看到的是空队列；轮到排队时这一卷已有别处排的整卷生成——
    // enqueue 原样返回那个任务、不排这次的批量重生成。
    final _HangingRunner otherRunner = _HangingRunner();
    final TtsRenderQueue busy = TtsRenderQueue(
      store: File(p.join(tmp.path, 'jobs-busy.json')),
      workRoot: Directory(p.join(tmp.path, 'work-busy')),
      runner: otherRunner,
    );
    final TtsRenderJob other = await busy.enqueue(
      bookKey: bookKey,
      title: 'vol',
      presetId: 'v1',
      kind: TtsRenderJobKind.manga,
    );
    await until(() => otherRunner.runs == 1);
    int calls = 0;
    queueOf = () => ++calls == 1 ? queue : busy;
    await expectLater(
      call(
        'POST',
        '$item/characters/:name/regenerate',
        params: <String, String>{'key': wire, 'name': '太郎'},
      ),
      failure(409),
    );
    final Directory backups = mangaCtlBackupDir(model, bookKey);
    expect(
      backups.existsSync() ? backups.listSync() : const <FileSystemEntity>[],
      isEmpty,
    );
    expect(busy.latestFor(bookKey)!.id, other.id);
    expect(busy.latestFor(bookKey)!.isTerminal, isFalse);
    await busy.cancel(other.id);
    await until(() => busy.latestFor(bookKey)!.isTerminal);
    await busy.close();
  });

  test('按角色批量重生成：预检列句子与跳过原因；排进队列；撤销取消任务、放回已换的句子', () async {
    final File manifestFile = await writeRendered();
    await expectLater(
      call(
        'POST',
        '$item/characters/:name/regenerate',
        params: <String, String>{'key': wire, 'name': '花子'},
      ),
      failure(404),
    );
    // 太郎还有一句没生成过：按角色重生成要跳过它。
    final MangaAudioScript script = await readScript();
    script.lines.add(
      MangaScriptLine(
        page: 2,
        blocks: const <int>[0],
        speaker: '太郎',
        kind: CastLineKind.spoken,
      ),
    );
    await writeScript(script);
    final Object? dry = await call(
      'POST',
      '$item/characters/:name/regenerate',
      params: <String, String>{'key': wire, 'name': '太郎'},
      body: <String, Object?>{'dryRun': true},
    );
    expect(
      ((dry! as Map)['lines'] as List<Object?>).map(
        (Object? l) => (l! as Map)['line'],
      ),
      <String>['p0b0'],
    );
    expect((dry as Map)['skipped'], <Object?>[
      <String, Object?>{'line': 'p2b0', 'reason': 'not_rendered'},
    ]);
    expect(queue.latestFor(bookKey), isNull);

    // 跑起来后撤销：任务还在跑 → 取消，什么都没换成。
    final (Object? r1, Future<OpUndoOutcome> Function() undo1) = await runOp(
      'tts.manga.character.regenerate',
      params: <String, String>{'key': wire, 'name': '太郎'},
    );
    expect(r1, containsPair('taskId', wire));
    await until(() => renderRunner.runs == 1);
    final TtsRenderJob job1 = queue.latestFor(bookKey)!;
    expect(job1.lineRequests.single.lineId, 'p0b0');
    expect(job1.lineRequests.single.seed, isNotNull);
    expect((await undo1()).status, OpUndoStatus.done);
    expect(queue.latestFor(bookKey)!.status, TtsRenderJobStatus.cancelled);

    // 再跑一次，模拟任务换好了这一句（新种子、新文件），撤销放回旧音频与旧种子。
    final (Object? _, Future<OpUndoOutcome> Function() undo2) = await runOp(
      'tts.manga.character.regenerate',
      params: <String, String>{'key': wire, 'name': '太郎'},
    );
    final TtsRenderJob job2 = queue.latestFor(bookKey)!;
    final int seed = job2.lineRequests.single.seed!;
    await queue.cancel(job2.id);
    await until(() => queue.latestFor(bookKey)!.isTerminal);
    final String newFile = mangaCandidateFileName('p0b0', seed);
    await File(
      p.join(manifestFile.parent.path, newFile),
    ).writeAsString('new-audio');
    final MangaRenderManifest manifest = (await MangaRenderManifest.load(
      manifestFile,
    ))!;
    manifest.replaceLine(
      'p0b0',
      (MangaRenderedLine l) => l.replaced(
        file: newFile,
        durationMs: 900,
        placeholder: false,
        voice: 'v1',
        seed: seed,
      ),
    );
    await manifest.save(manifestFile);
    await File(p.join(manifestFile.parent.path, 'p0b0.m4a')).delete();
    final MangaAudioScript changed = await readScript();
    changed.replaceLine('p0b0', (MangaScriptLine l) => l.copyWith(seed: seed));
    await writeScript(changed);
    // 重生成之后独立改了停顿与念的文字（HBK-AUDIT-208）：撤销只放回音频与种子。
    final MangaAudioScript edited = await readScript();
    edited.replaceLine(
      'p0b0',
      (MangaScriptLine l) => l.copyWith(beatMs: 900, say: 'こんばんは'),
    );
    await writeScript(edited);

    expect((await undo2()).status, OpUndoStatus.done);
    final MangaRenderManifest back = (await MangaRenderManifest.load(
      manifestFile,
    ))!;
    expect(back.lines[0].file, 'p0b0.m4a');
    expect(back.lines[0].seed, 0);
    expect(
      File(p.join(manifestFile.parent.path, 'p0b0.m4a')).readAsStringSync(),
      'old-p0b0',
    );
    expect(
      File(p.join(manifestFile.parent.path, newFile)).existsSync(),
      isFalse,
    );
    expect((await readScript()).lineById('p0b0')!.seed, isNull);
    expect((await readScript()).lineById('p0b0')!.beatMs, 900);
    expect((await readScript()).lineById('p0b0')!.say, 'こんばんは');
    expect((await cues()).first.endMs, 1200);
  });

  test('描述：写操作都可撤销或标 irreversible；生成与标注是长任务', () {
    expect(catalog['tts.manga.render']!.risk, OpRisk.irreversible);
    expect(catalog['tts.manga.annotate']!.spec.needsConfirmation, isTrue);
    expect(catalog['tts.manga.annotate']!.longRunning, isTrue);
    for (final String id in <String>[
      'tts.manga.line.edit',
      'tts.manga.character.edit',
      'tts.manga.line.regenerate',
      'tts.manga.lines.replace',
      'tts.manga.character.regenerate',
      'tts.manga.render-cancel',
      'tts.manga.annotate',
      'tts.manga.import',
    ]) {
      expect(catalog[id]!.undo, isNotNull, reason: id);
    }
  });
}
