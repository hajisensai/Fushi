/// TODO-894：EPUB-backed 有声书导入必须补写配对 SrtBook 行。
///
/// 病灶：`_importEpubWithAlignment` 只写 Audiobooks 行、不写 srt_books 行，导致
/// live push（`sync_orchestrator.dart:1024`）与 syncAudiobookPackages（:1270）查
/// `getSrtBookByBookKey == null` → 整本永不上传。
///
/// 修复把「补写配对 SrtBook」抽成可测的纯 helper [writeEpubBackedSrtBook]
/// （导入路径与测试共用）。本测试驱动 helper（private widget 难驱动），断言：
/// - `getSrtBookByBookKey(bookKey) != null`
/// - srtPath / audioPathsJson / title / author 字段正确映射
/// - uid == `srtbook_epub_<bookKey>`（稳定派生，幂等核心）
/// - 同 bookKey 二次调用幂等：行数不增、uid 不变。
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  group('TODO-894 writeEpubBackedSrtBook', () {
    late HibikiDatabase db;
    late SrtBookRepository repo;

    setUp(() {
      db = _memDb();
      repo = SrtBookRepository(db);
    });
    tearDown(() async => db.close());

    test('补写后 getSrtBookByBookKey 命中，字段映射正确，uid 稳定派生', () async {
      const String bookKey = 'Adachi to Shimamura';
      expect(await db.getSrtBookByBookKey(bookKey), isNull,
          reason: '前置：尚无配对 SrtBook');

      await writeEpubBackedSrtBook(
        repo: repo,
        bookKey: bookKey,
        title: '安達としまむら',
        author: '入間人間',
        srtPath: '/abs/persist/$bookKey/aligned.srt',
        audioPaths: <String>[
          '/abs/persist/$bookKey/disc1.mp3',
          '/abs/persist/$bookKey/disc2.mp3',
        ],
      );

      final SrtBookRow? row = await db.getSrtBookByBookKey(bookKey);
      expect(row, isNotNull, reason: '补写后必须能按 bookKey 查到配对 SrtBook');
      expect(row!.uid, 'srtbook_epub_$bookKey',
          reason: 'uid 必须稳定派生（禁 DateTime.now()）');
      expect(row.bookKey, bookKey);
      expect(row.title, '安達としまむら');
      expect(row.author, '入間人間');
      expect(row.srtPath, '/abs/persist/$bookKey/aligned.srt',
          reason: 'srtPath 必须等于 audiobook.alignmentPath（同批落盘文件）');
      expect(
        (jsonDecode(row.audioPathsJson!) as List).cast<String>(),
        <String>[
          '/abs/persist/$bookKey/disc1.mp3',
          '/abs/persist/$bookKey/disc2.mp3',
        ],
      );
      // 必改4：cover_path 两路径都留空（export 不依赖 srtBook.coverPath）。
      expect(row.coverPath, isNull, reason: 'EPUB-backed 配对行 cover_path 留空');
    });

    test('无音频时 audioPathsJson 为空', () async {
      const String bookKey = 'NoAudioBook';
      await writeEpubBackedSrtBook(
        repo: repo,
        bookKey: bookKey,
        title: 'No Audio',
        author: null,
        srtPath: '/abs/persist/$bookKey/aligned.vtt',
        audioPaths: const <String>[],
      );
      final SrtBookRow? row = await db.getSrtBookByBookKey(bookKey);
      expect(row, isNotNull);
      expect(row!.audioPathsJson, isNull);
      expect(row.author, isNull);
    });

    test('同 bookKey 二次调用幂等：行数不增，uid 不变', () async {
      const String bookKey = 'IdempotentBook';
      await writeEpubBackedSrtBook(
        repo: repo,
        bookKey: bookKey,
        title: 'First',
        author: 'A',
        srtPath: '/abs/persist/$bookKey/a.srt',
        audioPaths: const <String>['/abs/persist/$bookKey/a.mp3'],
      );
      final SrtBookRow first = (await db.getSrtBookByBookKey(bookKey))!;

      // 二次导入（同 bookKey）：upsert on uid → 覆盖同行，不新增行。
      await writeEpubBackedSrtBook(
        repo: repo,
        bookKey: bookKey,
        title: 'Second',
        author: 'B',
        srtPath: '/abs/persist/$bookKey/b.srt',
        audioPaths: const <String>['/abs/persist/$bookKey/b.mp3'],
      );

      final List<SrtBookRow> all = await db.getAllSrtBooks();
      final Iterable<SrtBookRow> forKey =
          all.where((SrtBookRow r) => r.bookKey == bookKey);
      expect(forKey, hasLength(1), reason: '幂等：同 bookKey 不得新增第二行');
      expect(forKey.single.uid, first.uid, reason: 'uid 必须稳定不变');
      expect(forKey.single.uid, 'srtbook_epub_$bookKey');
    });
  });
}
