import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/pages/implementations/android_storage_move_prompt.dart'
    show shouldShowAndroidStorageMovePrompt;
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        canClearStaleAndroidMigrationTarget,
        clearStaleAndroidMigrationTargetIfSafe;

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

  group('反馈 RCv76PPoiJ：书库位置锚点多进程安全 + 磁盘对账', () {
    const String internal = AppPaths.androidDocumentsLocationInternal;
    const String external = AppPaths.androidDocumentsLocationExternal;

    test('锚定的根是空的、另一个根有书 → 以磁盘为准改正锚点', () {
      expect(
        AppPaths.reconcileAndroidDocumentsLocation(
          anchored: internal,
          anchoredHasLibrary: false,
          otherHasLibrary: true,
        ),
        external,
        reason: '锚点被冲回 internal，但书全在外部：必须回到外部，而不是对着空根',
      );
      expect(
        AppPaths.reconcileAndroidDocumentsLocation(
          anchored: external,
          anchoredHasLibrary: false,
          otherHasLibrary: true,
        ),
        internal,
      );
    });

    test('锚定的根有书 / 两边都空 → 沿用锚点', () {
      for (final (bool, bool) c in <(bool, bool)>[
        (true, true),
        (true, false),
        (false, false),
      ]) {
        expect(
          AppPaths.reconcileAndroidDocumentsLocation(
            anchored: external,
            anchoredHasLibrary: c.$1,
            otherHasLibrary: c.$2,
          ),
          external,
          reason: '$c：迁移中断（两边都有）与全新安装（两边都空）都不改锚点',
        );
      }
    });

    group('磁盘探测与纠偏', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_anchor_'));
      tearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      test(
        'hasLibraryFiles 忽略空目录与启动占位 (.nomedia / fushiExport / 工作目录)',
        () async {
          Directory(
            p.join(tmp.path, 'fushi_books', 'empty', 'deeper'),
          ).createSync(recursive: true);
          Directory(p.join(tmp.path, 'thumbnails')).createSync(recursive: true);
          Directory(
            p.join(tmp.path, 'dictionaryResources'),
          ).createSync(recursive: true);
          File(p.join(tmp.path, 'not_owned', 'x.txt'))
            ..createSync(recursive: true)
            ..writeAsStringSync('x');
          // 启动期在 Android 上必然建出 fushiExport/.nomedia，不应被误判为已有书库。
          File(p.join(tmp.path, 'fushiExport', '.nomedia'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(const <int>[]);
          File(p.join(tmp.path, 'hibikiExport', '.nomedia'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(const <int>[]);
          File(p.join(tmp.path, 'thumbnails', '.nomedia'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(const <int>[]);
          File(p.join(tmp.path, 'fushiExport', 'temp.jpg'))
            ..createSync(recursive: true)
            ..writeAsStringSync('tmp');
          File(p.join(tmp.path, 'dictionaryImportWorkingDirectory', 'tmp.bin'))
            ..createSync(recursive: true)
            ..writeAsStringSync('tmp');

          expect(await AppPaths.hasLibraryFiles(tmp, onTimeout: true), isFalse);

          File(
            p.join(tmp.path, 'fushi_books', 'empty', 'deeper', 'c.jpg'),
          ).writeAsStringSync('jpg');
          expect(await AppPaths.hasLibraryFiles(tmp, onTimeout: false), isTrue);
        },
      );

      test(
        '真机现场：external 仅有 fushiExport/.nomedia 与空运行目录、书库仍在 internal → 纠回 internal',
        () async {
          final Directory platformDocs = Directory(
            p.join(tmp.path, 'data', 'app_flutter'),
          )..createSync(recursive: true);
          final Directory extDocs = Directory(
            p.join(
              tmp.path,
              'sdcard',
              'Android',
              'data',
              'pkg',
              'files',
              'data',
            ),
          )..createSync(recursive: true);
          File(p.join(extDocs.path, 'fushiExport', '.nomedia'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(const <int>[]);
          for (final String dir in <String>[
            'thumbnails',
            'dictionaryResources',
            'dictionaryImportWorkingDirectory',
          ]) {
            Directory(p.join(extDocs.path, dir)).createSync(recursive: true);
          }
          File(p.join(platformDocs.path, 'fushi_books', 'norway', 'cover.jpg'))
            ..createSync(recursive: true)
            ..writeAsStringSync('jpg');

          final List<String> corrections = <String>[];
          final AndroidLibraryAnchor resolved =
              await AppPaths.reconcileAndroidLibraryAnchorWithDisk(
                anchored: const AndroidLibraryAnchor(location: external),
                defaultFlatLayout: true,
                defaultContainer: 'Fushi',
                platformDocuments: platformDocs,
                externalDocuments: extDocs,
                corrections: corrections,
              );

          expect(resolved.location, internal);
          expect(corrections, hasLength(1));
        },
      );

      test(
        '跨内部布局兜底：锚 external（空）且默认 Fushi/data 空，真书在 Hibiki/data 或 flat → 纠回对应内部布局',
        () async {
          final Directory platformDocs = Directory(
            p.join(tmp.path, 'data', 'app_flutter'),
          )..createSync(recursive: true);
          final Directory extDocs = Directory(
            p.join(
              tmp.path,
              'sdcard',
              'Android',
              'data',
              'pkg',
              'files',
              'data',
            ),
          )..createSync(recursive: true);
          File(p.join(extDocs.path, 'fushiExport', '.nomedia'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(const <int>[]);
          Directory(
            p.join(platformDocs.path, 'Fushi', 'data'),
          ).createSync(recursive: true);
          File(
              p.join(
                platformDocs.path,
                'Hibiki',
                'data',
                'audiobooks',
                'bk',
                'a.mp3',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsBytesSync(<int>[1, 2]);

          final List<String> corrections = <String>[];
          final AndroidLibraryAnchor resolved =
              await AppPaths.reconcileAndroidLibraryAnchorWithDisk(
                anchored: const AndroidLibraryAnchor(location: external),
                defaultFlatLayout: false,
                defaultContainer: 'Fushi',
                platformDocuments: platformDocs,
                externalDocuments: extDocs,
                corrections: corrections,
              );

          expect(
            resolved,
            const AndroidLibraryAnchor(
              location: internal,
              layout: AppPaths.documentsLayoutNested,
              container: 'Hibiki',
            ),
          );
          expect(corrections, hasLength(1));
        },
      );

      test('反向场景：internal 只有 .nomedia、书全在 external → 纠回 external', () async {
        final Directory platformDocs = Directory(
          p.join(tmp.path, 'data', 'app_flutter'),
        )..createSync(recursive: true);
        final Directory extDocs = Directory(
          p.join(tmp.path, 'sdcard', 'Android', 'data', 'pkg', 'files', 'data'),
        )..createSync(recursive: true);
        File(p.join(platformDocs.path, 'fushiExport', '.nomedia'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(const <int>[]);
        File(p.join(extDocs.path, 'fushi_books', 'norway', 'cover.jpg'))
          ..createSync(recursive: true)
          ..writeAsStringSync('jpg');

        final List<String> corrections = <String>[];
        final AndroidLibraryAnchor resolved =
            await AppPaths.reconcileAndroidLibraryAnchorWithDisk(
              anchored: const AndroidLibraryAnchor(location: internal),
              defaultFlatLayout: true,
              defaultContainer: 'Fushi',
              platformDocuments: platformDocs,
              externalDocuments: extDocs,
              corrections: corrections,
            );

        expect(resolved.location, external);
        expect(corrections, hasLength(1));
      });

      test('全新安装（两侧均无真书库文件，仅有 .nomedia）→ 保持原锚点不变', () async {
        final Directory platformDocs = Directory(
          p.join(tmp.path, 'data', 'app_flutter'),
        )..createSync(recursive: true);
        final Directory extDocs = Directory(
          p.join(tmp.path, 'sdcard', 'Android', 'data', 'pkg', 'files', 'data'),
        )..createSync(recursive: true);
        File(p.join(extDocs.path, 'fushiExport', '.nomedia'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(const <int>[]);

        final List<String> corrections = <String>[];
        final AndroidLibraryAnchor resolved =
            await AppPaths.reconcileAndroidLibraryAnchorWithDisk(
              anchored: const AndroidLibraryAnchor(location: external),
              defaultFlatLayout: false,
              defaultContainer: 'Fushi',
              platformDocuments: platformDocs,
              externalDocuments: extDocs,
              corrections: corrections,
            );

        expect(resolved, const AndroidLibraryAnchor(location: external));
        expect(corrections, isEmpty);
      });

      test('锚点文件原子写、读回一致；坏内容按不存在处理', () async {
        expect(await AppPaths.readAndroidLibraryAnchor(tmp), isNull);
        const AndroidLibraryAnchor anchor = AndroidLibraryAnchor(
          location: internal,
          layout: AppPaths.documentsLayoutNested,
          container: 'Hibiki',
        );
        await AppPaths.writeAndroidLibraryAnchor(tmp, anchor);
        expect(await AppPaths.readAndroidLibraryAnchor(tmp), anchor);
        expect(
          tmp.listSync().whereType<File>().map((File f) => p.basename(f.path)),
          <String>[AppPaths.androidLibraryAnchorFileName],
          reason: '临时文件不留残渣',
        );

        File(
          p.join(tmp.path, AppPaths.androidLibraryAnchorFileName),
        ).writeAsStringSync('{"location":"sdcard"}');
        expect(await AppPaths.readAndroidLibraryAnchor(tmp), isNull);
      });
    });

    group('迁移目标清理保护（防锚点错位时误删活书库）', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_clr_'));
      tearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      test('canClearStaleAndroidMigrationTarget 纯判据', () {
        expect(
          canClearStaleAndroidMigrationTarget(
            oldHasLibrary: false,
            newHasLibrary: true,
          ),
          isFalse,
        );
        expect(
          canClearStaleAndroidMigrationTarget(
            oldHasLibrary: true,
            newHasLibrary: true,
          ),
          isTrue,
        );
        expect(
          canClearStaleAndroidMigrationTarget(
            oldHasLibrary: false,
            newHasLibrary: false,
          ),
          isTrue,
        );
      });

      test('源根仅含 .nomedia 而目标根有真书库文件 → 拒绝清理且完整保留目标文件', () async {
        final Directory oldDocs = Directory(p.join(tmp.path, 'ext', 'data'))
          ..createSync(recursive: true);
        final Directory newDocs = Directory(
          p.join(tmp.path, 'internal', 'Fushi', 'data'),
        )..createSync(recursive: true);
        File(p.join(oldDocs.path, 'fushiExport', '.nomedia'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(const <int>[]);
        final File liveBook =
            File(p.join(newDocs.path, 'fushi_books', 'norway', 'cover.jpg'))
              ..createSync(recursive: true)
              ..writeAsStringSync('jpg');

        final bool cleared = await clearStaleAndroidMigrationTargetIfSafe(
          oldDocs: oldDocs,
          newDocs: newDocs,
        );

        expect(cleared, isFalse);
        expect(liveBook.existsSync(), isTrue, reason: '绝不误删活书库');
      });

      test('源根也有真书库（迁移中断重试）或目标仅有空目录/.nomedia → 允许清理陈旧目标', () async {
        final Directory oldDocs = Directory(p.join(tmp.path, 'old'))
          ..createSync(recursive: true);
        final Directory newDocs = Directory(p.join(tmp.path, 'new'))
          ..createSync(recursive: true);
        File(p.join(oldDocs.path, 'fushi_books', 'a', 'c.jpg'))
          ..createSync(recursive: true)
          ..writeAsStringSync('old');
        final File halfCopied =
            File(p.join(newDocs.path, 'fushi_books', 'a', 'c.jpg'))
              ..createSync(recursive: true)
              ..writeAsStringSync('half');

        expect(
          await clearStaleAndroidMigrationTargetIfSafe(
            oldDocs: oldDocs,
            newDocs: newDocs,
          ),
          isTrue,
        );
        expect(halfCopied.existsSync(), isFalse);
        expect(newDocs.existsSync(), isFalse);

        final Directory emptyOld = Directory(p.join(tmp.path, 'empty_old'))
          ..createSync(recursive: true);
        final Directory nomediaTarget = Directory(
          p.join(tmp.path, 'nomedia_target'),
        )..createSync(recursive: true);
        File(p.join(nomediaTarget.path, 'fushiExport', '.nomedia'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(const <int>[]);

        expect(
          await clearStaleAndroidMigrationTargetIfSafe(
            oldDocs: emptyOld,
            newDocs: nomediaTarget,
          ),
          isTrue,
        );
        expect(nomediaTarget.existsSync(), isFalse);
      });
    });

    test('AndroidLibraryAnchor 编解码', () {
      expect(
        AndroidLibraryAnchor.tryParse(
          const AndroidLibraryAnchor(
            location: external,
            layout: AppPaths.documentsLayoutNested,
            container: 'Fushi',
          ).encode(),
        ),
        const AndroidLibraryAnchor(
          location: external,
          layout: AppPaths.documentsLayoutNested,
          container: 'Fushi',
        ),
      );
      expect(AndroidLibraryAnchor.tryParse('not json'), isNull);
      expect(
        AndroidLibraryAnchor.tryParse(
          '{"location":"internal","layout":"x","container":"y"}',
        ),
        const AndroidLibraryAnchor(location: internal),
        reason: '布局或容器是垃圾值时当没给',
      );
    });

    test('守卫：位置锚点不再写进 SharedPreferences（多进程会被旧副本整份覆盖）', () {
      final RegExp write = RegExp(
        r'set(String|Bool)\(\s*AppPaths\.androidDocumentsLocationPrefKey|'
        r'set(String|Bool)\(\s*androidDocumentsLocationPrefKey',
      );
      final List<String> offenders = <String>[
        for (final FileSystemEntity e in Directory(
          'lib',
        ).listSync(recursive: true))
          if (e is File &&
              e.path.endsWith('.dart') &&
              write.hasMatch(e.readAsStringSync()))
            e.path,
      ];
      expect(offenders, isEmpty);
    });
  });
}
