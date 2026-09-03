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
import 'package:fushi/src/media/import/epub_backed_srt_book.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  group('TODO-894 writeEpubBackedSrtBook', () {
    late FushiDatabase db;
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

    test('BUG-1678：只换字幕（不带音频）不得清空配对行的音频与封面', () async {
      const String bookKey = 'SubtitleOnlyReimport';
      await writeEpubBackedSrtBook(
        repo: repo,
        bookKey: bookKey,
        title: 'Book',
        author: 'A',
        srtPath: '/abs/persist/$bookKey/old.srt',
        audioPaths: const <String>['/abs/persist/$bookKey/a.mp3'],
      );
      // 封面由别的路径（书架编辑 / backfill）写上；helper 自己新建时不写。
      final SrtBook seeded = (await repo.findByUid('srtbook_epub_$bookKey'))!;
      seeded.coverPath = '/abs/persist/$bookKey/cover.jpg';
      await repo.save(seeded);

      // 换字幕路径：AudiobookImportDialog 此时 persistedPaths 为空，helper 拿不到
      // 音频。整行覆盖若不以现有行为基线，配对行的音频/封面就一起没了 —— 互联
      // host 的 hasAudiobook 判据要求两表齐备且带音频，清掉即从同步里消失。
      await writeEpubBackedSrtBook(
        repo: repo,
        bookKey: bookKey,
        title: 'Book',
        author: 'A',
        srtPath: '/abs/persist/$bookKey/new.srt',
        audioPaths: const <String>[],
      );

      final SrtBook after = (await repo.findByUid('srtbook_epub_$bookKey'))!;
      expect(after.srtPath, '/abs/persist/$bookKey/new.srt', reason: '字幕确实换了');
      expect(after.audioPaths, equals(<String>['/abs/persist/$bookKey/a.mp3']),
          reason: '换字幕不得清空配对行的音频（BUG-1678）');
      expect(after.coverPath, '/abs/persist/$bookKey/cover.jpg',
          reason: '本次没碰的列不该被整行覆盖清掉');
    });
  });
}
