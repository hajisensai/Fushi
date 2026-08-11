import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-1575 ②：已经落进用户库的坏 srt 路径，在列出时自愈。
///
/// 光修导入代码救不了「已经迁移完、中转文件已删」的设备——那 6 本书的行永远指着
/// 旧数据根。这里锁死自愈的三条边界：幂等、同名歧义不猜、有效路径不动。
void main() {
  late Directory docs; // 当前设备的 <documents>
  late Directory root; // 当前设备的 <documents>/audiobooks

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('srtrelo_');
    root = Directory(p.join(docs.path, 'audiobooks'))
      ..createSync(recursive: true);
    // 生产接线：AppModel 启动期把这个钩子接到 AppPaths.documentsRootDirectory
    // （app_model.dart 的 _prepareRuntimeDirectories），这里照接，好让 listAll()
    // 的自愈走与真机同一条根解析路径。
    AudiobookStorage.documentsRootResolver = () async => docs;
  });
  tearDown(() async {
    AudiobookStorage.documentsRootResolver = null;
    if (docs.existsSync()) {
      try {
        docs.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上偶发句柄未释放，测试结论与清理无关。
      }
    }
  });

  void writeFile(String path, String content) {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<void> insertBook(
    FushiDatabase db, {
    required String uid,
    String? audioRoot,
    List<String>? audioPaths,
    required String srtPath,
    String? coverPath,
  }) =>
      db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: uid,
        title: uid,
        audioRoot: Value(audioRoot),
        audioPathsJson:
            Value(audioPaths == null ? null : jsonEncode(audioPaths)),
        srtPath: srtPath,
        coverPath: Value(coverPath),
        importedAt: 0,
      ));

  group('AudiobookPathRelocator', () {
    test(
        're-anchors the sub-path after the audiobooks segment onto the current '
        'root', () {
      writeFile(p.join(root.path, 'u1', '01.mp3'), 'A');
      final AudiobookPathRelocator relocator =
          AudiobookPathRelocator(audiobooksRoot: root.path);
      expect(
        relocator
            .relocate('/data/user/0/app.hibiki.reader/audiobooks/u1/01.mp3'),
        p.join(root.path, 'u1', '01.mp3'),
      );
      expect(relocator.stats.repaired, 1);
    });

    test('leaves a path that resolves on disk untouched', () {
      final String good = p.join(root.path, 'u1', '01.mp3');
      writeFile(good, 'A');
      final AudiobookPathRelocator relocator =
          AudiobookPathRelocator(audiobooksRoot: root.path);
      expect(relocator.relocate(good), isNull);
      expect(relocator.stats.repaired, 0);
    });

    test('does NOT touch a referenced import outside any audiobooks tree', () {
      writeFile(p.join(root.path, 'u1', '01.mp3'), 'A');
      final AudiobookPathRelocator relocator =
          AudiobookPathRelocator(audiobooksRoot: root.path);
      // 用户自己目录里的原始文件被删/移走：同名文件在 audiobooks 根下有且只有
      // 一个，但那是**别的书的**章节，绝不能指过去。
      expect(relocator.relocate('/sdcard/Music/MyBook/01.mp3'), isNull);
      expect(relocator.stats.repaired, 0);
    });

    test('falls back to a UNIQUE basename hit when the sub-path moved', () {
      writeFile(p.join(root.path, 'newdir', 'only-one.mp3'), 'A');
      final AudiobookPathRelocator relocator =
          AudiobookPathRelocator(audiobooksRoot: root.path);
      expect(
        relocator.relocate('/old/root/audiobooks/olddir/only-one.mp3'),
        p.join(root.path, 'newdir', 'only-one.mp3'),
      );
      expect(relocator.stats.repaired, 1);
    });

    test('refuses to guess when several files share the basename', () {
      writeFile(p.join(root.path, 'a', '01.mp3'), 'A');
      writeFile(p.join(root.path, 'b', '01.mp3'), 'B');
      final AudiobookPathRelocator relocator =
          AudiobookPathRelocator(audiobooksRoot: root.path);
      expect(relocator.relocate('/old/root/audiobooks/gone/01.mp3'), isNull);
      expect(relocator.stats.ambiguous, 1);
      expect(relocator.stats.repaired, 0);
    });

    test('windows-style stored path re-anchors onto a posix-style root', () {
      writeFile(p.join(root.path, 'u1', 'sub.srt'), 'S');
      final AudiobookPathRelocator relocator =
          AudiobookPathRelocator(audiobooksRoot: root.path);
      expect(
        relocator.relocate(r'C:\Old\Hibiki\audiobooks\u1\sub.srt'),
        p.join(root.path, 'u1', 'sub.srt'),
      );
    });
  });

  group('SrtBookRepository.repairMovedPaths', () {
    test('repairs all four columns of a row stranded on the old data root',
        () async {
      writeFile(p.join(root.path, 'u1', '01.mp3'), 'A');
      writeFile(p.join(root.path, 'u1', '02.mp3'), 'B');
      writeFile(p.join(root.path, 'u1', 'sub.srt'), 'S');
      writeFile(p.join(root.path, 'u1', 'cover.jpg'), 'C');
      const String old = '/data/user/0/app.hibiki.reader/files/audiobooks/u1';

      final FushiDatabase db = await openDb();
      await insertBook(
        db,
        uid: 'srtbook_1',
        audioRoot: old,
        audioPaths: <String>['$old/01.mp3', '$old/02.mp3'],
        srtPath: '$old/sub.srt',
        coverPath: '$old/cover.jpg',
      );

      final SrtBookRepository repo = SrtBookRepository(db);
      expect(await repo.repairMovedPaths(audiobooksRoot: root.path), 1);

      final SrtBookRow? row = await db.getSrtBookByUid('srtbook_1');
      expect(row!.audioRoot, p.join(root.path, 'u1'));
      expect(row.srtPath, p.join(root.path, 'u1', 'sub.srt'));
      expect(row.coverPath, p.join(root.path, 'u1', 'cover.jpg'));
      expect(jsonDecode(row.audioPathsJson!), <String>[
        p.join(root.path, 'u1', '01.mp3'),
        p.join(root.path, 'u1', '02.mp3'),
      ]);
    });

    test('is idempotent: a second run changes nothing', () async {
      writeFile(p.join(root.path, 'u1', '01.mp3'), 'A');
      writeFile(p.join(root.path, 'u1', 'sub.srt'), 'S');
      const String old = '/old/hibiki/audiobooks/u1';

      final FushiDatabase db = await openDb();
      await insertBook(
        db,
        uid: 'srtbook_1',
        audioPaths: <String>['$old/01.mp3'],
        srtPath: '$old/sub.srt',
      );
      final SrtBookRepository repo = SrtBookRepository(db);
      expect(await repo.repairMovedPaths(audiobooksRoot: root.path), 1);
      final SrtBookRow? first = await db.getSrtBookByUid('srtbook_1');

      expect(
        await repo.repairMovedPaths(audiobooksRoot: root.path),
        0,
        reason: '第二遍必须一行都不改',
      );
      final SrtBookRow? second = await db.getSrtBookByUid('srtbook_1');
      expect(second!.srtPath, first!.srtPath);
      expect(second.audioPathsJson, first.audioPathsJson);
    });

    test('does not rewrite anything when several same-name candidates exist',
        () async {
      writeFile(p.join(root.path, 'a', '01.mp3'), 'A');
      writeFile(p.join(root.path, 'b', '01.mp3'), 'B');
      writeFile(p.join(root.path, 'a', 'sub.srt'), 'S');
      writeFile(p.join(root.path, 'b', 'sub.srt'), 'S');
      const String old = '/old/hibiki/audiobooks/gone';

      final FushiDatabase db = await openDb();
      await insertBook(
        db,
        uid: 'srtbook_1',
        audioPaths: <String>['$old/01.mp3'],
        srtPath: '$old/sub.srt',
      );
      final SrtBookRepository repo = SrtBookRepository(db);
      expect(
        await repo.repairMovedPaths(audiobooksRoot: root.path),
        0,
        reason: '两个同名候选 → 不猜，一行都不改',
      );

      final SrtBookRow? row = await db.getSrtBookByUid('srtbook_1');
      expect(jsonDecode(row!.audioPathsJson!), <String>['$old/01.mp3'],
          reason: '保持原值，让用户手动重定位');
      expect(row.srtPath, '$old/sub.srt');
    });

    test('a healthy library is never rewritten (and never scans the tree)',
        () async {
      final String goodSrt = p.join(root.path, 'u1', 'sub.srt');
      final String goodMp3 = p.join(root.path, 'u1', '01.mp3');
      writeFile(goodSrt, 'S');
      writeFile(goodMp3, 'A');

      final FushiDatabase db = await openDb();
      await insertBook(
        db,
        uid: 'srtbook_1',
        audioPaths: <String>[goodMp3],
        srtPath: goodSrt,
      );
      bool rootResolved = false;
      AudiobookStorage.documentsRootResolver = () async {
        rootResolved = true;
        return docs;
      };
      final SrtBookRepository repo = SrtBookRepository(db);
      expect(
        await repo.repairMovedPaths(
          // 刻意不传 audiobooksRoot：健康库必须在**解析数据根之前**就短路返回，
          // 否则每次列书都要走 path_provider / 扫一遍 audiobooks 全树。
          listEntries: (String _) => throw StateError('健康库不得触发目录扫描'),
        ),
        0,
      );
      expect(rootResolved, isFalse, reason: '健康库不得解析 documents 根');
      final SrtBookRow? row = await db.getSrtBookByUid('srtbook_1');
      expect(row!.srtPath, goodSrt);
      expect(jsonDecode(row.audioPathsJson!), <String>[goodMp3]);
    });

    test(
        'only the broken row is rewritten (rows are keyed by uid, and the '
        'standalone bookKey sentinel is shared by every such row)', () async {
      writeFile(p.join(root.path, 'u1', 'sub.srt'), 'S');
      final String healthySrt = p.join(root.path, 'u2', 'other.srt');
      writeFile(healthySrt, 'S2');

      final FushiDatabase db = await openDb();
      await insertBook(db,
          uid: 'srtbook_broken', srtPath: '/old/hibiki/audiobooks/u1/sub.srt');
      await insertBook(db, uid: 'srtbook_healthy', srtPath: healthySrt);

      final SrtBookRepository repo = SrtBookRepository(db);
      expect(await repo.repairMovedPaths(audiobooksRoot: root.path), 1);

      expect((await db.getSrtBookByUid('srtbook_broken'))!.srtPath,
          p.join(root.path, 'u1', 'sub.srt'));
      expect((await db.getSrtBookByUid('srtbook_healthy'))!.srtPath, healthySrt,
          reason: '健康行绝不能被同批改写');
    });

    test('listAll alone self-heals (production wiring: documents root hook)',
        () async {
      writeFile(p.join(root.path, 'u1', 'sub.srt'), 'S');
      writeFile(p.join(root.path, 'u1', '01.mp3'), 'A');
      const String old = '/data/user/0/app.hibiki.reader/files/audiobooks/u1';
      final FushiDatabase db = await openDb();
      await insertBook(db,
          uid: 'srtbook_1',
          srtPath: '$old/sub.srt',
          audioPaths: <String>['$old/01.mp3']);

      final SrtBookRepository repo = SrtBookRepository(db);
      final List<SrtBook> books = await repo.listAll();
      expect(books.single.srtPath, p.join(root.path, 'u1', 'sub.srt'),
          reason: '返回的模型必须已经是修好的路径');
      expect(
          books.single.audioPaths, <String>[p.join(root.path, 'u1', '01.mp3')]);

      final SrtBookRow? row = await db.getSrtBookByUid('srtbook_1');
      expect(row!.srtPath, p.join(root.path, 'u1', 'sub.srt'),
          reason: '修复必须落库，否则每次列出都要重扫');
    });
  });
}
