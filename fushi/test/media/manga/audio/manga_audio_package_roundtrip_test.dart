import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show registerMangaAudio;
import 'package:fushi/src/media/manga/audio/manga_audio_package_export.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_import.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_io.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_volume_busy.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart'
    show MangaAnnotateRunSummary;
import 'package:fushi_engine/tts/manga_audio/manga_audio_package.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

class _Session implements AudiobookSession {
  @override
  Future<void> stopIfPlayingAny(Iterable<String> bookKeys) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingRunner implements TtsRenderRunner {
  @override
  Future<({bool verified, List<TtsRenderFlag> flags})> run(
    TtsRenderJob job, {
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) async => throw const TtsRenderFailure('synthesis_failed');
}

class _Host implements AudioProductionHost {
  _Host(this.database, this.databaseDirectory);

  @override
  final FushiDatabase database;

  @override
  final Directory databaseDirectory;

  @override
  final AudiobookSession audiobookSession = _Session();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> _block(String text) => <String, Object?>{
  'box': <int>[0, 0, 10, 10],
  'vertical': true,
  'font_size': 12,
  'lines': <String>[text],
};

const String _bookKey = 'vol-1';
const String _title = '第1巻';
const String _seriesName = 'テストシリーズ';

/// 源设备上一卷做好有声漫画的漫画：3 页页图、演出稿 3 句、成品 3 句已登记，
/// 在合集「テストシリーズ」里，系列档案给太郎指了声音。
Future<void> _seedSource(_Host host, Directory root) async {
  final FushiDatabase db = host.database;
  final Directory volDir = Directory(p.join(root.path, 'vol'))
    ..createSync(recursive: true);
  for (int i = 0; i < 3; i++) {
    File(p.join(volDir.path, 'p$i.jpg')).writeAsBytesSync(<int>[i, 1, 2, 3]);
  }
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
      bookKey: _bookKey,
      title: _title,
      epubPath: 'manga.json',
      extractDir: volDir.path,
      // 漫画卷的 chapterCount 是页数（MangaImporter 落库约定）。
      chapterCount: 3,
      chaptersJson: '[]',
      importedAt: 1000,
      format: const Value<String>('manga'),
    ),
  );
  await mangaAudioScriptStoreFor(host).save(
    _bookKey,
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
  final File manifestFile = mangaRenderManifestFile(host, _bookKey);
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
    ).writeAsString('audio-$id');
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
    bookKey: _bookKey,
    manifestFile: manifestFile,
    manifest: manifest,
  );
  final String uid = (await db.resolveEpubBookUid(_bookKey))!;
  final int collection = await db.createMediaCollection(_seriesName);
  await db.addToCollection(collection, MediaKind.epub, uid);
  await seriesCastStoreFor(host).update(
    '$kSeriesKeyCollectionPrefix$collection',
    (SeriesCastProfile profile) {
      profile.voices.byCharacter['太郎'] = 'voice-taro';
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FushiDatabase sourceDb;
  late FushiDatabase targetDb;
  late _Host source;
  late _Host target;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('manga_pkg_');
    sourceDb = FushiDatabase.forTesting(NativeDatabase.memory());
    targetDb = FushiDatabase.forTesting(NativeDatabase.memory());
    source = _Host(sourceDb, Directory(p.join(tmp.path, 'a', 'db')));
    target = _Host(targetDb, Directory(p.join(tmp.path, 'b', 'db')));
    EpubStorage.debugBaseDirectoryOverride = p.join(tmp.path, 'b', 'books');
    await _seedSource(source, Directory(p.join(tmp.path, 'a')));
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await sourceDb.close();
    await targetDb.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> exportPackage({bool scriptOnly = false}) async {
    final MangaPackageExportPlan plan = await planMangaAudioPackageExport(
      source,
      <MangaPackageExportItem>[
        MangaPackageExportItem(_bookKey, scriptOnly: scriptOnly),
      ],
    );
    final String out = p.join(tmp.path, 'out$kMangaAudioPackageExtension');
    await runMangaAudioPackageExport(plan, outputPath: out, appLabel: 'test');
    return out;
  }

  test('导出后在另一台空库导入：新建同一卷、成品登记、系列选角带过去；撤销删干净', () async {
    final String path = await exportPackage();
    final MangaAudioPackageManifest manifest =
        await readMangaAudioPackageManifest(path);
    final MangaAudioPackageVolume packed = manifest.volumes.single;
    expect(packed.title, _title);
    expect(packed.pageCount, 3);
    expect(packed.audio!.lines, 3);
    expect(packed.audio!.active, isTrue);
    expect(manifest.series.single.title, _seriesName);
    expect(packed.voices, contains('voice-taro'));

    final MangaPackageImportPlan plan = await planMangaAudioPackageImport(
      target,
      path,
    );
    expect(plan.volumes.single.action, MangaPackageImportAction.create);
    expect(plan.needsConfirm, isFalse);

    final Map<String, Object?> result = await runMangaAudioPackageImport(
      target,
      plan,
      runId: 'r1',
    );
    expect(result['imported'], 1, reason: '$result');
    final Map<String, Object?> volume =
        (result['volumes']! as List<Object?>).single! as Map<String, Object?>;
    final String newKey = volume['bookKey']! as String;

    final EpubBookRow row = (await targetDb.getEpubBook(newKey))!;
    expect(row.title, _title);
    expect(row.format, 'manga');
    final List<String> pages = <String>[
      for (final FileSystemEntity e in Directory(
        row.extractDir,
      ).listSync(recursive: true))
        if (e.path.endsWith('.jpg')) p.basename(e.path),
    ]..sort();
    expect(pages, <String>['p0.jpg', 'p1.jpg', 'p2.jpg']);

    final MangaAudioScript script = await mangaAudioScriptStoreFor(
      target,
    ).load(newKey);
    expect(script.lines, hasLength(3));
    final AudiobookRow? audiobook = await targetDb.getAudiobookByBookKey(
      newKey,
    );
    expect(audiobook, isNotNull);
    expect(await targetDb.getCuesForBook(newKey), hasLength(3));
    final MangaRenderManifest? rendered = await MangaRenderManifest.load(
      File(audiobook!.alignmentPath),
    );
    expect(rendered!.lines, hasLength(3));
    for (final MangaRenderedLine line in rendered.lines) {
      expect(
        await File(
          p.join(File(audiobook.alignmentPath).parent.path, line.file),
        ).readAsString(),
        'audio-${line.lineId}',
      );
    }

    final String? seriesKey = await resolveSeriesKey(target, newKey);
    expect(seriesKey, isNotNull);
    final SeriesCastProfile profile = await seriesCastStoreFor(
      target,
    ).load(seriesKey!);
    expect(profile.voices.byCharacter['太郎'], 'voice-taro');
    expect(profile.members, contains(newKey));

    // 再导一次同一个包：认出本机同一卷，替换演出稿 / 成品要确认。
    final MangaPackageImportPlan again = await planMangaAudioPackageImport(
      target,
      path,
    );
    expect(again.volumes.single.action, MangaPackageImportAction.useExisting);
    expect(again.volumes.single.match.bookKey, newKey);
    expect(again.volumes.single.replacesAudio, isTrue);
    expect(again.needsConfirm, isTrue);

    final MangaPackageUndoResult undo = await revertMangaAudioPackageImport(
      target,
      'r1',
    );
    expect(undo.status, 'done', reason: undo.message);
    expect(await targetDb.getEpubBook(newKey), isNull);
    expect(await targetDb.getAudiobookByBookKey(newKey), isNull);
    expect(
      (await revertMangaAudioPackageImport(target, 'r1')).status,
      'superseded',
    );
  });

  test('导入到已有同一卷：替换成品后撤销恢复原来的演出稿与成品', () async {
    final String path = await exportPackage();
    // 目标机就是源机自己：卷已在、演出稿与成品都在。
    final File script = mangaAudioScriptStoreFor(source).fileFor(_bookKey);
    final String scriptBefore = await script.readAsString();
    final MangaPackageImportPlan plan = await planMangaAudioPackageImport(
      source,
      path,
    );
    expect(plan.volumes.single.action, MangaPackageImportAction.useExisting);
    expect(plan.volumes.single.match.bookKey, _bookKey);
    await mangaAudioScriptStoreFor(
      source,
    ).save(_bookKey, MangaAudioScript(engineSignature: 'sig-1'));
    final Map<String, Object?> result = await runMangaAudioPackageImport(
      source,
      plan,
      runId: 'r2',
    );
    expect(result['imported'], 1, reason: '$result');
    expect(
      (await mangaAudioScriptStoreFor(source).load(_bookKey)).lines,
      hasLength(3),
    );
    expect(await sourceDb.getCuesForBook(_bookKey), hasLength(3));

    final MangaPackageUndoResult undo = await revertMangaAudioPackageImport(
      source,
      'r2',
    );
    expect(undo.status, 'done', reason: undo.message);
    expect(
      (await mangaAudioScriptStoreFor(source).load(_bookKey)).lines,
      isEmpty,
      reason: '撤销回到导入前（导入前演出稿是空的那份）',
    );
    expect(scriptBefore, isNotEmpty);
    expect(await sourceDb.getEpubBook(_bookKey), isNotNull, reason: '已有的卷不删');
  });

  test('撤销时卷在导入之后又被改过：卷留下，也留在原系列 / 合集里', () async {
    final String path = await exportPackage();
    final Map<String, Object?> result = await runMangaAudioPackageImport(
      target,
      await planMangaAudioPackageImport(target, path),
      runId: 'r5',
    );
    final String newKey =
        ((result['volumes']! as List<Object?>).single!
                as Map<String, Object?>)['bookKey']!
            as String;
    final String seriesKey = (await resolveSeriesKey(target, newKey))!;
    // 导入之后登记又被改过（重新生成 / 补句之类）。
    await targetDb.patchAudiobook(
      newKey,
      const AudiobooksCompanion(audioRoot: Value<String?>('changed-later')),
    );

    final MangaPackageUndoResult undo = await revertMangaAudioPackageImport(
      target,
      'r5',
    );
    expect(undo.status, 'superseded', reason: undo.message);
    expect(await targetDb.getEpubBook(newKey), isNotNull);
    expect(
      await resolveSeriesKey(target, newKey),
      seriesKey,
      reason: '留下的卷不能被摘出导入时进的合集',
    );
    expect(
      (await seriesCastStoreFor(target).load(seriesKey)).members,
      contains(newKey),
      reason: '系列档案不放回导入前，否则留下的卷从成员里消失',
    );
  });

  test('落库中途出错：已落库的部分照样写进撤销日志、能撤干净', () async {
    final String path = await exportPackage();
    expect(await targetDb.getAllMediaCollections(), isEmpty);
    // 新建的合集在空库里 id = 1：把它的系列档案位置占成目录，系列这一步写档案必然失败。
    Directory(
      p.join(
        target.databaseDirectory.path,
        'tts_cast',
        '${sha1.convert(utf8.encode('${kSeriesKeyCollectionPrefix}1'))}'
            '.series-cast.json',
      ),
    ).createSync(recursive: true);
    await expectLater(
      runMangaAudioPackageImport(
        target,
        await planMangaAudioPackageImport(target, path),
        runId: 'r6',
      ),
      throwsA(isA<FileSystemException>()),
    );
    final List<EpubBookRow> books = await targetDb.getAllEpubBooks();
    expect(books, hasLength(1), reason: '卷已经落库');
    expect(await targetDb.getAllMediaCollections(), hasLength(1));

    final MangaPackageUndoResult undo = await revertMangaAudioPackageImport(
      target,
      'r6',
    );
    expect(undo.status, 'done', reason: undo.message);
    expect(await targetDb.getAllEpubBooks(), isEmpty);
    expect(await targetDb.getAllMediaCollections(), isEmpty);
  });

  test('只导出演出稿：包里没有成品，导入后有演出稿、不登记有声', () async {
    final String path = await exportPackage(scriptOnly: true);
    final MangaAudioPackageVolume packed = (await readMangaAudioPackageManifest(
      path,
    )).volumes.single;
    expect(packed.hasAudio, isFalse);
    final Map<String, Object?> result = await runMangaAudioPackageImport(
      target,
      await planMangaAudioPackageImport(target, path),
      runId: 'r3',
    );
    final String newKey =
        ((result['volumes']! as List<Object?>).single!
                as Map<String, Object?>)['bookKey']!
            as String;
    expect(
      (await mangaAudioScriptStoreFor(target).load(newKey)).lines,
      hasLength(3),
    );
    expect(await targetDb.getAudiobookByBookKey(newKey), isNull);
  });

  test('包里文件缺了：这一卷判坏、不落库', () async {
    final String path = await exportPackage();
    final MangaPackageImportPlan plan = await planMangaAudioPackageImport(
      target,
      path,
    );
    // 把一个音频条目换掉内容，清单不动。
    final String tampered = p.join(tmp.path, 'tampered.zip');
    await writeMangaAudioPackageZip(
      outputPath: tampered,
      entries: <MangaPackageZipEntry>[
        MangaPackageZipEntry.bytes(
          kMangaAudioPackageManifestName,
          utf8.encode(plan.manifest.encode()),
        ),
      ],
    );
    final MangaPackageImportPlan bad = await planMangaAudioPackageImport(
      target,
      tampered,
    );
    final Map<String, Object?> result = await runMangaAudioPackageImport(
      target,
      bad,
      runId: 'r4',
    );
    expect(result['failed'], 1, reason: '$result');
    expect(
      ((result['volumes']! as List<Object?>).single!
          as Map<String, Object?>)['code'],
      'package_corrupt',
    );
    expect(await targetDb.getAllEpubBooks(), isEmpty);
  });

  test('同一个目标文件已有导出在写：任务表拒绝再起一个', () async {
    final MangaAudioPackageTasks tasks = MangaAudioPackageTasks();
    final Completer<void> gate = Completer<void>();
    final String out = p.join(tmp.path, 'same$kMangaAudioPackageExtension');
    final MangaAudioPackageTask first = tasks.start(
      kind: MangaAudioPackageTaskKind.export,
      path: out,
      run: (MangaAudioPackageTask task) async {
        await gate.future;
        return <String, Object?>{};
      },
    );
    expect(
      () => tasks.start(
        kind: MangaAudioPackageTaskKind.export,
        path: out,
        run: (MangaAudioPackageTask task) async => <String, Object?>{},
      ),
      throwsA(
        isA<MangaAudioPackageException>().having(
          (MangaAudioPackageException e) => e.code,
          'code',
          'export_running',
        ),
      ),
    );
    gate.complete();
    await first.whenDone;
    final MangaAudioPackageTask second = tasks.start(
      kind: MangaAudioPackageTaskKind.export,
      path: out,
      run: (MangaAudioPackageTask task) async => <String, Object?>{},
    );
    await second.whenDone;
    expect(second.status, MangaAudioPackageTaskStatus.done);
  });

  Future<int> mangaBookCount() async => (await targetDb.getAllEpubBooks())
      .where((EpubBookRow r) => r.format == 'manga')
      .length;

  test('同一个包导两次（含换个文件名的副本）：在跑时第二次起不来；之后拿旧计划落库判 plan_stale，'
      '不建重复的卷（BUG-5337）', () async {
    final String path = await exportPackage();
    final String copy = p.join(tmp.path, 'copy$kMangaAudioPackageExtension');
    await File(path).copy(copy);
    final MangaPackageImportPlan first = await planMangaAudioPackageImport(
      target,
      path,
    );
    final MangaPackageImportPlan second = await planMangaAudioPackageImport(
      target,
      copy,
    );
    // 两份计划都是读包时定的：本机还没有这一卷，都判「新建」。
    expect(first.volumes.single.action, MangaPackageImportAction.create);
    expect(second.volumes.single.action, MangaPackageImportAction.create);

    final MangaAudioPackageTasks tasks = MangaAudioPackageTasks();
    final Completer<void> gate = Completer<void>();
    final List<String> created = <String>[];
    final List<bool> claimedWhileRunning = <bool>[];
    final MangaAudioPackageTask running = tasks.start(
      kind: MangaAudioPackageTaskKind.import,
      path: path,
      claims: mangaPackageImportClaims(first),
      run: (MangaAudioPackageTask task) async {
        await gate.future;
        return runMangaAudioPackageImport(
          target,
          first,
          runId: task.id,
          onCommit: task.markCommitting,
          onCreated: (String bookKey) {
            created.add(bookKey);
            task.claimVolume(bookKey);
            // 新建出来的卷从这一刻起算「正在导入」，别处判忙；任务自己不算。
            claimedWhileRunning
              ..add(identical(tasks.importingVolume(bookKey), task))
              ..add(tasks.importingVolume(bookKey, except: task) == null);
          },
        );
      },
    );
    Matcher importRunning() => throwsA(
      isA<MangaAudioPackageException>().having(
        (MangaAudioPackageException e) => e.code,
        'code',
        'import_running',
      ),
    );
    for (final (String file, MangaPackageImportPlan plan)
        in <(String, MangaPackageImportPlan)>[(path, first), (copy, second)]) {
      expect(
        () => tasks.start(
          kind: MangaAudioPackageTaskKind.import,
          path: file,
          claims: mangaPackageImportClaims(plan),
          run: (MangaAudioPackageTask task) async => <String, Object?>{},
        ),
        importRunning(),
      );
    }
    gate.complete();
    await running.whenDone;
    expect(running.status, MangaAudioPackageTaskStatus.done);
    expect(running.result!['imported'], 1, reason: '${running.result}');
    expect(created, hasLength(1));
    expect(claimedWhileRunning, <bool>[true, true]);
    expect(tasks.importingVolume(created.single), isNull, reason: '结束即释放');
    expect(await mangaBookCount(), 1);

    // 第一次结束后再用读包时那份「新建」计划落库：本机已经有这一卷，不再建。
    final Map<String, Object?> stale = await runMangaAudioPackageImport(
      target,
      second,
      runId: 'r2',
    );
    final Map<String, Object?> outcome =
        (stale['volumes']! as List<Object?>).single! as Map<String, Object?>;
    expect(stale['imported'], 0, reason: '$stale');
    expect(outcome['code'], 'plan_stale', reason: '$outcome');
    expect(await mangaBookCount(), 1);
  });

  test('导入占住的卷算忙：标注任务表与生成队列都拒收，判据排除导入自己；结束后放行（BUG-5337）', () async {
    const String key = 'vol-x';
    final MangaAudioPackageTasks packages = MangaAudioPackageTasks();
    final MangaAnnotateTasks annotate = MangaAnnotateTasks(
      runner:
          (
            MangaAnnotateRequest request,
            MangaAnnotateTaskSink sink,
            bool Function() isCancelled,
          ) => Completer<MangaAnnotateRunSummary>().future,
      blocker: (String bookKey) =>
          mangaVolumeImportBlocker(bookKey, packages: packages),
    );
    final TtsRenderQueue queue = TtsRenderQueue(
      store: File(p.join(tmp.path, 'jobs.json')),
      workRoot: Directory(p.join(tmp.path, 'work')),
      runner: _FailingRunner(),
      admission: (String bookKey) =>
          mangaVolumeImportBlocker(bookKey, packages: packages) == null
          ? null
          : kMangaPackageImportingCode,
    );
    addTearDown(queue.close);
    MangaVolumeBusy? busy({MangaAudioPackageTask? except}) => mangaVolumeBusy(
      key,
      annotate: annotate,
      renderQueue: queue,
      packages: packages,
      except: except,
    );
    final MangaAnnotateRequest request = MangaAnnotateRequest.annotate(
      bookKey: key,
      provider: AiProviderConfig(
        id: 'p1',
        presetId: 'openai',
        name: 'Test',
        baseUrl: Uri.parse('https://example.invalid'),
      ),
    );

    final Completer<void> gate = Completer<void>();
    final MangaAudioPackageTask importing = packages.start(
      kind: MangaAudioPackageTaskKind.import,
      path: p.join(tmp.path, 'in$kMangaAudioPackageExtension'),
      claims: <String>{mangaPackageBookClaim(key)},
      run: (MangaAudioPackageTask task) async {
        await gate.future;
        return <String, Object?>{};
      },
    );
    expect(busy(), MangaVolumeBusy.importing);
    expect(busy(except: importing), isNull);
    expect(
      () => annotate.start(request),
      throwsA(
        isA<MangaVolumeBusyException>().having(
          (MangaVolumeBusyException e) => e.busy,
          'busy',
          MangaVolumeBusy.importing,
        ),
      ),
    );
    expect(annotate.isRunning(key), isFalse);
    await expectLater(
      queue.enqueue(
        bookKey: key,
        title: 't',
        presetId: 'v1',
        kind: TtsRenderJobKind.manga,
      ),
      throwsA(
        isA<TtsRenderRejected>().having(
          (TtsRenderRejected e) => e.reason,
          'reason',
          kMangaPackageImportingCode,
        ),
      ),
    );
    expect(queue.latestFor(key), isNull);

    gate.complete();
    await importing.whenDone;
    expect(busy(), isNull);
    annotate.start(request, announce: false);
    expect(busy(), MangaVolumeBusy.annotating);
    final TtsRenderJob job = await queue.enqueue(
      bookKey: key,
      title: 't',
      presetId: 'v1',
      kind: TtsRenderJobKind.manga,
    );
    expect(job.bookKey, key);
  });

  test('不是有声漫画包：计划阶段就报 not_package', () async {
    final File junk = File(p.join(tmp.path, 'junk$kMangaAudioPackageExtension'))
      ..writeAsStringSync('nope');
    await expectLater(
      planMangaAudioPackageImport(target, junk.path),
      throwsA(
        isA<MangaAudioPackageException>().having(
          (MangaAudioPackageException e) => e.code,
          'code',
          'package_invalid',
        ),
      ),
    );
  });
}
