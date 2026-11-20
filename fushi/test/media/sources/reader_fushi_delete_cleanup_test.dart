// 删书原语 `ReaderFushiSource.deleteBook` 的三处清理缺口（路线图 #3722 c37）：
// - BUG-4906：appModel 可选、多数调用点不传 → override 封面文件不清，同名书重新导入
//   （bookKey = 净化后的书名，同名即同键）后旧封面复活。先在 develop 上复现过一次：
//   不传 appModel 删书 → 同名重导 → resolveOverrideThumbnailFile 非空。
// - BUG-4907：每删一本都跑一次整库 VACUUM + wal_checkpoint，批删 N 本串行 N 次。
// - BUG-4908：「同步删除」的墓碑写入失败被 `catch (_)` 吞掉，无日志。
// 真实内存 Drift 库 + 真实删书原语；VACUUM 计数与墓碑写失败都经 Drift 拦截器观测 /
// 注入，不碰用户库。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart' show SrtBook, SrtBookRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart' show DeleteScope;

import '../../helpers/test_platform_services.dart';

class _ThumbAppModel extends AppModel {
  _ThumbAppModel(this._thumbs) : super(testPlatformServices());
  final Directory _thumbs;
  @override
  Directory get thumbnailsDirectory => _thumbs;
}

/// 记下所有 custom 语句（数 VACUUM），可按需让墓碑表的插入失败。
class _Recorder extends QueryInterceptor {
  final List<String> customStatements = <String>[];
  bool failTombstoneInsert = false;

  int get vacuumCount =>
      customStatements.where((String s) => s.trim() == 'VACUUM').length;

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    customStatements.add(statement);
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (failTombstoneInsert && statement.contains('sync_deletion_tombstones')) {
      throw StateError('injected sync tombstone write failure');
    }
    return super.runInsert(executor, statement, args);
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Recorder recorder;
  late FushiDatabase db;
  late AppModel app;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('fushi_delete_cleanup');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => root.path,
    );
    recorder = _Recorder();
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(recorder),
    );
    // 先打开并迁移，再开始记录。
    await db.customSelect('SELECT 1').get();
    recorder.customStatements.clear();
    MediaSource.setDatabase(db);
    final Directory thumbs = Directory('${root.path}/thumbs')..createSync();
    app = _ThumbAppModel(thumbs);
  });
  tearDown(() async {
    await db.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  EpubBooksCompanion bookRow(String key, {String? sourceMetadata}) =>
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/tmp/$key.epub',
        extractDir: '${root.path}/extract/$key',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: 1,
        sourceMetadata: sourceMetadata == null
            ? const Value<String?>.absent()
            : Value<String?>(sourceMetadata),
      );

  MediaItem itemFor(String bookKey) {
    final ReaderFushiSource src = ReaderFushiSource.instance;
    return MediaItem(
      mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
      title: '',
      mediaTypeIdentifier: src.mediaType.uniqueKey,
      mediaSourceIdentifier: src.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );
  }

  /// 给这本书写一个 override 封面文件（与「编辑封面」落盘的规范路径相同）。
  File writeOverrideCover(String bookKey) => File(
    ReaderFushiSource.instance.getOverrideThumbnailFilename(
      appModel: app,
      item: itemFor(bookKey),
    ),
  )..writeAsBytesSync(<int>[1, 2, 3]);

  File? resolvedCover(String bookKey) => ReaderFushiSource.instance
      .resolveOverrideThumbnailFile(appModel: app, item: itemFor(bookKey));

  group('BUG-4906 删书清 override 封面，同名重导不复活', () {
    test('书架删书后同名书重新导入，没有旧封面', () async {
      await db.insertEpubBook(bookRow('Kokoro'));
      final File cover = writeOverrideCover('Kokoro');

      final DeleteBookResult r = await ReaderFushiSource.instance.deleteBook(
        db: db,
        bookKey: 'Kokoro',
        appModel: app,
      );
      expect(r.deleted, isTrue);
      expect(cover.existsSync(), isFalse);

      // 同名重导 = 同一个 bookKey。
      await db.insertEpubBook(bookRow('Kokoro'));
      expect(resolvedCover('Kokoro'), isNull);
    });

    test('配对 EPUB 的字幕书卡删除（deleteSrtShelfBook）同样清封面', () async {
      await db.insertEpubBook(bookRow('Paired'));
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'srt/paired',
          title: 'Paired',
          srtPath: '/tmp/paired.srt',
          importedAt: 0,
          bookKey: const Value<String>('Paired'),
        ),
      );
      final SrtBook paired = (await SrtBookRepository(
        db,
      ).findByUid('srt/paired'))!;
      final File cover = writeOverrideCover('Paired');

      final DeleteBookResult r = await ReaderFushiSource.instance
          .deleteSrtShelfBook(db: db, book: paired, appModel: app);
      expect(r.deleted, isTrue);
      expect(cover.existsSync(), isFalse);
    });

    test('Kavita「移除下载」走生产删书原语，也清封面', () async {
      await db.insertEpubBook(
        bookRow(
          'KavitaBook',
          sourceMetadata: const KavitaBookBinding(
            serverConfigId: 'srv',
            seriesId: 1,
            volumeId: 2,
            chapterId: 3,
            libraryId: 4,
            cachedOnly: false,
          ).encode(),
        ),
      );
      final File cover = writeOverrideCover('KavitaBook');

      final KavitaLocalRemoval outcome = await KavitaBookService(
        db: db,
        appModel: app,
      ).removeDownload('KavitaBook');

      expect(outcome, KavitaLocalRemoval.removed);
      expect(await db.getEpubBook('KavitaBook'), isNull);
      expect(cover.existsSync(), isFalse);
      expect(recorder.vacuumCount, 1, reason: '单本移除下载照旧回收一次');
    });

    test('没给 appModel 的 Kavita 服务实例拒绝删书（不再静默漏清封面）', () async {
      await db.insertEpubBook(
        bookRow(
          'Bound',
          sourceMetadata: const KavitaBookBinding(
            serverConfigId: 'srv',
            seriesId: 1,
            volumeId: 2,
            chapterId: 3,
            libraryId: 4,
            cachedOnly: false,
          ).encode(),
        ),
      );
      await expectLater(
        KavitaBookService(db: db).removeDownload('Bound'),
        throwsStateError,
      );
      expect(await db.getEpubBook('Bound'), isNotNull);
    });
  });

  group('BUG-4907 批删只回收一次数据库空间', () {
    test('单删默认照旧 VACUUM 一次', () async {
      await db.insertEpubBook(bookRow('One'));
      await ReaderFushiSource.instance.deleteBook(
        db: db,
        bookKey: 'One',
        appModel: app,
      );
      expect(recorder.vacuumCount, 1);
    });

    test('compactDatabase:false 逐本不回收，批末回收一次', () async {
      for (final String k in <String>['A', 'B', 'C', 'D', 'E']) {
        await db.insertEpubBook(bookRow(k));
      }
      for (final String k in <String>['A', 'B', 'C', 'D', 'E']) {
        final DeleteBookResult r = await ReaderFushiSource.instance.deleteBook(
          db: db,
          bookKey: k,
          appModel: app,
          compactDatabase: false,
        );
        expect(r.deleted, isTrue);
      }
      expect(recorder.vacuumCount, 0);

      await ReaderFushiSource.compactAfterBookDeleteBestEffort(db);
      expect(recorder.vacuumCount, 1);
      expect(recorder.customStatements.last, 'PRAGMA wal_checkpoint(TRUNCATE)');
    });
  });

  group('BUG-4908 同步删除墓碑写入失败留痕', () {
    test('墓碑写失败：书照样删掉，ErrorLogService 有一条记录', () async {
      await ErrorLogService.instance.clear();
      await db.insertEpubBook(bookRow('Synced'));
      recorder.failTombstoneInsert = true;

      final DeleteBookResult r = await ReaderFushiSource.instance.deleteBook(
        db: db,
        bookKey: 'Synced',
        appModel: app,
        scope: DeleteScope.syncEverywhere,
      );

      expect(r.deleted, isTrue, reason: '记账失败不翻转删除结果');
      expect(await db.getEpubBook('Synced'), isNull);
      expect(
        ErrorLogService.instance.entries.map((ErrorLogEntry e) => e.source),
        contains('ReaderFushiSource.deleteBook.syncTombstone'),
      );
    });
  });
}
