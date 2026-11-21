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
import 'package:test/test.dart';
import 'package:fushi/src/media/collections/collection_grouping.dart';
import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';
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
      expect(
        await db.getSrtBookByBookKey(bookKey),
        isNull,
        reason: '前置：尚无配对 SrtBook',
      );

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
      expect(
        row!.uid,
        'srtbook_epub_$bookKey',
        reason: 'uid 必须稳定派生（禁 DateTime.now()）',
      );
      expect(row.bookKey, bookKey);
      expect(row.title, '安達としまむら');
      expect(row.author, '入間人間');
      expect(
        row.srtPath,
        '/abs/persist/$bookKey/aligned.srt',
        reason: 'srtPath 必须等于 audiobook.alignmentPath（同批落盘文件）',
      );
      expect((jsonDecode(row.audioPathsJson!) as List).cast<String>(), <String>[
        '/abs/persist/$bookKey/disc1.mp3',
        '/abs/persist/$bookKey/disc2.mp3',
      ]);
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
      final Iterable<SrtBookRow> forKey = all.where(
        (SrtBookRow r) => r.bookKey == bookKey,
      );
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
      expect(
        after.audioPaths,
        equals(<String>['/abs/persist/$bookKey/a.mp3']),
        reason: '换字幕不得清空配对行的音频（BUG-1678）',
      );
      expect(
        after.coverPath,
        '/abs/persist/$bookKey/cover.jpg',
        reason: '本次没碰的列不该被整行覆盖清掉',
      );
    });
  });

  group('writeEpubBackedSrtBook 继承原书合集归属', () {
    late FushiDatabase db;
    late SrtBookRepository repo;

    setUp(() {
      db = _memDb();
      repo = SrtBookRepository(db);
    });
    tearDown(() async => db.close());

    Future<String> insertEpub(String bookKey, {String format = 'epub'}) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: bookKey,
          epubPath: '/abs/$bookKey.epub',
          extractDir: '/abs/$bookKey',
          chapterCount: 1,
          chaptersJson: '["ch1"]',
          importedAt: 1000,
          format: Value<String>(format),
        ),
      );
      return (await db.resolveEpubBookUid(bookKey))!;
    }

    Future<void> writePaired(String bookKey) => writeEpubBackedSrtBook(
      repo: repo,
      bookKey: bookKey,
      title: bookKey,
      author: 'Author',
      srtPath: '/abs/persist/$bookKey/tts_audiobook.srt',
      audioPaths: <String>['/abs/persist/$bookKey/tts_001.m4a'],
    );

    test('规则合集：生成配对有声书后紧邻原书入合集，不抢占 origin 与 orderUpdatedAt', () async {
      final String uid1 = await insertEpub('Vol 1');
      final String uid2 = await insertEpub('Vol 2');
      final String uid3 = await insertEpub('Vol 3');
      final int cid = await db.createMediaCollection(
        'Series',
        collectionType: 'playlist',
        origin: CollectionOrigin.rule,
      );
      await db.addToCollection(cid, MediaKind.epub, uid1, userIntent: false);
      await db.addToCollection(cid, MediaKind.epub, uid2, userIntent: false);
      await db.addToCollection(cid, MediaKind.epub, uid3, userIntent: false);

      await writePaired('Vol 2');

      final List<MediaCollectionItemRow> items = await db.getCollectionItems(
        cid,
      );
      expect(
        <String>[
          for (final MediaCollectionItemRow i in items)
            '${i.mediaType}|${i.entryKey}',
        ],
        <String>[
          'epub|$uid1',
          'epub|$uid2',
          'srt|${epubBackedSrtBookUid('Vol 2')}',
          'epub|$uid3',
        ],
      );
      expect(
        <int>[for (final MediaCollectionItemRow i in items) i.sortIndex],
        <int>[0, 1, 2, 3],
      );
      expect(
        items.every((MediaCollectionItemRow i) => !i.pinnedByUser),
        isTrue,
      );
      final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;
      expect(col.origin, CollectionOrigin.rule.dbValue);
      expect(col.orderUpdatedAt, 0);
    });

    test('用户手动排序的自定义合集：继承 pinnedByUser 并保留 orderUpdatedAt', () async {
      final String uidA = await insertEpub('Book A');
      final String uidB = await insertEpub('Book B');
      final String uidC = await insertEpub('Book C');
      final int cid = await db.createMediaCollection('Custom');
      await db.addToCollection(cid, MediaKind.epub, uidA);
      await db.addToCollection(cid, MediaKind.epub, uidB);
      await db.addToCollection(cid, MediaKind.epub, uidC);
      await db.reorderCollectionItems(cid, <CollectionMemberKey>[
        (mediaType: MediaKind.epub.dbValue, entryKey: uidA),
        (mediaType: MediaKind.epub.dbValue, entryKey: uidB),
        (mediaType: MediaKind.epub.dbValue, entryKey: uidC),
      ]);
      final int orderBefore = (await db.getMediaCollectionById(
        cid,
      ))!.orderUpdatedAt;
      expect(orderBefore, greaterThan(0));

      await writePaired('Book B');

      final List<MediaCollectionItemRow> items = await db.getCollectionItems(
        cid,
      );
      expect(
        <String>[
          for (final MediaCollectionItemRow i in items)
            '${i.mediaType}|${i.entryKey}',
        ],
        <String>[
          'epub|$uidA',
          'epub|$uidB',
          'srt|${epubBackedSrtBookUid('Book B')}',
          'epub|$uidC',
        ],
      );
      final MediaCollectionItemRow srtItem = items.singleWhere(
        (MediaCollectionItemRow i) => i.mediaType == MediaKind.srt.dbValue,
      );
      expect(srtItem.pinnedByUser, isTrue);
      expect(
        (await db.getMediaCollectionById(cid))!.orderUpdatedAt,
        orderBefore,
      );
    });

    test('多合集与旧 bookKey 成员行：同步继承进全部所属合集', () async {
      final String uidX = await insertEpub('Book X');
      final int cidA = await db.createMediaCollection('Col A');
      final int cidB = await db.createMediaCollection('Col B');
      await db.addToCollection(cidA, MediaKind.epub, uidX);
      await db.addToCollection(cidB, MediaKind.epub, 'Book X');

      await writePaired('Book X');

      final String srtUid = epubBackedSrtBookUid('Book X');
      expect(
        (await db.getCollectionItems(cidA)).any(
          (MediaCollectionItemRow r) =>
              r.mediaType == MediaKind.srt.dbValue && r.entryKey == srtUid,
        ),
        isTrue,
      );
      expect(
        (await db.getCollectionItems(cidB)).any(
          (MediaCollectionItemRow r) =>
              r.mediaType == MediaKind.srt.dbValue && r.entryKey == srtUid,
        ),
        isTrue,
      );
    });

    test('尊重成员移出墓碑：移出有声书后再次补写不复活', () async {
      final String uidT = await insertEpub('Book T');
      final int cid = await db.createMediaCollection('Tombstone Col');
      await db.addToCollection(cid, MediaKind.epub, uidT);
      await writePaired('Book T');

      final String srtUid = epubBackedSrtBookUid('Book T');
      await db.removeFromCollection(cid, MediaKind.srt, srtUid);
      await writePaired('Book T');

      final List<MediaCollectionItemRow> items = await db.getCollectionItems(
        cid,
      );
      expect(
        items.any(
          (MediaCollectionItemRow r) =>
              r.mediaType == MediaKind.srt.dbValue && r.entryKey == srtUid,
        ),
        isFalse,
      );
      expect(
        items.any(
          (MediaCollectionItemRow r) =>
              r.mediaType == MediaKind.epub.dbValue && r.entryKey == uidT,
        ),
        isTrue,
      );
    });

    test('尊重既有放置：配对 SRT 已在合集 B 时不会自动补进合集 A', () async {
      final String uidP = await insertEpub('Book P');
      final int cidA = await db.createMediaCollection('Col A');
      final int cidB = await db.createMediaCollection('Col B');
      await db.addToCollection(cidA, MediaKind.epub, uidP);
      final String srtUid = epubBackedSrtBookUid('Book P');
      await db.addToCollection(cidB, MediaKind.srt, srtUid);

      await writePaired('Book P');

      expect(
        (await db.getCollectionItems(cidA)).any(
          (MediaCollectionItemRow r) =>
              r.mediaType == MediaKind.srt.dbValue && r.entryKey == srtUid,
        ),
        isFalse,
      );
      expect(
        (await db.getCollectionItems(cidB)).any(
          (MediaCollectionItemRow r) =>
              r.mediaType == MediaKind.srt.dbValue && r.entryKey == srtUid,
        ),
        isTrue,
      );
    });

    test('漫画格式（format=manga）不继承 SRT 合集成员', () async {
      final String uidM = await insertEpub('Manga M', format: 'manga');
      final int cid = await db.createMediaCollection('Manga Col');
      await db.addToCollection(cid, MediaKind.epub, uidM);

      await writePaired('Manga M');

      final List<MediaCollectionItemRow> items = await db.getCollectionItems(
        cid,
      );
      expect(items, hasLength(1));
      expect(items.single.mediaType, MediaKind.epub.dbValue);
      expect(items.single.entryKey, uidM);
    });

    test('端到端书架折叠（groupByCollections）：替换卡留在同合集且保持相对顺序', () async {
      final String uid1 = await insertEpub('Vol 1');
      final String uid2 = await insertEpub('Vol 2');
      final String uid3 = await insertEpub('Vol 3');
      final int cid = await db.createMediaCollection(
        'Shelf Series',
        collectionType: 'playlist',
        origin: CollectionOrigin.rule,
      );
      await db.addToCollection(cid, MediaKind.epub, uid1, userIntent: false);
      await db.addToCollection(cid, MediaKind.epub, uid2, userIntent: false);
      await db.addToCollection(cid, MediaKind.epub, uid3, userIntent: false);

      await writePaired('Vol 2');
      final String srtUid2 = epubBackedSrtBookUid('Vol 2');

      final Map<String, int> primaryByEntry = await db
          .getPrimaryCollectionIdByEntry();
      final Map<int, MediaCollectionRow> collectionsById =
          <int, MediaCollectionRow>{
            for (final MediaCollectionRow c
                in await db.getAllMediaCollections())
              c.id: c,
          };
      final Map<String, int> memberSortIndex = <String, int>{};
      for (final MediaCollectionItemRow m in await db.getAllCollectionItems()) {
        final String key = '${m.mediaType}|${m.entryKey}';
        if (primaryByEntry[key] == m.collectionId) {
          memberSortIndex[key] = m.sortIndex;
        }
      }

      // 书架展示时 Vol 2 的 EPUB 卡被有声书 SRT 卡顶替（audiobookShadowedBookKeys）。
      final List<CollectionGroup<String>> groups = groupByCollections<String>(
        items: <CollectionOrderingItem<String>>[
          CollectionOrderingItem<String>(
            mediaType: MediaKind.srt,
            entryKey: srtUid2,
            importedAt: 2000,
            payload: 'Vol 2 Audio',
          ),
          CollectionOrderingItem<String>(
            mediaType: MediaKind.epub,
            entryKey: uid1,
            importedAt: 1000,
            payload: 'Vol 1',
          ),
          CollectionOrderingItem<String>(
            mediaType: MediaKind.epub,
            entryKey: uid3,
            importedAt: 3000,
            payload: 'Vol 3',
          ),
        ],
        primaryCollectionIdByEntry: primaryByEntry,
        collectionsById: collectionsById,
        memberSortIndex: memberSortIndex,
      );

      expect(groups, hasLength(1));
      expect(groups.single.collection?.id, cid);
      expect(
        <String>[
          for (final CollectionOrderingItem<String> it in groups.single.items)
            it.payload,
        ],
        <String>['Vol 1', 'Vol 2 Audio', 'Vol 3'],
      );
    });
  });
}
