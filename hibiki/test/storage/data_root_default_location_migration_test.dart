import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';

/// BUG-1188：「选目录」迁移到不了新装形态 —— 目标解析归一化 + 端到端布局守卫。
///
/// 修前实测（真 `DataRootMigrator.migrate()`）：老安装照 BUG-1115 文档指引选
/// `<Documents>\Hibiki`，产出的是 `Hibiki\documents` + `Hibiki\support`，并且 `fushi.db`
/// 被一起搬进文档目录；而**全新安装**是 `<Documents>\Hibiki\data` + 平台固定 support 根。
/// 同一个物理位置有两种持久化表达、两种磁盘布局，用户整理完永远回不到新装形态。
///
/// 修后：挑中默认位置（`<Documents>\Hibiki` 或 `<Documents>\Hibiki\data`）时目标被归一化
/// 成「与全新安装同形」——内容落 `<Documents>\Hibiki\data`、DB 留在平台固定落点、提交清掉
/// `data_root` 并把 `documents_layout` 锚成 nested。挑别的目录时行为逐字节不变。
void main() {
  late Directory tmp;
  late Directory platformDocuments;
  late Directory platformSupport;
  late String defaultDocsRoot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hibiki_default_loc_');
    platformDocuments = Directory(p.join(tmp.path, 'Documents'))
      ..createSync(recursive: true);
    platformSupport =
        Directory(p.join(tmp.path, 'AppData', 'Roaming', 'app.fushi.reader'))
          ..createSync(recursive: true);
    // 本文件全部用例模拟**存量 Hibiki 安装**（BUG-1188 归一化路径），容器锚
    // 固定 Hibiki（生产由 _ensureDocumentsContainerDecided 启动期判定）。
    AppPaths.debugSetDocumentsContainer('Hibiki');
    defaultDocsRoot = p.joinAll(<String>[
      platformDocuments.path,
      ...AppPaths.defaultDocumentsChildSegments,
    ]);
  });

  tearDown(() {
    AppPaths.debugSetDocumentsContainer(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DataRootMigrationTarget resolve(String picked) =>
      resolveDataRootMigrationTarget(
        pickedRoot: picked,
        defaultDocumentsRoot: defaultDocsRoot,
        platformSupportRoot: platformSupport.path,
      );

  /// 在 [documentsRoot] 下铺白名单内容 + 用户自己的文件，在 [supportRoot] 下铺
  /// `fushi.db`（含指向 documents 根的绝对路径行）与 `shared_preferences.json`。
  Future<void> seed({
    required Directory documentsRoot,
    required Directory supportRoot,
    bool withPrefsFile = true,
  }) async {
    File(p.join(documentsRoot.path, 'hoshi_books', 'Bk', 'a.html'))
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    File(p.join(documentsRoot.path, 'audiobooks', 'Bk', 'a.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    File(p.join(documentsRoot.path, 'video_covers', 'v.jpg'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[4, 5]);
    if (withPrefsFile) {
      File(p.join(supportRoot.path, 'shared_preferences.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"flutter.documents_layout":"flat"}');
    }
    File(p.join(supportRoot.path, 'local_audio_1.db'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[9]);

    final FushiDatabase db = FushiDatabase(supportRoot.path);
    try {
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: p.join(documentsRoot.path, 'hoshi_books', 'Bk', 'o.epub'),
        extractDir: p.join(documentsRoot.path, 'hoshi_books', 'Bk'),
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
        coverPath:
            Value(p.join(documentsRoot.path, 'hoshi_books', 'Bk', 'c.jpg')),
      ));
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/Bk',
        title: 'Video Bk',
        videoPath: p.join('E:', 'anime', 'Bk.mkv'),
        coverPath: Value(p.join(documentsRoot.path, 'video_covers', 'v.jpg')),
      ));
      await db.setPref(
        'local_audio_dbs',
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'path': p.join(supportRoot.path, 'local_audio_1.db'),
            'displayName': 'L1',
            'enabled': true,
          }
        ]),
      );
    } finally {
      await db.close();
    }
  }

  Future<Map<String, String?>> dbSnapshot(String supportDir) async {
    final FushiDatabase db = FushiDatabase(supportDir);
    try {
      final EpubBookRow b = (await db.getAllEpubBooks()).single;
      final VideoBookRow v = (await db.allVideoBooks()).single;
      final Map<String, String> prefs = await db.getAllPrefs();
      return <String, String?>{
        'epubPath': b.epubPath,
        'extractDir': b.extractDir,
        'coverPath': b.coverPath,
        'videoPath': v.videoPath,
        'videoCover': v.coverPath,
        'localAudioDbs': prefs['local_audio_dbs'],
      };
    } finally {
      await db.close();
    }
  }

  group('BUG-1188 ①：目标解析归一化', () {
    test('挑 Hibiki 伞目录 → 默认位置（内容落 Hibiki/data、DB 留平台固定落点）', () {
      final DataRootMigrationTarget t =
          resolve(p.join(platformDocuments.path, 'Hibiki'));
      expect(t.isDefaultLocation, isTrue);
      expect(t.documentsRoot.path, equals(defaultDocsRoot));
      expect(t.supportRoot.path, equals(platformSupport.path));
      expect(t.dataRootPrefValue, isNull,
          reason: '默认位置不写 data_root——写了就又变成"自定义根"这种第二种表达');
    });

    test('挑默认 documents 根本身 → 同一个默认位置目标', () {
      final DataRootMigrationTarget t = resolve(defaultDocsRoot);
      expect(t.isDefaultLocation, isTrue);
      expect(t.documentsRoot.path, equals(defaultDocsRoot));
      expect(t.supportRoot.path, equals(platformSupport.path));
    });

    test('挑别的目录 → 自定义根，派生 documents/support（行为逐字节不变）', () {
      final String picked = p.join(tmp.path, 'Elsewhere');
      final DataRootMigrationTarget t = resolve(picked);
      expect(t.isDefaultLocation, isFalse);
      expect(t.dataRootPrefValue, equals(picked));
      final (Directory docs, Directory support) =
          AppPaths.rootsForDataRoot(picked);
      expect(t.documentsRoot.path, equals(docs.path));
      expect(t.supportRoot.path, equals(support.path));
    });

    test('挑共享 Documents 根本身**不是**默认位置（伞目录恒比它深一层）', () {
      expect(AppPaths.defaultDocumentsChildSegments.length,
          greaterThanOrEqualTo(2),
          reason: '伞目录 = 默认 documents 根的父目录。默认段只有 1 段时伞目录就等于共享的平台 '
              'Documents，挑 Documents 根会被误判成"默认位置"而绕过自我迁移拒绝');
      expect(resolve(platformDocuments.path).isDefaultLocation, isFalse);
    });
  });

  group('BUG-1188 ②：扁平老安装照文档指引整理 → 与新装同形', () {
    test('产出 Hibiki/data + DB 留在平台固定落点，且不再出现 documents/support 两个目录', () async {
      await seed(
          documentsRoot: platformDocuments, supportRoot: platformSupport);
      final File userDoc = File(p.join(platformDocuments.path, 'essay.docx'))
        ..writeAsStringSync('user data');
      final File prefsFile =
          File(p.join(platformSupport.path, 'shared_preferences.json'));

      final DataRootMigrationTarget target =
          resolve(p.join(platformDocuments.path, 'Hibiki'));
      DataRootMigrationTarget? committed;
      final (Directory newDocs, Directory newSupport) =
          await const DataRootMigrator().migrate(DataRootMigrationRequest(
        oldDocumentsRoot: platformDocuments,
        oldSupportRoot: platformSupport,
        target: target,
        closeResources: () async {},
        commitLocation: (DataRootMigrationTarget t) async => committed = t,
        documentsTopLevelIncludeNames: AppPaths.fushiOwnedDocumentsEntries,
      ));

      // 与全新安装逐字节同形。
      expect(newDocs.path, equals(defaultDocsRoot));
      expect(newSupport.path, equals(platformSupport.path));
      // 布局分裂的两个症状都消失：Hibiki 伞下只有 data，DB 没被拖进文档目录。
      expect(
        Directory(p.join(platformDocuments.path, 'Hibiki'))
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList(),
        equals(<String>['data']),
      );
      expect(
          Directory(p.join(platformDocuments.path, 'Hibiki', 'documents'))
              .existsSync(),
          isFalse);
      expect(
          Directory(p.join(platformDocuments.path, 'Hibiki', 'support'))
              .existsSync(),
          isFalse);
      expect(
          File(p.join(platformSupport.path, 'fushi.db')).existsSync(), isTrue,
          reason: 'DB 必须留在平台固定落点（新装的落点），绝不搬进用户文档目录');
      expect(File(p.join(newDocs.path, 'fushi.db')).existsSync(), isFalse);
      // 内容真的搬过去了，用户自己的文件与 prefs 一字未动。
      expect(
          File(p.join(newDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(
          File(p.join(newDocs.path, 'audiobooks', 'Bk', 'a.mp3')).existsSync(),
          isTrue);
      expect(
          Directory(p.join(platformDocuments.path, 'audiobooks')).existsSync(),
          isFalse);
      expect(userDoc.readAsStringSync(), equals('user data'));
      expect(prefsFile.existsSync(), isTrue,
          reason: 'support 根未变 ⇒ 绝不能跑"删旧 support 只留 prefs"那一步');
      expect(
          File(p.join(platformSupport.path, 'local_audio_1.db')).existsSync(),
          isTrue);

      // 提交是"默认位置"语义（清 data_root + 锚 nested），不是写一个自定义根。
      expect(committed?.isDefaultLocation, isTrue);
      expect(committed?.dataRootPrefValue, isNull);

      // DB 内 documents 路径已 rebase；support 路径与外部视频路径原样不动。
      final Map<String, String?> snap = await dbSnapshot(newSupport.path);
      expect(snap['epubPath'], startsWith(newDocs.path));
      expect(snap['extractDir'], startsWith(newDocs.path));
      expect(snap['coverPath'], startsWith(newDocs.path));
      expect(snap['videoCover'], startsWith(newDocs.path));
      expect(snap['videoPath'], equals(p.join('E:', 'anime', 'Bk.mkv')));
      expect(
          (jsonDecode(snap['localAudioDbs']!) as List<dynamic>).single
              as Map<dynamic, dynamic>,
          containsPair(
              'path', p.join(platformSupport.path, 'local_audio_1.db')));
    });

    test('路径改写幂等：同一次默认位置改写连跑两次逐字节 no-op、不产出 Hibiki/data/Hibiki/data', () async {
      await seed(
          documentsRoot: platformDocuments, supportRoot: platformSupport);
      Future<void> runOnce() =>
          const DataRootMigrator().rebaseDatabasePathsForTesting(
            dbDirectory: platformSupport.path,
            oldDocumentsRoot: platformDocuments.path,
            newDocumentsRoot: defaultDocsRoot,
            // 默认位置：support 根不变。
            newSupportRoot: platformSupport.path,
            documentsScopeEntries: AppPaths.fushiOwnedDocumentsEntries,
          );

      await runOnce();
      final Map<String, String?> first = await dbSnapshot(platformSupport.path);
      expect(first['epubPath'], startsWith(defaultDocsRoot));

      await runOnce();
      final Map<String, String?> second =
          await dbSnapshot(platformSupport.path);
      expect(second, equals(first), reason: '第二遍必须是逐字节 no-op');

      final String doubled = p.joinAll(<String>[
        defaultDocsRoot,
        ...AppPaths.defaultDocumentsChildSegments,
      ]);
      for (final MapEntry<String, String?> e in second.entries) {
        expect(e.value ?? '', isNot(contains(doubled)), reason: e.key);
      }
    });
  });

  group('BUG-1188 ③：已按旧方式搬过的用户', () {
    /// 旧方式的产物：`<Documents>/Hibiki/documents` + `<Documents>/Hibiki/support`，
    /// `data_root = <Documents>/Hibiki`。这批用户必须**继续正常工作**（解析规则一字未改），
    /// 并且现在多了一条收敛回默认形态的路径。
    test('旧布局仍按 <root>/documents + <root>/support 解析（自定义根语义未变）', () {
      final String oldStyleRoot = p.join(platformDocuments.path, 'Hibiki2');
      final (Directory docs, Directory support) =
          AppPaths.rootsForDataRoot(oldStyleRoot);
      expect(docs.path, equals(p.join(oldStyleRoot, 'documents')));
      expect(support.path, equals(p.join(oldStyleRoot, 'support')));
    });

    test('再选一次 Hibiki → 归一化回默认位置：内容进 Hibiki/data、DB 搬回平台落点、prefs 保住', () async {
      final Directory oldRoot =
          Directory(p.join(platformDocuments.path, 'Hibiki'))
            ..createSync(recursive: true);
      final Directory oldDocs = Directory(p.join(oldRoot.path, 'documents'))
        ..createSync(recursive: true);
      final Directory oldSupport = Directory(p.join(oldRoot.path, 'support'))
        ..createSync(recursive: true);
      // 旧方式搬过之后，平台固定落点里只剩 prefs（迁移器刻意保住的那一份）。
      final File prefsFile =
          File(p.join(platformSupport.path, 'shared_preferences.json'))
            ..writeAsStringSync('{"flutter.data_root":"keep-me"}');
      await seed(
          documentsRoot: oldDocs,
          supportRoot: oldSupport,
          withPrefsFile: false);

      final DataRootMigrationTarget target = resolve(oldRoot.path);
      DataRootMigrationTarget? committed;
      final (Directory newDocs, Directory newSupport) =
          await const DataRootMigrator().migrate(DataRootMigrationRequest(
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        target: target,
        closeResources: () async {},
        commitLocation: (DataRootMigrationTarget t) async => committed = t,
        // 旧布局的 documents 根是 Hibiki 专属目录 → 整树搬移语义。
        documentsTopLevelIncludeNames: null,
      ));

      expect(newDocs.path, equals(defaultDocsRoot));
      expect(newSupport.path, equals(platformSupport.path));
      expect(committed?.isDefaultLocation, isTrue);
      // 内容与 DB 都到位，旧的 documents/support 两个目录消失。
      expect(
          File(p.join(newDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(
          File(p.join(platformSupport.path, 'fushi.db')).existsSync(), isTrue);
      expect(
          File(p.join(platformSupport.path, 'local_audio_1.db')).existsSync(),
          isTrue);
      expect(oldDocs.existsSync(), isFalse);
      expect(oldSupport.existsSync(), isFalse);
      // 合并搬入平台落点时，先于迁移就存在的 prefs 必须一字未动。
      expect(prefsFile.existsSync(), isTrue);
      expect(prefsFile.readAsStringSync(),
          equals('{"flutter.data_root":"keep-me"}'));

      final Map<String, String?> snap = await dbSnapshot(newSupport.path);
      expect(snap['epubPath'], startsWith(newDocs.path));
      expect(
          (jsonDecode(snap['localAudioDbs']!) as List<dynamic>).single
              as Map<dynamic, dynamic>,
          containsPair(
              'path', p.join(platformSupport.path, 'local_audio_1.db')));
    });

    test('提交失败回滚：平台固定落点不被整目录删掉，prefs 与旧根数据都还在', () async {
      final Directory oldRoot =
          Directory(p.join(platformDocuments.path, 'Hibiki'))
            ..createSync(recursive: true);
      final Directory oldDocs = Directory(p.join(oldRoot.path, 'documents'))
        ..createSync(recursive: true);
      final Directory oldSupport = Directory(p.join(oldRoot.path, 'support'))
        ..createSync(recursive: true);
      final File prefsFile =
          File(p.join(platformSupport.path, 'shared_preferences.json'))
            ..writeAsStringSync('{"flutter.data_root":"keep-me"}');
      await seed(
          documentsRoot: oldDocs,
          supportRoot: oldSupport,
          withPrefsFile: false);

      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          target: resolve(oldRoot.path),
          closeResources: () async {},
          commitLocation: (DataRootMigrationTarget t) async =>
              throw StateError('prefs unavailable'),
          documentsTopLevelIncludeNames: null,
        )),
        throwsA(isA<DataRootMigrationException>()),
      );

      expect(platformSupport.existsSync(), isTrue,
          reason: '目标 support 根是活着的平台固定落点，回滚绝不能整目录删掉它');
      expect(prefsFile.existsSync(), isTrue);
      expect(prefsFile.readAsStringSync(),
          equals('{"flutter.data_root":"keep-me"}'));
      // 数据搬回旧根，平台落点里不留本次搬进去的东西。
      expect(File(p.join(oldSupport.path, 'fushi.db')).existsSync(), isTrue);
      expect(
          File(p.join(oldDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(
          File(p.join(platformSupport.path, 'fushi.db')).existsSync(), isFalse);
      expect(Directory(defaultDocsRoot).existsSync(), isFalse);
    });
  });

  group('BUG-1188 ④：源码守卫', () {
    String readSource(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
      return f.readAsStringSync();
    }

    test('设置页必须经 resolveDataRootMigrationTarget 解析，不得把 picked 直接当 dataRoot',
        () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/data_root.part.dart');
      expect(src.contains('resolveDataRootMigrationTarget('), isTrue);
      expect(src.contains('AppPaths.defaultLocationDocumentsRoot()'), isTrue);
      expect(src.contains('getApplicationSupportDirectory()'), isTrue);
      expect(src.contains('AppPaths.rootsForDataRoot('), isFalse,
          reason: 'BUG-1188：目标派生只有一个入口（resolveDataRootMigrationTarget），'
              'UI 再自己派生一次就会与引擎的认知漂开');
    });

    test('默认位置提交必须同时锚 nested 布局并清掉 data_root', () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/data_root.part.dart');
      expect(src.contains('AppPaths.documentsLayoutNested'), isTrue,
          reason: '只清 data_root 不锚 nested，下次启动 documents 根解析回共享 Documents '
              '= 书库集体消失');
      expect(src.contains('sp.remove(AppPaths.dataRootPrefKey)'), isTrue,
          reason: '只锚 nested 不清 data_root，下次启动仍指向已搬空的旧自定义根');
    });

    test('support 根未变时绝不跑"删旧 support"，也不把它当自建子树清掉', () {
      final String src = readSource('lib/src/storage/data_root_migrator.dart');
      expect(src.contains('if (!supportUnchanged) {'), isTrue);
      expect(
        src.contains('if (!supportUnchanged && !mergeSupport) newSupport,'),
        isTrue,
        reason: 'BUG-1188：平台固定落点进了 _cleanupCreatedSubtrees 就会被整目录删掉，'
            '用户全部设置与 data_root 配置一起没',
      );
    });
  });
}
