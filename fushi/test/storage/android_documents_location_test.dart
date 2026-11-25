import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

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

    group('磁盘', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_anchor_'));
      tearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      test('hasLibraryFiles 只认白名单目录里的文件，空目录不算', () async {
        Directory(
          p.join(tmp.path, 'fushi_books', 'empty', 'deeper'),
        ).createSync(recursive: true);
        File(p.join(tmp.path, 'not_owned', 'x.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
        expect(await AppPaths.hasLibraryFiles(tmp, onTimeout: true), isFalse);

        File(
          p.join(tmp.path, 'fushi_books', 'empty', 'deeper', 'c.jpg'),
        ).writeAsStringSync('jpg');
        expect(await AppPaths.hasLibraryFiles(tmp, onTimeout: false), isTrue);
      });

      test('#4366 指出：冷启动自建的导出目录 .nomedia 与空运行目录不算书库', () async {
        // 小米真机现场：外部根里只有冷启动建出的空运行目录 + fushiExport/.nomedia。
        for (final String d in <String>[
          'browser',
          'thumbnails',
          'dictionaryResources',
          'webArchive',
        ]) {
          Directory(p.join(tmp.path, d)).createSync(recursive: true);
        }
        File(
          p.join(tmp.path, 'fushiExport', '.nomedia'),
        ).createSync(recursive: true);
        File(
          p.join(tmp.path, 'dictionaryImportWorkingDirectory', 'x.tmp'),
        ).createSync(recursive: true);
        File(
          p.join(tmp.path, 'audiobooks', '.nomedia'),
        ).createSync(recursive: true);
        expect(await AppPaths.hasLibraryFiles(tmp, onTimeout: true), isFalse);

        File(
          p.join(tmp.path, 'audiobooks', 'a', 'track01.mp3'),
        ).createSync(recursive: true);
        expect(await AppPaths.hasLibraryFiles(tmp, onTimeout: false), isTrue);
      });

      test('不计入证据的顶层项都是白名单成员（改名时不会悄悄失效）', () {
        expect(
          AppPaths.fushiOwnedDocumentsEntries.containsAll(
            AppPaths.libraryEvidenceIgnoredEntries,
          ),
          isTrue,
        );
      });

      test('已中招的安装（书库在内部、锚点指向外部空根）按磁盘自愈回内部', () async {
        final Directory ext = Directory(p.join(tmp.path, 'ext', 'data'))
          ..createSync(recursive: true);
        final Directory internalRoot = Directory(
          p.join(tmp.path, 'app_flutter', 'Fushi', 'data'),
        )..createSync(recursive: true);
        Directory(p.join(ext.path, 'thumbnails')).createSync();
        File(
          p.join(ext.path, 'fushiExport', '.nomedia'),
        ).createSync(recursive: true);
        File(
          p.join(internalRoot.path, 'fushiExport', '.nomedia'),
        ).createSync(recursive: true);
        File(
          p.join(internalRoot.path, 'fushi_books', 'norway', 'cover.jpg'),
        ).createSync(recursive: true);

        expect(
          AppPaths.reconcileAndroidDocumentsLocation(
            anchored: external,
            anchoredHasLibrary: await AppPaths.hasLibraryFiles(
              ext,
              onTimeout: true,
            ),
            otherHasLibrary: await AppPaths.hasLibraryFiles(
              internalRoot,
              onTimeout: false,
            ),
          ),
          internal,
          reason: '旧判据把外部的 fushiExport/.nomedia 当书库，锚点永远停在空的外部根',
        );
      });

      group('布局 / 容器锚点丢失（32552 用户复现）：对账探所有内部布局', () {
        late Directory appFlutter;
        late Directory ext;
        setUp(() {
          appFlutter = Directory(p.join(tmp.path, 'app_flutter'))
            ..createSync(recursive: true);
          ext = Directory(p.join(tmp.path, 'ext', 'data'))
            ..createSync(recursive: true);
          // 外部根：只有冷启动建出的空运行目录与 .nomedia。
          Directory(p.join(ext.path, 'thumbnails')).createSync();
          File(
            p.join(ext.path, 'fushiExport', '.nomedia'),
          ).createSync(recursive: true);
        });

        List<AndroidInternalLibraryCandidate> candidates({
          required String layout,
          required String container,
        }) => AppPaths.androidInternalLibraryCandidates(
          platformDocuments: appFlutter,
          configuredLayout: layout,
          configuredContainer: container,
        );

        test('候选：当前配置在前，其余布局去重排在后', () {
          final List<AndroidInternalLibraryCandidate> c = candidates(
            layout: AppPaths.documentsLayoutNested,
            container: AppPaths.documentsContainerHibiki,
          );
          expect(
            c.map((AndroidInternalLibraryCandidate x) => x.root.path),
            <String>[
              p.join(appFlutter.path, 'Hibiki', 'data'),
              appFlutter.path,
              p.join(appFlutter.path, 'Fushi', 'data'),
            ],
          );
        });

        test(
          '锚点指外部空根、布局被冲成 flat、书在 Hibiki/data → 改回内部 nested Hibiki',
          () async {
            File(
              p.join(
                appFlutter.path,
                'Hibiki',
                'data',
                'audiobooks',
                'a',
                'b.m4b',
              ),
            ).createSync(recursive: true);
            final List<AndroidInternalLibraryCandidate> c = candidates(
              layout: AppPaths.documentsLayoutFlat,
              container: AppPaths.documentsContainerFushi,
            );
            final AndroidLibraryReconciliation r =
                await AppPaths.reconcileAndroidLibraryRoots(
                  anchored: external,
                  external: ext,
                  internalCandidates: c,
                  supportRoot: tmp,
                );
            expect(r.location, internal);
            expect(r.internal.layout, AppPaths.documentsLayoutNested);
            expect(r.internal.container, AppPaths.documentsContainerHibiki);
            expect(
              r.notes.single,
              contains('Hibiki'),
              reason: '纠正要进诊断日志，带上各根的探测结论',
            );
          },
        );

        test('锚点指内部、当前配置的内部根是空的、书在另一种布局 → 改布局不改位置', () async {
          File(
            p.join(appFlutter.path, 'fushi_books', 'x', 'book.epub'),
          ).createSync(recursive: true);
          final AndroidLibraryReconciliation r =
              await AppPaths.reconcileAndroidLibraryRoots(
                anchored: internal,
                external: ext,
                internalCandidates: candidates(
                  layout: AppPaths.documentsLayoutNested,
                  container: AppPaths.documentsContainerFushi,
                ),
                supportRoot: tmp,
              );
          expect(r.location, internal);
          expect(r.internal.layout, AppPaths.documentsLayoutFlat);
          expect(r.internal.root.path, appFlutter.path);
        });

        test('哪里都没有书 → 沿用锚点，诊断里列出每个根的探测结论', () async {
          final AndroidLibraryReconciliation r =
              await AppPaths.reconcileAndroidLibraryRoots(
                anchored: external,
                external: ext,
                internalCandidates: candidates(
                  layout: AppPaths.documentsLayoutNested,
                  container: AppPaths.documentsContainerFushi,
                ),
                supportRoot: tmp,
              );
          expect(r.location, external);
          expect(r.strayRoot, isNull);
          expect(r.notes.single, contains('其余候选也都没有'));
          expect(r.notes.single, contains('=none'));
        });

        test('只有锚定的根有书 → 沿用，不写诊断', () async {
          File(
            p.join(ext.path, 'audiobooks', 'a', 'b.m4b'),
          ).createSync(recursive: true);
          final AndroidLibraryReconciliation r =
              await AppPaths.reconcileAndroidLibraryRoots(
                anchored: external,
                external: ext,
                internalCandidates: candidates(
                  layout: AppPaths.documentsLayoutNested,
                  container: AppPaths.documentsContainerFushi,
                ),
                supportRoot: tmp,
              );
          expect(r.location, external);
          expect(r.notes, isEmpty);
          expect(r.strayRoot, isNull);
        });

        test('锚定的根和另一种内部布局都有书、读不到主库 → 沿用锚点、不合并，诊断列出各根', () async {
          File(
            p.join(ext.path, 'audiobooks', 'a', 'b.m4b'),
          ).createSync(recursive: true);
          File(
            p.join(
              appFlutter.path,
              'Hibiki',
              'data',
              'fushi_books',
              'old.epub',
            ),
          ).createSync(recursive: true);
          final AndroidLibraryReconciliation r =
              await AppPaths.reconcileAndroidLibraryRoots(
                anchored: external,
                external: ext,
                internalCandidates: candidates(
                  layout: AppPaths.documentsLayoutNested,
                  container: AppPaths.documentsContainerFushi,
                ),
                supportRoot: tmp,
              );
          expect(r.location, external);
          expect(r.strayRoot, isNull);
          expect(r.notes.single, contains('主库读不到'));
        });

        group('错根运行期间自己写进了证据文件（锚定的根「有书」但不是真书库）', () {
          late Directory support;
          late Directory hibikiRoot;
          setUp(() {
            support = Directory(p.join(tmp.path, 'support'))..createSync();
            hibikiRoot = Directory(p.join(appFlutter.path, 'Hibiki', 'data'));
            // 真书库：nested Hibiki。
            File(
              p.join(hibikiRoot.path, 'fushi_books', 'k1', 'book.epub'),
            ).createSync(recursive: true);
            File(
              p.join(hibikiRoot.path, 'fushi_books', 'k2', 'book.epub'),
            ).createSync(recursive: true);
            // 布局被冲成 flat 后，app 以 app_flutter 为根跑过：自动备份写了进去。
            File(
              p.join(appFlutter.path, 'srs_backups', 'auto.zip'),
            ).createSync(recursive: true);
            final sqlite.Database db = sqlite.sqlite3.open(
              p.join(support.path, fushiDatabaseFileName),
            );
            db.execute('CREATE TABLE epub_books (extract_dir TEXT)');
            for (final String key in <String>['k1', 'k2']) {
              db.execute('INSERT INTO epub_books VALUES (?)', <Object?>[
                p.join(hibikiRoot.path, 'fushi_books', key),
              ]);
            }
            db.dispose();
          });

          test('锚点指内部 flat → 主库作证改回 nested Hibiki，flat 根交给散书合并', () async {
            final AndroidLibraryReconciliation r =
                await AppPaths.reconcileAndroidLibraryRoots(
                  anchored: internal,
                  external: ext,
                  internalCandidates: candidates(
                    layout: AppPaths.documentsLayoutFlat,
                    container: AppPaths.documentsContainerFushi,
                  ),
                  supportRoot: support,
                );
            expect(r.location, internal);
            expect(r.internal.layout, AppPaths.documentsLayoutNested);
            expect(r.internal.container, AppPaths.documentsContainerHibiki);
            expect(r.strayRoot?.path, appFlutter.path);
            expect(r.notes.single, contains('改为'));
          });

          test('外部存储不可用时内部各布局照样对账', () async {
            final AndroidLibraryReconciliation r =
                await AppPaths.reconcileAndroidLibraryRoots(
                  anchored: internal,
                  external: null,
                  internalCandidates: candidates(
                    layout: AppPaths.documentsLayoutFlat,
                    container: AppPaths.documentsContainerFushi,
                  ),
                  supportRoot: support,
                );
            expect(r.location, internal);
            expect(r.internal.root.path, hibikiRoot.path);
          });
        });
      });

      test('探测三态：有 / 没有 / 探不清（超时）各归各，探不清按调用方的保守值', () async {
        expect(await AppPaths.probeLibraryFiles(tmp), LibraryProbe.none);
        File(
          p.join(tmp.path, 'fushi_books', 'a', 'b.epub'),
        ).createSync(recursive: true);
        expect(await AppPaths.probeLibraryFiles(tmp), LibraryProbe.found);
        expect(
          await AppPaths.probeLibraryFiles(tmp, timeout: Duration.zero),
          LibraryProbe.unknown,
        );
        expect(
          await AppPaths.hasLibraryFiles(
            tmp,
            onTimeout: false,
            timeout: Duration.zero,
          ),
          isFalse,
        );
      });

      group('迁移前清理固定目标（#4366 指出）', () {
        late Directory source;
        late Directory target;
        setUp(() {
          source = Directory(p.join(tmp.path, 'src'))..createSync();
          target = Directory(p.join(tmp.path, 'dst'));
        });

        test('目标不存在 → 可清', () async {
          expect(
            await AppPaths.firstAndroidMigrationTargetOnlyFile(
              target: target,
              source: source,
            ),
            isNull,
          );
        });

        test('上次中断留下的半成品（源的子集）→ 可清', () async {
          for (final String rel in <String>[
            p.join('fushi_books', 'norway', 'cover.jpg'),
            p.join('audiobooks', 'a', 'track01.mp3'),
          ]) {
            File(p.join(source.path, rel))
              ..createSync(recursive: true)
              ..writeAsStringSync('x');
          }
          File(p.join(target.path, 'fushi_books', 'norway', 'cover.jpg'))
            ..createSync(recursive: true)
            ..writeAsStringSync('x');
          File(
            p.join(target.path, 'fushiExport', '.nomedia'),
          ).createSync(recursive: true);
          expect(
            await AppPaths.firstAndroidMigrationTargetOnlyFile(
              target: target,
              source: source,
            ),
            isNull,
          );
        });

        test('目标里有源没有的文件（锚点错指空根时目标就是真书库）→ 拒绝', () async {
          File(
            p.join(source.path, 'fushiExport', '.nomedia'),
          ).createSync(recursive: true);
          File(p.join(target.path, 'fushi_books', 'norway', 'cover.jpg'))
            ..createSync(recursive: true)
            ..writeAsStringSync('x');
          expect(
            await AppPaths.firstAndroidMigrationTargetOnlyFile(
              target: target,
              source: source,
            ),
            p.join('fushi_books', 'norway', 'cover.jpg'),
          );
        });
      });

      test('锚点文件原子写、读回一致；坏内容按不存在处理', () async {
        expect(await AppPaths.readAndroidLibraryAnchor(tmp), isNull);
        const AndroidLibraryAnchor anchor = AndroidLibraryAnchor(
          location: internal,
          layout: AppPaths.documentsLayoutNested,
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

    test('AndroidLibraryAnchor 编解码', () {
      expect(
        AndroidLibraryAnchor.tryParse(
          const AndroidLibraryAnchor(location: external).encode(),
        ),
        const AndroidLibraryAnchor(location: external),
      );
      expect(AndroidLibraryAnchor.tryParse('not json'), isNull);
      expect(
        AndroidLibraryAnchor.tryParse('{"location":"internal","layout":"x"}'),
        const AndroidLibraryAnchor(location: internal),
        reason: '布局是垃圾值时当没给',
      );
      const AndroidLibraryAnchor full = AndroidLibraryAnchor(
        location: internal,
        layout: AppPaths.documentsLayoutNested,
        container: AppPaths.documentsContainerHibiki,
      );
      expect(AndroidLibraryAnchor.tryParse(full.encode()), full);
      expect(
        AndroidLibraryAnchor.tryParse(
          '{"location":"internal","container":"Other"}',
        ),
        const AndroidLibraryAnchor(location: internal),
        reason: '容器名是垃圾值时当没给',
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
