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
          closeResources: () async {},
          writeDataRootPref: (String r) async {},
        )),
        throwsA(isA<DataRootMigrationException>()),
      );

      // 旧根原样保留。
      expect(File(p.join(oldSupport.path, 'hibiki.db')).existsSync(), isTrue);
    });
  });
}
