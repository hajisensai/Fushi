import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/pages/implementations/android_storage_move_prompt.dart'
    show shouldShowAndroidStorageMovePrompt;
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';

/// Android 书库根：新装默认外部 app 专属目录（`Android/data/<包名>/files/data`），
/// 老安装锚定内部、一次性提示后走带进度的迁移（数据库始终留在内部）。
void main() {
  group('decideAndroidDocumentsLocation', () {
    test('全新安装（没有主库）→ 外部', () {
      expect(
        AppPaths.decideAndroidDocumentsLocation(
          stored: null,
          existingInstall: false,
        ),
        AppPaths.androidDocumentsLocationExternal,
      );
    });

    test('升级上来的老安装（已有主库）→ 内部，一个字节都不自动搬', () {
      expect(
        AppPaths.decideAndroidDocumentsLocation(
          stored: null,
          existingInstall: true,
        ),
        AppPaths.androidDocumentsLocationInternal,
      );
    });

    test('已有锚点一律沿用，不因主库存在与否翻转', () {
      expect(
        AppPaths.decideAndroidDocumentsLocation(
          stored: AppPaths.androidDocumentsLocationExternal,
          existingInstall: true,
        ),
        AppPaths.androidDocumentsLocationExternal,
      );
      expect(
        AppPaths.decideAndroidDocumentsLocation(
          stored: AppPaths.androidDocumentsLocationInternal,
          existingInstall: false,
        ),
        AppPaths.androidDocumentsLocationInternal,
      );
    });

    test('锚点是垃圾值时按安装状态重判', () {
      expect(
        AppPaths.decideAndroidDocumentsLocation(
          stored: 'sdcard',
          existingInstall: true,
        ),
        AppPaths.androidDocumentsLocationInternal,
      );
    });
  });

  group('shouldShowAndroidStorageMovePrompt', () {
    test('只有 Android + 书库在内部 + 没处理过才弹', () {
      expect(
        shouldShowAndroidStorageMovePrompt(
          isAndroid: true,
          documentsExternal: false,
          prompted: false,
        ),
        isTrue,
      );
      expect(
        shouldShowAndroidStorageMovePrompt(
          isAndroid: true,
          documentsExternal: true,
          prompted: false,
        ),
        isFalse,
        reason: '新装 / 已迁移：书库已经在外部',
      );
      expect(
        shouldShowAndroidStorageMovePrompt(
          isAndroid: true,
          documentsExternal: false,
          prompted: true,
        ),
        isFalse,
        reason: '弹过一次就不再弹，之后走设置',
      );
      expect(
        shouldShowAndroidStorageMovePrompt(
          isAndroid: false,
          documentsExternal: false,
          prompted: false,
        ),
        isFalse,
      );
    });
  });

  test('DataRootMigrationTarget.androidDocuments：不是默认位置、DB 不搬、带位置锚点', () {
    final DataRootMigrationTarget target =
        DataRootMigrationTarget.androidDocuments(
          documentsRoot: '/ext/files/data',
          supportRoot: '/data/user/0/pkg/files',
          location: AppPaths.androidDocumentsLocationExternal,
        );
    expect(target.isDefaultLocation, isFalse);
    expect(target.dataRootPrefValue, isNull);
    expect(target.supportRoot.path, '/data/user/0/pkg/files');
    expect(target.documentsRoot.path, '/ext/files/data');
    expect(
      target.androidDocumentsLocation,
      AppPaths.androidDocumentsLocationExternal,
    );
  });

  group('端到端迁移（真 DataRootMigrator，跨挂载点 = 逐文件复制）', () {
    late Directory tmp;
    late Directory appFlutter;
    late Directory support;
    late Directory externalFiles;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_android_docs_');
      appFlutter = Directory(p.join(tmp.path, 'data', 'app_flutter'))
        ..createSync(recursive: true);
      support = Directory(p.join(tmp.path, 'data', 'files'))
        ..createSync(recursive: true);
      externalFiles = Directory(p.join(tmp.path, 'sdcard', 'files'))
        ..createSync(recursive: true);
      // 内部 app_flutter → 外部 Android/data 跨挂载点，rename 必然 EXDEV。
      DataRootMigrator.debugForceCopyFallback = true;
    });

    tearDown(() {
      DataRootMigrator.debugForceCopyFallback = false;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<void> seedDb(Directory documentsRoot) async {
      final FushiDatabase db = FushiDatabase(support.path);
      try {
        await db.insertEpubBook(
          EpubBooksCompanion.insert(
            bookKey: 'Bk',
            title: 'Bk',
            epubPath: p.join(documentsRoot.path, 'fushi_books', 'Bk', 'o.epub'),
            extractDir: p.join(documentsRoot.path, 'fushi_books', 'Bk'),
            chapterCount: 1,
            chaptersJson: '["c"]',
            importedAt: 0,
            coverPath: Value(
              p.join(documentsRoot.path, 'fushi_books', 'Bk', 'c.jpg'),
            ),
          ),
        );
      } finally {
        await db.close();
      }
    }

    Future<String> extractDirInDb() async {
      final FushiDatabase db = FushiDatabase(support.path);
      try {
        return (await db.getAllEpubBooks()).single.extractDir;
      } finally {
        await db.close();
      }
    }

    test('老 flat 安装 → 外部：只搬白名单、DB 重基、库留在内部、插件文件不动', () async {
      File(p.join(appFlutter.path, 'fushi_books', 'Bk', 'a.html'))
        ..createSync(recursive: true)
        ..writeAsStringSync('hello');
      File(p.join(appFlutter.path, 'audiobooks', 'Bk', 'a.mp3'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);
      // 不属于书库的东西：别的插件写进 app_flutter 的文件。
      final File pluginFile = File(p.join(appFlutter.path, 'plugin_state.bin'))
        ..writeAsBytesSync(<int>[7]);
      await seedDb(appFlutter);

      final Directory newDocs = Directory(
        p.join(externalFiles.path, AppPaths.androidExternalDocumentsChild),
      );
      DataRootMigrationTarget? committed;
      final (
        Directory docs,
        Directory sup,
      ) = await const DataRootMigrator().migrate(
        DataRootMigrationRequest(
          oldDocumentsRoot: appFlutter,
          oldSupportRoot: support,
          target: DataRootMigrationTarget.androidDocuments(
            documentsRoot: newDocs.path,
            supportRoot: support.path,
            location: AppPaths.androidDocumentsLocationExternal,
          ),
          closeResources: () async {},
          commitLocation: (DataRootMigrationTarget t) async => committed = t,
          documentsTopLevelIncludeNames: AppPaths.fushiOwnedDocumentsEntries,
        ),
      );

      expect(docs.path, newDocs.path);
      expect(sup.path, support.path);
      expect(
        committed?.androidDocumentsLocation,
        AppPaths.androidDocumentsLocationExternal,
      );
      expect(
        File(p.join(newDocs.path, 'fushi_books', 'Bk', 'a.html')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(newDocs.path, 'audiobooks', 'Bk', 'a.mp3')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(appFlutter.path, 'fushi_books')).existsSync(),
        isFalse,
        reason: '提交后旧位置的白名单项被删掉',
      );
      expect(pluginFile.existsSync(), isTrue, reason: '共享根里非书库文件一律不碰');
      expect(appFlutter.existsSync(), isTrue, reason: '绝不删 app_flutter 本体');
      expect(
        File(p.join(support.path, fushiDatabaseFileName)).existsSync(),
        isTrue,
        reason: '数据库留在内部',
      );
      expect(await extractDirInDb(), p.join(newDocs.path, 'fushi_books', 'Bk'));
    });

    test('外部 → 内部 nested：整树搬回、DB 重基、外部书库根删掉', () async {
      final Directory extDocs = Directory(
        p.join(externalFiles.path, AppPaths.androidExternalDocumentsChild),
      );
      File(p.join(extDocs.path, 'fushi_books', 'Bk', 'a.html'))
        ..createSync(recursive: true)
        ..writeAsStringSync('hello');
      // 外部 files/ 下与书库并列的诊断目录不属于书库根，不能被卷走。
      final File log = File(p.join(externalFiles.path, 'logs', 'error_log.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      await seedDb(extDocs);

      final Directory newDocs = Directory(
        p.join(appFlutter.path, 'Fushi', 'data'),
      );
      DataRootMigrationTarget? committed;
      await const DataRootMigrator().migrate(
        DataRootMigrationRequest(
          oldDocumentsRoot: extDocs,
          oldSupportRoot: support,
          target: DataRootMigrationTarget.androidDocuments(
            documentsRoot: newDocs.path,
            supportRoot: support.path,
            location: AppPaths.androidDocumentsLocationInternal,
          ),
          closeResources: () async {},
          commitLocation: (DataRootMigrationTarget t) async => committed = t,
          documentsTopLevelIncludeNames: null,
        ),
      );

      expect(
        committed?.androidDocumentsLocation,
        AppPaths.androidDocumentsLocationInternal,
      );
      expect(
        File(p.join(newDocs.path, 'fushi_books', 'Bk', 'a.html')).existsSync(),
        isTrue,
      );
      expect(extDocs.existsSync(), isFalse);
      expect(log.existsSync(), isTrue);
      expect(await extractDirInDb(), p.join(newDocs.path, 'fushi_books', 'Bk'));
    });

    test('提交失败 → 整次回滚：书库回到内部、DB 路径不变', () async {
      File(p.join(appFlutter.path, 'fushi_books', 'Bk', 'a.html'))
        ..createSync(recursive: true)
        ..writeAsStringSync('hello');
      await seedDb(appFlutter);
      final Directory newDocs = Directory(
        p.join(externalFiles.path, AppPaths.androidExternalDocumentsChild),
      );

      await expectLater(
        const DataRootMigrator().migrate(
          DataRootMigrationRequest(
            oldDocumentsRoot: appFlutter,
            oldSupportRoot: support,
            target: DataRootMigrationTarget.androidDocuments(
              documentsRoot: newDocs.path,
              supportRoot: support.path,
              location: AppPaths.androidDocumentsLocationExternal,
            ),
            closeResources: () async {},
            commitLocation: (DataRootMigrationTarget t) async =>
                throw const DataRootMigrationException('pref write failed'),
            documentsTopLevelIncludeNames: AppPaths.fushiOwnedDocumentsEntries,
          ),
        ),
        throwsA(isA<DataRootMigrationException>()),
      );

      expect(
        File(
          p.join(appFlutter.path, 'fushi_books', 'Bk', 'a.html'),
        ).existsSync(),
        isTrue,
      );
      expect(
        await extractDirInDb(),
        p.join(appFlutter.path, 'fushi_books', 'Bk'),
      );
    });
  });
}
