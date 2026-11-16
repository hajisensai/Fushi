import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/import/import_inbox.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/sandbox_relocation.dart';

/// 拍板台 nLXhu0d7gV：iOS Documents 改作「文件」App 可见的导入收件箱前，存量书库要先搬出去，
/// 库里的绝对路径随后由 `SandboxRelocation` 重基——两步合起来就是用户升级那一刻的真实路径。
void main() {
  late Directory sandbox;
  late Directory documents;
  late Directory target;

  File touch(String path, [String body = 'x']) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(body);

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ios_vacate_');
    documents = Directory(p.join(sandbox.path, 'C', 'Documents'))
      ..createSync(recursive: true);
    target = AppPaths.iosDocumentsRootUnder(
      Directory(p.join(sandbox.path, 'C', 'Library')),
    );
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('vacateLegacyIosDocuments', () {
    test('nested：整个 <Documents>/Fushi/data 搬成新根，空容器伞删掉', () async {
      touch(
        p.join(documents.path, 'Fushi', 'data', 'fushi_books', 'b1', 'x.html'),
      );
      touch(
        p.join(
          documents.path,
          'Fushi',
          'data',
          'dictionaryResources',
          'd',
          'blobs.bin',
        ),
      );
      touch(p.join(documents.path, 'video_clips', 'clip.mp4'));

      final List<String> failures = await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: target,
        legacyFlat: false,
        containerName: 'Fushi',
      );

      expect(failures, isEmpty);
      expect(
        File(p.join(target.path, 'fushi_books', 'b1', 'x.html')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(target.path, 'dictionaryResources', 'd', 'blobs.bin'),
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(documents.path, 'Fushi')).existsSync(),
        isFalse,
        reason: '容器伞只剩空目录时删掉，「文件」App 里不留一个空的 Fushi 文件夹',
      );
      expect(
        File(p.join(documents.path, 'video_clips', 'clip.mp4')).existsSync(),
        isTrue,
        reason: '导出的剪辑是用户文件，留在 Documents 里正好能在「文件」App 里拿到',
      );
    });

    test('nested：容器伞里还有别的东西时只搬 data，伞留着', () async {
      touch(p.join(documents.path, 'Hibiki', 'data', 'audiobooks', 'a.mp3'));
      touch(p.join(documents.path, 'Hibiki', 'export.txt'));

      final List<String> failures = await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: target,
        legacyFlat: false,
        containerName: 'Hibiki',
      );

      expect(failures, isEmpty);
      expect(
        File(p.join(target.path, 'audiobooks', 'a.mp3')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(documents.path, 'Hibiki', 'export.txt')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(documents.path, 'Hibiki', 'data')).existsSync(),
        isFalse,
      );
    });

    test('flat：只搬白名单顶层项，其它东西一律不碰', () async {
      touch(p.join(documents.path, 'fushi_books', 'b1', 'x.html'));
      touch(p.join(documents.path, 'videos', 'v.mkv'));
      touch(p.join(documents.path, 'video_clips', 'clip.mp4'));
      touch(p.join(documents.path, 'notes.txt'));

      final List<String> failures = await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: target,
        legacyFlat: true,
        containerName: 'Fushi',
      );

      expect(failures, isEmpty);
      expect(
        File(p.join(target.path, 'fushi_books', 'b1', 'x.html')).existsSync(),
        isTrue,
      );
      expect(File(p.join(target.path, 'videos', 'v.mkv')).existsSync(), isTrue);
      expect(
        Directory(p.join(documents.path, 'fushi_books')).existsSync(),
        isFalse,
      );
      expect(Directory(p.join(documents.path, 'videos')).existsSync(), isFalse);
      expect(
        File(p.join(documents.path, 'video_clips', 'clip.mp4')).existsSync(),
        isTrue,
      );
      expect(File(p.join(documents.path, 'notes.txt')).existsSync(), isTrue);
    });

    test('上次搬到一半：目标里已有同名目录时合并，不丢已搬好的部分', () async {
      touch(p.join(target.path, 'fushi_books', 'b1', 'done.html'));
      touch(p.join(documents.path, 'fushi_books', 'b2', 'rest.html'));

      final List<String> failures = await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: target,
        legacyFlat: true,
        containerName: 'Fushi',
      );

      expect(failures, isEmpty);
      expect(
        File(
          p.join(target.path, 'fushi_books', 'b1', 'done.html'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(target.path, 'fushi_books', 'b2', 'rest.html'),
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(documents.path, 'fushi_books')).existsSync(),
        isFalse,
      );
    });

    test('全新安装（Documents 里什么都没有）：无事发生', () async {
      final List<String> failures = await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: target,
        legacyFlat: false,
        containerName: 'Fushi',
      );
      expect(failures, isEmpty);
      expect(target.existsSync(), isFalse);
    });

    test('目标落在 Documents 里 → 拒绝（那等于没搬）', () async {
      final List<String> failures = await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: Directory(p.join(documents.path, 'Fushi', 'data')),
        legacyFlat: false,
        containerName: 'Fushi',
      );
      expect(failures, isNotEmpty);
    });
  });

  group('vacateIosDocumentsWithLedger（只全扫一次，之后只重试失败项）', () {
    late File ledger;

    setUp(() {
      ledger = AppPaths.iosDocumentsVacateLedgerUnder(
        Directory(p.join(sandbox.path, 'C', 'Library')),
      );
    });

    Future<List<String>> run() => AppPaths.vacateIosDocumentsWithLedger(
      platformDocuments: documents,
      target: target,
      ledger: ledger,
      legacyFlat: () async => true,
      containerName: 'Fushi',
    );

    test('台账在 Library/Fushi 下：不在书库根里，也不在「文件」App 可见的 Documents 里', () {
      expect(p.isWithin(documents.path, ledger.path), isFalse);
      expect(p.isWithin(target.path, ledger.path), isFalse);
      expect(p.dirname(ledger.path), p.dirname(target.path));
    });

    test('第一次全量搬并写空台账；之后用户在「文件」App 里建的同名文件夹不再被收走', () async {
      touch(p.join(documents.path, 'videos', 'old.mkv'));

      expect(await run(), isEmpty);
      expect(ledger.existsSync(), isTrue);
      expect(ledger.readAsStringSync().trim(), isEmpty);
      expect(
        File(p.join(target.path, 'videos', 'old.mkv')).existsSync(),
        isTrue,
      );

      touch(p.join(documents.path, 'videos', 'mine.mkv'));
      touch(p.join(documents.path, 'browser', 'mine.txt'));
      expect(await run(), isEmpty);
      expect(
        File(p.join(documents.path, 'videos', 'mine.mkv')).existsSync(),
        isTrue,
        reason: '搬完之后 Documents 是用户的收件箱，同名文件夹是用户自己的',
      );
      expect(
        File(p.join(documents.path, 'browser', 'mine.txt')).existsSync(),
        isTrue,
      );
    });

    test('台账里记着上次失败的项：只重试它，白名单里的其它同名文件夹不碰', () async {
      ledger
        ..createSync(recursive: true)
        ..writeAsStringSync('fushi_books\n');
      touch(p.join(documents.path, 'fushi_books', 'b1', 'x.html'));
      touch(p.join(documents.path, 'videos', 'mine.mkv'));

      expect(await run(), isEmpty);
      expect(
        File(p.join(target.path, 'fushi_books', 'b1', 'x.html')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(documents.path, 'videos', 'mine.mkv')).existsSync(),
        isTrue,
      );
      expect(ledger.readAsStringSync().trim(), isEmpty);
    });

    test('nested 布局的失败项名是 <容器>/data，重试时按它找回', () async {
      final List<String> failed = <String>[];
      touch(p.join(documents.path, 'Fushi', 'data', 'fushi_books', 'b', 'x'));
      await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: target,
        legacyFlat: false,
        containerName: 'Fushi',
        onlyEntries: <String>{'videos'},
        failedEntries: failed,
      );
      expect(
        Directory(p.join(documents.path, 'Fushi', 'data')).existsSync(),
        isTrue,
        reason: 'onlyEntries 不含 Fushi/data 时 nested 书库不动',
      );
      await AppPaths.vacateLegacyIosDocuments(
        platformDocuments: documents,
        target: target,
        legacyFlat: false,
        containerName: 'Fushi',
        onlyEntries: <String>{'Fushi/data'},
        failedEntries: failed,
      );
      expect(failed, isEmpty);
      expect(
        File(p.join(target.path, 'fushi_books', 'b', 'x')).existsSync(),
        isTrue,
      );
    });
  });

  test('旧 Documents/metrickit 合并进诊断目录', () async {
    final Directory logs = Directory(
      p.join(sandbox.path, 'C', 'Support', 'logs'),
    )..createSync(recursive: true);
    touch(p.join(documents.path, 'metrickit', 'crash1.json'), '{}');
    touch(p.join(logs.path, 'metrickit', 'crash0.json'), '{}');

    final List<String> failures =
        await AppPaths.migrateLegacyMetricKitDirectory(
          from: documents,
          to: logs,
        );

    expect(failures, isEmpty);
    expect(
      File(p.join(logs.path, 'metrickit', 'crash0.json')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(logs.path, 'metrickit', 'crash1.json')).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(documents.path, 'metrickit')).existsSync(),
      isFalse,
    );
    expect(
      await AppPaths.migrateLegacyMetricKitDirectory(from: documents, to: logs),
      isEmpty,
      reason: '旧目录已不存在时什么都不做',
    );
  });

  test('收件箱子目录名与书库白名单大小写无关地互不相交（APFS 默认不分大小写）', () {
    final Set<String> owned = <String>{
      for (final String name in AppPaths.fushiOwnedDocumentsEntries)
        name.toLowerCase(),
    };
    for (final String folder in ImportInbox.kindFolderNames.values) {
      expect(owned, isNot(contains(folder.toLowerCase())), reason: folder);
    }
    expect(owned, contains('inbox_imports'));
  });

  group('升级端到端：搬出 Documents + 按台账重基库路径', () {
    late FushiDatabase db;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    Future<String> seedBook(String extractDir) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'book1',
          title: '言の葉の庭',
          epubPath: 'manga.json',
          extractDir: extractDir,
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return extractDir;
    }

    test('nested 安装：上次启动的台账指向 Documents/Fushi/data → 书回到新根', () async {
      final String oldRoot = p.join(documents.path, 'Fushi', 'data');
      final String staleDir = p.join(oldRoot, 'fushi_books', 'book1');
      touch(p.join(staleDir, 'manga.json'), '{}');
      await seedBook(staleDir);
      await db.setPref(SandboxRelocation.lastDocumentsRootPrefKey, oldRoot);

      expect(
        await AppPaths.vacateLegacyIosDocuments(
          platformDocuments: documents,
          target: target,
          legacyFlat: false,
          containerName: 'Fushi',
        ),
        isEmpty,
      );
      final SandboxRelocationOutcome outcome =
          await SandboxRelocation.reconcile(
            db: db,
            documentsRoot: target.path,
            supportRoot: p.join(sandbox.path, 'C', 'Support'),
          );

      expect(outcome.rebased, isTrue);
      expect(outcome.source, SandboxRelocationSource.ledger);
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(p.isWithin(target.path, row.extractDir), isTrue);
      expect(File(p.join(row.extractDir, 'manga.json')).existsSync(), isTrue);
    });

    test('flat 老安装、台账为空：靠磁盘证据反推旧根，照样重基', () async {
      final String staleDir = p.join(documents.path, 'fushi_books', 'book1');
      touch(p.join(staleDir, 'manga.json'), '{}');
      await seedBook(staleDir);

      expect(
        await AppPaths.vacateLegacyIosDocuments(
          platformDocuments: documents,
          target: target,
          legacyFlat: true,
          containerName: 'Fushi',
        ),
        isEmpty,
      );
      final SandboxRelocationOutcome outcome =
          await SandboxRelocation.reconcile(
            db: db,
            documentsRoot: target.path,
            supportRoot: p.join(sandbox.path, 'C', 'Support'),
          );

      expect(outcome.rebased, isTrue);
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(File(p.join(row.extractDir, 'manga.json')).existsSync(), isTrue);
    });
  });
}
