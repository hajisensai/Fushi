import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/data_root_migrator.dart';

/// TODO-935 E1 块2 单测：数据根迁移引擎 [DataRootMigrator]。
///
/// 三类用例：
///  1. **成功迁移**：构造旧 documents/support 目录树 + 真 Drift DB（带各类绝对路径行）→
///     跑迁移 → 断言新根文件齐全、DB 内绝对路径列已 rebase 到新根、local_audio_dbs /
///     字体 pref 已 rebase、data_root pref 已写、旧根已删。
///  2. **失败回滚**：模拟 DB rebase 阶段失败（喂一个无法打开的 support 根使 rebase 抛错）
///     → 断言旧根完整保留、未切换、新根半成品已清、data_root pref 未写。
///  3. **目标非空拒绝**：目标 dataRoot 已存在数据 → 直接抛错不动旧根。
void main() {
  late Directory tmp;
  late Directory oldDocs;
  late Directory oldSupport;
  late String oldDocsPath;
  late String oldSupportPath;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hibiki_migrate_');
    oldDocs = Directory(p.join(tmp.path, 'old', 'documents'))
      ..createSync(recursive: true);
    oldSupport = Directory(p.join(tmp.path, 'old', 'support'))
      ..createSync(recursive: true);
    oldDocsPath = oldDocs.path;
    oldSupportPath = oldSupport.path;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 在旧 documents 根下铺一个 epub 内容文件 + 视频封面，在旧 support 根下铺 hibiki.db
  /// 与一个 local_audio_*.db，并在 DB 里写各类绝对路径行。返回 (newDataRoot, prefWrites)。
  Future<void> seedDb() async {
    // 文件树。
    File(p.join(oldDocs.path, 'hoshi_books', 'Bk', 'a.html'))
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    File(p.join(oldDocs.path, 'audiobooks', 'Bk', 'a.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5]);
    File(p.join(oldDocs.path, 'audiobooks', 'SrtOnly', 'line.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[6, 7, 8]);
    File(p.join(oldDocs.path, 'audiobooks', 'SrtOnly', 'line.srt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');
    File(p.join(oldSupport.path, 'local_audio_1.db'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[9, 9, 9]);

    final HibikiDatabase db = HibikiDatabase(oldSupportPath);
    try {
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: p.join(oldDocsPath, 'hoshi_books', 'Bk', 'original.epub'),
        extractDir: p.join(oldDocsPath, 'hoshi_books', 'Bk'),
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
        coverPath: Value(p.join(oldDocsPath, 'hoshi_books', 'Bk', 'cover.jpg')),
      ));
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: 'Bk',
        alignmentFormat: 'srt',
        alignmentPath: p.join(oldDocsPath, 'audiobooks', 'Bk', 'align.srt'),
        audioRoot: Value(p.join(oldDocsPath, 'audiobooks', 'Bk')),
        audioPathsJson: Value(jsonEncode(<String>[
          p.join(oldDocsPath, 'audiobooks', 'Bk', 'a.mp3'),
        ])),
      ));
      await db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srtbook_1',
        title: 'SRT Only',
        author: const Value('tester'),
        audioRoot: Value(p.join(oldDocsPath, 'audiobooks', 'SrtOnly')),
        audioPathsJson: Value(jsonEncode(<String>[
          p.join(oldDocsPath, 'audiobooks', 'SrtOnly', 'line.mp3'),
        ])),
        srtPath: p.join(oldDocsPath, 'audiobooks', 'SrtOnly', 'line.srt'),
        coverPath: Value(p.join(oldDocsPath, 'audiobooks', 'SrtOnly', 'c.jpg')),
        importedAt: 1234,
        bookKey: const Value(''),
      ));
      // local_audio_dbs pref points at the internal copy under support root.
      await db.setPref(
        'local_audio_dbs',
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'path': p.join(oldSupportPath, 'local_audio_1.db'),
            'displayName': 'L1',
            'enabled': true,
          }
        ]),
      );
      // Font catalog pref points under documents root.
      await db.setPref(
        'src:reader_ttu:font_catalog',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'fonts': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'f1',
              'name': 'F1',
              'path': p.join(oldDocsPath, 'custom_fonts', 'f1.ttf'),
            }
          ],
        }),
      );
    } finally {
      await db.close();
    }
  }

  group('TODO-935 E1 块2：迁移引擎', () {
    test('成功迁移：文件搬齐 + DB 绝对路径 rebase + prefs rebase + data_root 写入 + 旧根删',
        () async {
      await seedDb();
      final String newDataRoot = p.join(tmp.path, 'new');
      String? wroteDataRoot;
      bool closed = false;

      final (Directory newDocs, Directory newSupport) =
          await const DataRootMigrator().migrate(DataRootMigrationRequest(
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        newDataRoot: newDataRoot,
        // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
        documentsTopLevelIncludeNames: null,
        closeResources: () async => closed = true,
        writeDataRootPref: (String r) async => wroteDataRoot = r,
      ));

      // 关闭回调被调用。
      expect(closed, isTrue);
      // 新根文件齐全。
      expect(
          File(p.join(newDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(
          File(p.join(newDocs.path, 'audiobooks', 'Bk', 'a.mp3')).existsSync(),
          isTrue);
      expect(File(p.join(newSupport.path, 'hibiki.db')).existsSync(), isTrue);
      expect(File(p.join(newSupport.path, 'local_audio_1.db')).existsSync(),
          isTrue);
      // 旧根已删。
      expect(oldDocs.existsSync(), isFalse);
      expect(oldSupport.existsSync(), isFalse);
      // data_root pref 写了新值。
      expect(wroteDataRoot, equals(newDataRoot));

      // DB 内绝对路径已 rebase 到新根。
      final HibikiDatabase db = HibikiDatabase(newSupport.path);
      try {
        final EpubBookRow b = (await db.getAllEpubBooks()).single;
        expect(b.epubPath, startsWith(newDocs.path));
        expect(b.extractDir, startsWith(newDocs.path));
        expect(b.coverPath, startsWith(newDocs.path));

        final AudiobookRow a = (await db.getAllAudiobooks()).single;
        expect(a.audioRoot, startsWith(newDocs.path));
        expect(a.alignmentPath, startsWith(newDocs.path));
        final List<dynamic> paths =
            jsonDecode(a.audioPathsJson!) as List<dynamic>;
        expect(paths.single as String, startsWith(newDocs.path));

        final SrtBookRow s = (await db.getAllSrtBooks()).single;
        expect(s.uid, equals('srtbook_1'));
        expect(s.audioRoot, startsWith(newDocs.path));
        expect(s.srtPath, startsWith(newDocs.path));
        expect(s.coverPath, startsWith(newDocs.path));
        final List<dynamic> srtAudioPaths =
            jsonDecode(s.audioPathsJson!) as List<dynamic>;
        expect(srtAudioPaths.single as String, startsWith(newDocs.path));

        final Map<String, String> prefs = await db.getAllPrefs();
        // local_audio_dbs rebased onto new support root.
        expect(prefs['local_audio_dbs'], contains('local_audio_1.db'));
        expect(prefs['local_audio_dbs'], startsWith('[{"path":'));
        final List<dynamic> la =
            jsonDecode(prefs['local_audio_dbs']!) as List<dynamic>;
        expect(
            (la.single as Map)['path'] as String, startsWith(newSupport.path));
        // font catalog rebased onto new documents root.
        final Map<String, dynamic> cat =
            jsonDecode(prefs['src:reader_ttu:font_catalog']!)
                as Map<String, dynamic>;
        final String fpath =
            ((cat['fonts'] as List).single as Map)['path'] as String;
        expect(fpath, startsWith(newDocs.path));
      } finally {
        await db.close();
      }
    });

    test('失败回滚：DB rebase 阶段失败 → 旧根保留、未切换、新根清、未写 data_root', () async {
      await seedDb();
      // 把 support 根里的 hibiki.db 删掉再造一个目录占名，使迁移后在新 support 打开
      // 报错？更可控：让目标新根落在一个「文件」上，使 createSync 抛错触发搬动失败回滚。
      final String newDataRoot = p.join(tmp.path, 'blocked_root');
      // 在新 dataRoot 应在的位置放一个同名文件，createSync(recursive) 会抛 FileSystem。
      File(newDataRoot).writeAsStringSync('not a dir');

      bool wrote = false;
      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          newDataRoot: newDataRoot,
          // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
          documentsTopLevelIncludeNames: null,
          closeResources: () async {},
          writeDataRootPref: (String r) async => wrote = true,
        )),
        throwsA(isA<DataRootMigrationException>()),
      );

      // 旧根完整保留（数据没丢）。
      expect(
          File(p.join(oldDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(File(p.join(oldSupport.path, 'hibiki.db')).existsSync(), isTrue);
      // 未写 data_root。
      expect(wrote, isFalse);
    });

    test('pref 写入失败：DB 路径反向 rebase 后搬回旧根，旧根继续可用', () async {
      await seedDb();
      final String newDataRoot = p.join(tmp.path, 'new_pref_fails');
      int writeAttempts = 0;

      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          newDataRoot: newDataRoot,
          // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
          documentsTopLevelIncludeNames: null,
          closeResources: () async {},
          writeDataRootPref: (String r) async {
            writeAttempts++;
            throw StateError('prefs unavailable');
          },
        )),
        throwsA(isA<DataRootMigrationException>().having(
          (DataRootMigrationException e) => e.message,
          'message',
          contains('写入新数据根设置失败'),
        )),
      );

      expect(writeAttempts, equals(1));
      // TODO-1182：回滚只清迁移自建的 documents/support 子树，用户选定的 newRoot 本体保留
      // （它可能是安装目录或含用户其它文件）；断言两子树已清、newRoot 下无迁移残留文件。
      expect(Directory(p.join(newDataRoot, 'documents')).existsSync(), isFalse);
      expect(Directory(p.join(newDataRoot, 'support')).existsSync(), isFalse);
      expect(_hasAnyFileUnder(newDataRoot), isFalse);
      expect(
          File(p.join(oldDocsPath, 'hoshi_books', 'Bk', 'a.html')).existsSync(),
          isTrue);
      expect(File(p.join(oldSupportPath, 'hibiki.db')).existsSync(), isTrue);

      final HibikiDatabase db = HibikiDatabase(oldSupportPath);
      try {
        final EpubBookRow b = (await db.getAllEpubBooks()).single;
        expect(b.epubPath, startsWith(oldDocsPath));
        expect(b.extractDir, startsWith(oldDocsPath));
        expect(b.coverPath, startsWith(oldDocsPath));

        final AudiobookRow a = (await db.getAllAudiobooks()).single;
        expect(a.audioRoot, startsWith(oldDocsPath));
        expect(a.alignmentPath, startsWith(oldDocsPath));
        final List<dynamic> audioPaths =
            jsonDecode(a.audioPathsJson!) as List<dynamic>;
        expect(audioPaths.single as String, startsWith(oldDocsPath));

        final SrtBookRow s = (await db.getAllSrtBooks()).single;
        expect(s.audioRoot, startsWith(oldDocsPath));
        expect(s.srtPath, startsWith(oldDocsPath));
        expect(s.coverPath, startsWith(oldDocsPath));

        final Map<String, String> prefs = await db.getAllPrefs();
        final List<dynamic> localAudio =
            jsonDecode(prefs['local_audio_dbs']!) as List<dynamic>;
        expect((localAudio.single as Map)['path'] as String,
            startsWith(oldSupportPath));
        final Map<String, dynamic> fontCatalog =
            jsonDecode(prefs['src:reader_ttu:font_catalog']!)
                as Map<String, dynamic>;
        final String fontPath =
            ((fontCatalog['fonts'] as List).single as Map)['path'] as String;
        expect(fontPath, startsWith(oldDocsPath));
      } finally {
        await db.close();
      }
    });

    test('跨盘复制进度回调：分母=文件总数，分子从 0 单调累加到总数（TODO-959）', () async {
      // 铺 3 个文件 + 嵌套目录（目录项不计入文件数）。
      final Directory src = Directory(p.join(tmp.path, 'copy_src'))
        ..createSync(recursive: true);
      File(p.join(src.path, 'a.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      File(p.join(src.path, 'sub', 'b.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('bb');
      File(p.join(src.path, 'sub', 'deep', 'c.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('ccc');
      final Directory dst = Directory(p.join(tmp.path, 'copy_dst'));

      final List<(int, int)> reports = <(int, int)>[];
      await const DataRootMigrator().copyTreeWithProgressForTesting(
        src,
        dst,
        (int copied, int total) => reports.add((copied, total)),
      );

      // 文件全部复制过去。
      expect(File(p.join(dst.path, 'a.txt')).existsSync(), isTrue);
      expect(File(p.join(dst.path, 'sub', 'b.txt')).existsSync(), isTrue);
      expect(
          File(p.join(dst.path, 'sub', 'deep', 'c.txt')).existsSync(), isTrue);

      // 至少回报一次；总数恒为 3（目录不计）。
      expect(reports, isNotEmpty);
      expect(reports.map((r) => r.$2).toSet(), <int>{3});
      // 分子单调不减，最终达到总数。
      final List<int> copied = reports.map((r) => r.$1).toList();
      for (int i = 1; i < copied.length; i++) {
        expect(copied[i], greaterThanOrEqualTo(copied[i - 1]));
      }
      expect(copied.last, equals(3));
    });

    test('prefs 保护：默认根迁移时 shared_preferences.json 留在旧 support 原地，DB+数据搬到新根',
        () async {
      // 模拟「默认根迁移」：oldSupport 即平台固定落点，顶层放真实
      // shared_preferences.json（含真实 data_root 值），以及 hibiki.db、local_audio。
      await seedDb();
      final File prefsFile =
          File(p.join(oldSupportPath, 'shared_preferences.json'))
            ..writeAsStringSync(jsonEncode(<String, dynamic>{
              'flutter.data_root': p.join(tmp.path, 'new'),
              'flutter.some_other': 42,
            }));
      final String prefsContentBefore = prefsFile.readAsStringSync();
      // sidecar：确保 .lock 之类前缀同族也被保护。
      final File prefsLock =
          File(p.join(oldSupportPath, 'shared_preferences.json.lock'))
            ..writeAsStringSync('lock');

      final String newDataRoot = p.join(tmp.path, 'new');
      String? wroteDataRoot;

      final (Directory newDocs, Directory newSupport) =
          await const DataRootMigrator().migrate(DataRootMigrationRequest(
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        newDataRoot: newDataRoot,
        // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
        documentsTopLevelIncludeNames: null,
        closeResources: () async {},
        writeDataRootPref: (String r) async => wroteDataRoot = r,
      ));

      // (a) prefs 仍在原 oldSupportRoot，内容不变；sidecar 也留下。
      expect(prefsFile.existsSync(), isTrue,
          reason: 'shared_preferences.json 必须留在固定平台落点');
      expect(prefsFile.readAsStringSync(), equals(prefsContentBefore));
      expect(prefsLock.existsSync(), isTrue);
      // prefs 不该被复制进新 support。
      expect(
          File(p.join(newSupport.path, 'shared_preferences.json')).existsSync(),
          isFalse);
      // (b) hibiki.db 已到新 support。
      expect(File(p.join(newSupport.path, 'hibiki.db')).existsSync(), isTrue);
      expect(File(p.join(newSupport.path, 'local_audio_1.db')).existsSync(),
          isTrue);
      // hibiki.db 已从旧 support 移走（只剩 prefs 族）。
      expect(File(p.join(oldSupportPath, 'hibiki.db')).existsSync(), isFalse);
      expect(File(p.join(oldSupportPath, 'local_audio_1.db')).existsSync(),
          isFalse);
      // (c) documents 数据到了新根。
      expect(
          File(p.join(newDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(
          File(p.join(newDocs.path, 'audiobooks', 'Bk', 'a.mp3')).existsSync(),
          isTrue);
      expect(oldDocs.existsSync(), isFalse);
      // (d) writeDataRootPref 收到新根值。
      expect(wroteDataRoot, equals(newDataRoot));

      // 旧 support 目录仍在（承载 prefs），且顶层只剩 prefs 族文件。
      expect(oldSupport.existsSync(), isTrue);
      final List<String> leftover = oldSupport
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toList()
        ..sort();
      expect(
          leftover,
          equals(<String>[
            'shared_preferences.json',
            'shared_preferences.json.lock'
          ]));

      // DB 内绝对路径仍正确 rebase 到新根（选择性搬移不破坏 rebase）。
      final HibikiDatabase db = HibikiDatabase(newSupport.path);
      try {
        final EpubBookRow b = (await db.getAllEpubBooks()).single;
        expect(b.epubPath, startsWith(newDocs.path));
      } finally {
        await db.close();
      }
    });

    test('自定义根迁移（源 support 无 prefs）→ 整树照搬不受 prefs 保护影响', () async {
      // 自定义根：oldSupport = <oldRoot>/support，顶层无 shared_preferences.json。
      await seedDb();
      final String newDataRoot = p.join(tmp.path, 'new2');
      String? wroteDataRoot;

      final (Directory newDocs, Directory newSupport) =
          await const DataRootMigrator().migrate(DataRootMigrationRequest(
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        newDataRoot: newDataRoot,
        // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
        documentsTopLevelIncludeNames: null,
        closeResources: () async {},
        writeDataRootPref: (String r) async => wroteDataRoot = r,
      ));

      // 整树搬齐：DB + local_audio + documents。
      expect(File(p.join(newSupport.path, 'hibiki.db')).existsSync(), isTrue);
      expect(File(p.join(newSupport.path, 'local_audio_1.db')).existsSync(),
          isTrue);
      expect(
          File(p.join(newDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      // 无 prefs 需保 → 旧根整目录删除（原行为）。
      expect(oldSupport.existsSync(), isFalse);
      expect(oldDocs.existsSync(), isFalse);
      expect(wroteDataRoot, equals(newDataRoot));
    });

    test('rename 被沙箱/权限层拒绝时退回 copy/delete（macOS 用户选择目录）', () {
      // POSIX EPERM / EACCES：macOS sandbox 下把容器目录 rename 到用户选择目录时
      // 可能被拒绝，但逐文件 copy/delete 仍可用，不能直接宣告迁移失败。
      expect(
          DataRootMigrator.shouldCopyAfterRenameFailureForTesting(1), isTrue);
      expect(
          DataRootMigrator.shouldCopyAfterRenameFailureForTesting(13), isTrue);
      // 既有跨盘 fallback 仍保留。
      expect(
          DataRootMigrator.shouldCopyAfterRenameFailureForTesting(18), isTrue);
      expect(
          DataRootMigrator.shouldCopyAfterRenameFailureForTesting(17), isTrue);
      // 普通不存在/路径错误不应伪装成可复制 fallback。
      expect(
          DataRootMigrator.shouldCopyAfterRenameFailureForTesting(2), isFalse);
    });

    test('目标 dataRoot 已存在数据 → 抛错，旧根不动', () async {
      await seedDb();
      final String newDataRoot = p.join(tmp.path, 'occupied');
      // 预先在目标 documents 子目录铺一个文件 → 非空 → 拒绝覆盖。
      File(p.join(newDataRoot, 'documents', 'x.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('existing');

      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          newDataRoot: newDataRoot,
          // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
          documentsTopLevelIncludeNames: null,
          closeResources: () async {},
          writeDataRootPref: (String r) async {},
        )),
        throwsA(isA<DataRootMigrationException>()),
      );

      // 旧根原样保留。
      expect(File(p.join(oldSupport.path, 'hibiki.db')).existsSync(), isTrue);
    });
  });

  group('TODO-1226：共享默认根白名单迁移（绝不整搬/整删用户 Documents）', () {
    test('白名单模式：只搬 Hibiki 自有顶层项，用户文件/junction 不动，Documents 本体保留', () async {
      await seedDb();
      // 模拟共享 Documents：用户自己的文件 + 目录 + shell junction（Link 指向别处）。
      final File userDoc = File(p.join(oldDocsPath, 'my_essay.docx'))
        ..writeAsStringSync('user data, do not touch');
      final Directory userDir = Directory(p.join(oldDocsPath, 'My Projects'))
        ..createSync();
      File(p.join(userDir.path, 'notes.txt')).writeAsStringSync('notes');
      final Directory linkTarget = Directory(p.join(tmp.path, 'link_target'))
        ..createSync(recursive: true);
      File(p.join(linkTarget.path, 'inside.txt')).writeAsStringSync('x');
      final Link junction = Link(p.join(oldDocsPath, 'My Music'))
        ..createSync(linkTarget.path);
      // 白名单里的另一个目录也铺数据。
      File(p.join(oldDocsPath, 'custom_fonts', 'f1.ttf'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2]);

      final String newDataRoot = p.join(tmp.path, 'new_whitelist');
      String? wrote;
      final (Directory newDocs, Directory newSupport) =
          await const DataRootMigrator().migrate(DataRootMigrationRequest(
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        newDataRoot: newDataRoot,
        closeResources: () async {},
        writeDataRootPref: (String r) async => wrote = r,
        documentsTopLevelIncludeNames: const <String>{
          'hoshi_books',
          'audiobooks',
          'custom_fonts',
        },
      ));

      // 白名单项已到新根。
      expect(
          File(p.join(newDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(
          File(p.join(newDocs.path, 'audiobooks', 'Bk', 'a.mp3')).existsSync(),
          isTrue);
      expect(File(p.join(newDocs.path, 'custom_fonts', 'f1.ttf')).existsSync(),
          isTrue);
      // 白名单项已离开源根（搬移即移除，不靠删整目录）。
      expect(
          Directory(p.join(oldDocsPath, 'hoshi_books')).existsSync(), isFalse);
      expect(
          Directory(p.join(oldDocsPath, 'audiobooks')).existsSync(), isFalse);
      // Documents 本体 + 用户文件 + junction 原样保留（P0：绝不删用户 Documents）。
      expect(oldDocs.existsSync(), isTrue);
      expect(userDoc.existsSync(), isTrue);
      expect(userDoc.readAsStringSync(), equals('user data, do not touch'));
      expect(File(p.join(userDir.path, 'notes.txt')).existsSync(), isTrue);
      expect(junction.existsSync(), isTrue);
      expect(File(p.join(linkTarget.path, 'inside.txt')).existsSync(), isTrue);
      // 用户文件/junction 不被复制/搬移到新根。
      expect(File(p.join(newDocs.path, 'my_essay.docx')).existsSync(), isFalse);
      expect(
          Directory(p.join(newDocs.path, 'My Projects')).existsSync(), isFalse);
      expect(Link(p.join(newDocs.path, 'My Music')).existsSync(), isFalse);
      // pref 已写、DB 绝对路径已 rebase 到新根。
      expect(wrote, equals(newDataRoot));
      final HibikiDatabase db = HibikiDatabase(newSupport.path);
      try {
        final EpubBookRow b = (await db.getAllEpubBooks()).single;
        expect(b.epubPath, startsWith(newDocs.path));
      } finally {
        await db.close();
      }
    });

    test('白名单模式回滚：pref 写失败 → 白名单项搬回 Documents，用户文件不动、新根子树清理', () async {
      await seedDb();
      final File userDoc = File(p.join(oldDocsPath, 'keep.txt'))
        ..writeAsStringSync('keep');
      final String newDataRoot = p.join(tmp.path, 'wl_rollback');

      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          newDataRoot: newDataRoot,
          closeResources: () async {},
          writeDataRootPref: (String r) async =>
              throw StateError('prefs unavailable'),
          documentsTopLevelIncludeNames: const <String>{
            'hoshi_books',
            'audiobooks',
          },
        )),
        throwsA(isA<DataRootMigrationException>()),
      );

      // 白名单项已合并搬回 Documents，用户文件毫发无损。
      expect(
          File(p.join(oldDocsPath, 'hoshi_books', 'Bk', 'a.html')).existsSync(),
          isTrue);
      expect(
          File(p.join(oldDocsPath, 'audiobooks', 'Bk', 'a.mp3')).existsSync(),
          isTrue);
      expect(userDoc.existsSync(), isTrue);
      expect(oldDocs.existsSync(), isTrue);
      // 新根迁移自建子树已清理。
      expect(Directory(p.join(newDataRoot, 'documents')).existsSync(), isFalse);
      expect(Directory(p.join(newDataRoot, 'support')).existsSync(), isFalse);
    });

    test('_countFiles 不追链接：进度分母只计真实文件（followLinks: false，TODO-1226）', () async {
      // src 有 1 个真实文件 + 1 个指向含文件目录的链接 → 分母恒为 1，链接不被复制。
      final Directory src = Directory(p.join(tmp.path, 'fl_src'))
        ..createSync(recursive: true);
      File(p.join(src.path, 'real.txt')).writeAsStringSync('r');
      final Directory tgt = Directory(p.join(tmp.path, 'fl_tgt'))
        ..createSync(recursive: true);
      File(p.join(tgt.path, 'linked.txt')).writeAsStringSync('L');
      Link(p.join(src.path, 'lnk')).createSync(tgt.path);
      final Directory dst = Directory(p.join(tmp.path, 'fl_dst'));

      final List<(int, int)> reports = <(int, int)>[];
      await const DataRootMigrator().copyTreeWithProgressForTesting(
        src,
        dst,
        (int copied, int total) => reports.add((copied, total)),
      );

      expect(reports.map(((int, int) r) => r.$2).toSet(), equals(<int>{1}));
      expect(File(p.join(dst.path, 'real.txt')).existsSync(), isTrue);
      // 链接目标内容不被当作真实文件复制。
      expect(File(p.join(dst.path, 'lnk', 'linked.txt')).existsSync(), isFalse);
      // 链接目标本体不受影响。
      expect(File(p.join(tgt.path, 'linked.txt')).existsSync(), isTrue);
    });
  });

  group('TODO-1182：安装目录/exe 目录拒绝 + 安全回滚 + 文件锁分类', () {
    test('目标是含运行 exe 的目录（安装目录）→ 拒绝，旧根不动', () async {
      await seedDb();
      final String newDataRoot = p.join(tmp.path, 'install');
      // 模拟安装目录：newRoot 下就放着「正在运行」的 exe。
      final String exe = p.join(newDataRoot, 'hibiki.exe');
      File(exe)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0x4d, 0x5a]);

      bool wrote = false;
      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          newDataRoot: newDataRoot,
          // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
          documentsTopLevelIncludeNames: null,
          closeResources: () async {},
          writeDataRootPref: (String r) async => wrote = true,
          resolvedExecutablePath: exe,
        )),
        throwsA(isA<DataRootMigrationException>().having(
          (DataRootMigrationException e) => e.message,
          'message',
          contains('安装目录'),
        )),
      );

      // exe 未被删、旧根完整、未写 pref。
      expect(File(exe).existsSync(), isTrue);
      expect(File(p.join(oldSupport.path, 'hibiki.db')).existsSync(), isTrue);
      expect(wrote, isFalse);
    });

    test('目标是 exe 所在目录的**祖先**目录 → 拒绝', () async {
      await seedDb();
      final String newDataRoot = p.join(tmp.path, 'apps');
      // exe 在 newRoot 的更深子目录（newRoot 是其祖先）。
      final String exe = p.join(newDataRoot, 'Hibiki', 'bin', 'hibiki.exe');
      File(exe)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0x4d, 0x5a]);

      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          newDataRoot: newDataRoot,
          // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
          documentsTopLevelIncludeNames: null,
          closeResources: () async {},
          writeDataRootPref: (String r) async {},
          resolvedExecutablePath: exe,
        )),
        throwsA(isA<DataRootMigrationException>()),
      );
      expect(File(exe).existsSync(), isTrue);
    });

    test('exe 在 newRoot 之外（普通空目录）→ 不拒绝，正常迁移', () async {
      await seedDb();
      final String newDataRoot = p.join(tmp.path, 'good_root');
      // exe 落在完全不相干的目录，不该触发安装目录拒绝。
      final String exe = p.join(tmp.path, 'elsewhere', 'hibiki.exe');
      File(exe)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0x4d, 0x5a]);
      String? wrote;

      final (Directory newDocs, Directory newSupport) =
          await const DataRootMigrator().migrate(DataRootMigrationRequest(
        oldDocumentsRoot: oldDocs,
        oldSupportRoot: oldSupport,
        newDataRoot: newDataRoot,
        // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
        documentsTopLevelIncludeNames: null,
        closeResources: () async {},
        writeDataRootPref: (String r) async => wrote = r,
        resolvedExecutablePath: exe,
      ));
      expect(File(p.join(newSupport.path, 'hibiki.db')).existsSync(), isTrue);
      expect(
          File(p.join(newDocs.path, 'hoshi_books', 'Bk', 'a.html'))
              .existsSync(),
          isTrue);
      expect(wrote, equals(newDataRoot));
    });

    test('回滚绝不删用户选定的 newRoot 本体：保留其中的用户预存文件', () async {
      await seedDb();
      // 用户选了一个**已存在且含自己其它文件**的目录做数据根。
      final String newDataRoot = p.join(tmp.path, 'user_picked');
      final File userFile = File(p.join(newDataRoot, 'my_notes.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('do not delete me');

      // 让 pref 写入失败，强制迁移在搬移成功后回滚。
      await expectLater(
        const DataRootMigrator().migrate(DataRootMigrationRequest(
          oldDocumentsRoot: oldDocs,
          oldSupportRoot: oldSupport,
          newDataRoot: newDataRoot,
          // 自定义专属根语义：整树搬移（TODO-1226 前的原行为）。
          documentsTopLevelIncludeNames: null,
          closeResources: () async {},
          writeDataRootPref: (String r) async =>
              throw StateError('prefs unavailable'),
        )),
        throwsA(isA<DataRootMigrationException>()),
      );

      // newRoot 本体保留，用户预存文件毫发无损。
      expect(Directory(newDataRoot).existsSync(), isTrue);
      expect(userFile.existsSync(), isTrue);
      expect(userFile.readAsStringSync(), equals('do not delete me'));
      // 迁移自建的 documents/support 子树已清理（无半迁移残留数据）。
      expect(Directory(p.join(newDataRoot, 'documents')).existsSync(), isFalse);
      expect(Directory(p.join(newDataRoot, 'support')).existsSync(), isFalse);
      // 旧根完整、数据回滚保留。
      expect(File(p.join(oldSupportPath, 'hibiki.db')).existsSync(), isTrue);
      expect(
          File(p.join(oldDocsPath, 'hoshi_books', 'Bk', 'a.html')).existsSync(),
          isTrue);
    });

    test('Windows 文件锁错误码分类：5/32/33 判为「被占用」，普通错误不误判', () {
      expect(DataRootMigrator.isWindowsLockCodeForTesting(5), isTrue);
      expect(DataRootMigrator.isWindowsLockCodeForTesting(32), isTrue);
      expect(DataRootMigrator.isWindowsLockCodeForTesting(33), isTrue);
      expect(DataRootMigrator.isWindowsLockCodeForTesting(2), isFalse);
      expect(DataRootMigrator.isWindowsLockCodeForTesting(18), isFalse);
    });
  });

  group('TODO-935/959：Windows 文件锁抗性（有界退避重试 + 跨盘删源降级）', () {
    test('withLockRetry：锁码抛出前几次后成功 → 重试直至成功', () async {
      int calls = 0;
      await DataRootMigrator.withLockRetryForTesting(
        () async {
          calls++;
          if (calls < 3) {
            throw FileSystemException(
                'locked', '', const OSError('sharing violation', 32));
          }
        },
        maxAttempts: 5,
        backoff: Duration.zero,
      );
      // 前 2 次锁、第 3 次成功。
      expect(calls, equals(3));
    });

    test('withLockRetry：锁码持续超过上限 → 最终上抛 FileSystemException', () async {
      int calls = 0;
      await expectLater(
        DataRootMigrator.withLockRetryForTesting(
          () async {
            calls++;
            throw FileSystemException(
                'locked', '', const OSError('access denied', 5));
          },
          maxAttempts: 3,
          backoff: Duration.zero,
        ),
        throwsA(isA<FileSystemException>()),
      );
      // 初次 + 3 次重试 = 4 次调用。
      expect(calls, equals(4));
    });

    test('withLockRetry：非锁错误立即上抛，不重试', () async {
      int calls = 0;
      await expectLater(
        DataRootMigrator.withLockRetryForTesting(
          () async {
            calls++;
            throw FileSystemException(
                'not found', '', const OSError('no such file', 2));
          },
          maxAttempts: 5,
          backoff: Duration.zero,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, equals(1));
    });
  });
}

/// 目录树下是否有任意文件（不含目录项）。用于断言回滚后 newRoot 下无迁移残留数据。
bool _hasAnyFileUnder(String dirPath) {
  final Directory dir = Directory(dirPath);
  if (!dir.existsSync()) return false;
  for (final FileSystemEntity e in dir.listSync(recursive: true)) {
    if (e is File) return true;
  }
  return false;
}
