import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart'
    show mangaCandidateFileName;
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
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
        renderQueue: () => queue,
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
              final File out = File(
                p.join(
                  mangaRenderManifestFile(model, bookKey).parent.path,
                  file,
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

    expect((await undo()).status, OpUndoStatus.done);
    manifest = (await MangaRenderManifest.load(manifestFile))!;
    expect(manifest.lines.single.file, 'p0b0.m4a');
    expect(manifest.lines.single.durationMs, 1200);
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

  test('描述：写操作都可撤销或标 irreversible；生成与标注是长任务', () {
    expect(catalog['tts.manga.render']!.risk, OpRisk.irreversible);
    expect(catalog['tts.manga.annotate']!.spec.needsConfirmation, isTrue);
    expect(catalog['tts.manga.annotate']!.longRunning, isTrue);
    for (final String id in <String>[
      'tts.manga.line.edit',
      'tts.manga.character.edit',
      'tts.manga.line.regenerate',
      'tts.manga.render-cancel',
      'tts.manga.annotate',
    ]) {
      expect(catalog[id]!.undo, isNotNull, reason: id);
    }
  });
}
