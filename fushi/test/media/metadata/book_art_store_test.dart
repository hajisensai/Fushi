import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/item_scrape_detail.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 刮削层存储：写 / 读 / 快照撤销往返；横幅 = 书的背景图（item_images，BUG-5609）：
/// 贴上 / 不覆盖别处来的背景图 / 清除只撤本层贴的 / 撤销贴回 / 旧版目录一次性搬家。
List<int> png(int width, int height, {int shade = 0}) => img.encodePng(
  img.Image(width: width, height: height)
    ..clear(img.ColorRgb8(shade, shade, shade)),
);

const String kBannerUrl = 'https://images.mangabaka.dev/banner/1';

BookArtRecord record(
  String bookKey, {
  String? bannerKey,
  String? bannerUrl,
  String source = 'mangabaka',
  int scrapedAt = 1,
}) => BookArtRecord(
  bookKey: bookKey,
  source: source,
  seriesId: '42',
  seriesTitle: 'Series',
  coverSource: source,
  coverUrl: 'https://images.example/$bookKey',
  bannerKey: bannerKey,
  bannerUrl: bannerUrl ?? (bannerKey == null ? null : kBannerUrl),
  scrapedAt: scrapedAt,
);

void main() {
  // 写盘 / 清除都会驱逐解码缓存（ImageCache 要 binding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late Directory items;
  late ItemScrapeStore itemScrape;
  late BookArtStore store;
  late File bannerSource;

  BookArtStore open() =>
      BookArtStore.of(thumbs, database: db, itemScrape: itemScrape);

  setUp(() async {
    BookArtStore.resetForTesting();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    thumbs = await Directory.systemTemp.createTemp('fushi_book_art_store_');
    items = Directory(p.join(thumbs.path, 'items'));
    itemScrape = ItemScrapeStore(db, imagesDirectory: items);
    store = open();
    bannerSource = File(p.join(thumbs.path, 'banner_src.png'))
      ..writeAsBytesSync(png(16, 9));
  });

  tearDown(() async {
    BookArtStore.resetForTesting();
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  Future<ItemScrapeKey> seed(String bookKey) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Series $bookKey',
        epubPath: '/nonexistent/$bookKey.cbz',
        extractDir: '/nonexistent/$bookKey',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
        format: const Value<String>('manga'),
      ),
    );
    return ItemScrapeKey(
      MediaKind.epub,
      (await db.resolveEpubBookUid(bookKey))!,
    );
  }

  Future<ItemImageRow?> backdrop(ItemScrapeKey key) =>
      itemScrape.firstImage(key, MediaImageKind.backdrop);

  /// 别处（书籍刮削）写的背景图。
  Future<String> foreignBackdrop(ItemScrapeKey key) async {
    final File src = File(p.join(thumbs.path, 'anilist.png'))
      ..writeAsBytesSync(png(20, 9, shade: 90));
    return itemScrape.setImageFromFile(
      key,
      MediaImageKind.backdrop,
      src,
      sourceUrl: 'https://s4.anilist.co/banner/1.jpg',
    );
  }

  /// 获取的完整一步：记录认领横幅 + 贴成背景图。
  Future<bool> fetchBanner(String bookKey, {List<int>? cover}) async {
    final bool applied = await store.applyBanner(
      bookKey,
      bannerSource,
      url: kBannerUrl,
    );
    await store.write(
      record: record(bookKey, bannerKey: applied ? 'mangabaka_1' : null),
      coverBytes: cover,
    );
    return applied;
  }

  test('写入后 hasCover / coverFileFor / recordFor 命中；重开实例从磁盘读回', () async {
    expect(store.hasCover('a'), isFalse);
    await store.write(record: record('a'), coverBytes: png(4, 6));
    expect(store.hasCover('a'), isTrue);
    expect(store.coverFileFor('a')!.existsSync(), isTrue);
    expect(store.recordFor('a')!.seriesId, '42');
    expect(store.recordFor('a')!.usesMangaBaka, isTrue);

    BookArtStore.resetForTesting();
    final BookArtStore reopened = open();
    expect(reopened.hasCover('a'), isTrue);
    expect(reopened.recordFor('a')!.coverUrl, 'https://images.example/a');
  });

  test('解码不了的字节不落盘，旧卷封面不动', () async {
    await store.write(record: record('a'), coverBytes: png(4, 6, shade: 9));
    final List<int> before = store.coverFileFor('a')!.readAsBytesSync();
    await expectLater(
      store.write(record: record('a'), coverBytes: <int>[1, 2, 3, 4]),
      throwsA(anything),
    );
    expect(store.coverFileFor('a')!.readAsBytesSync(), before);
  });

  test('横幅贴成书的背景图：同 URL 各卷共用一个文件，书详情页读得到', () async {
    final ItemScrapeKey a = await seed('a');
    final ItemScrapeKey b = await seed('b');
    expect(await fetchBanner('a'), isTrue);
    expect(await fetchBanner('b'), isTrue);

    final ItemImageRow rowA = (await backdrop(a))!;
    final ItemImageRow rowB = (await backdrop(b))!;
    expect(rowA.sourceUrl, kBannerUrl);
    expect(rowA.path, rowB.path, reason: '同系列横幅只存一份');
    expect(File(rowA.path).existsSync(), isTrue);
    expect(await store.bannerStateOf('a'), BookArtBannerState.fetched);

    // 书详情页 / 首页单本卡读的就是这一份（ItemScrapeDetail / getItemImages）。
    final ItemScrapeDetail detail = await ItemScrapeDetail.load(db, a);
    expect(detail.backdropPath, rowA.path);
  });

  test('覆盖策略：书已有别处来的背景图时不覆盖，也不认领', () async {
    final ItemScrapeKey a = await seed('a');
    final String foreign = await foreignBackdrop(a);
    expect(await store.bannerStateOf('a'), BookArtBannerState.other);

    expect(await fetchBanner('a'), isFalse);
    expect((await backdrop(a))!.path, foreign);
    expect(store.recordFor('a')!.bannerKey, isNull);
    expect(await store.bannerStateOf('a'), BookArtBannerState.other);
  });

  test('清除只撤本层贴的横幅：共用文件随最后一行回收，别处来的背景图不动', () async {
    final ItemScrapeKey a = await seed('a');
    final ItemScrapeKey b = await seed('b');
    final ItemScrapeKey c = await seed('c');
    await fetchBanner('a', cover: png(4, 6));
    await fetchBanner('b');
    final String shared = (await backdrop(a))!.path;
    // c 记录里也记着这张横幅，但之后被书籍刮削换成了自己的背景图。
    await fetchBanner('c');
    final String foreign = await foreignBackdrop(c);
    expect(await store.bannerStateOf('c'), BookArtBannerState.other);

    await store.remove('a');
    expect(store.hasCover('a'), isFalse);
    expect(store.recordFor('a'), isNull);
    expect(await backdrop(a), isNull);
    expect(File(shared).existsSync(), isTrue, reason: 'b 还在用');

    await store.remove('b');
    expect(await backdrop(b), isNull);
    expect(File(shared).existsSync(), isFalse);

    await store.remove('c');
    expect((await backdrop(c))!.path, foreign);
    expect(File(foreign).existsSync(), isTrue);
  });

  test('单本否决：卷封面与本层横幅撤掉，只留否决记录；JSON 往返保留', () async {
    final ItemScrapeKey a = await seed('a');
    await fetchBanner('a', cover: png(4, 6));
    await store.rejectCover('a');
    expect(store.hasCover('a'), isFalse);
    expect(await backdrop(a), isNull);
    expect(store.recordFor('a')!.hasSeries, isFalse);
    expect(store.recordFor('a')!.rejectedCoverUrls, <String>[
      'https://images.example/a',
    ]);
    BookArtStore.resetForTesting();
    final BookArtStore reopened = open();
    expect(reopened.recordFor('a')!.rejectedCoverUrls, <String>[
      'https://images.example/a',
    ]);
  });

  test('快照 → 覆盖写 → 恢复：卷封面字节与元数据回到快照', () async {
    await store.write(
      record: record('a', scrapedAt: 1),
      coverBytes: png(4, 6, shade: 1),
    );
    final List<int> original = store.coverFileFor('a')!.readAsBytesSync();
    final BookArtSnapshot snap = await store.snapshot('a');
    await store.write(
      record: record('a', scrapedAt: 2, source: 'bangumi'),
      coverBytes: png(8, 12, shade: 200),
    );
    final Map<String, Object?> after = await store.fingerprint('a');
    expect(after['scrapedAt'], 2);

    // 快照过 JSON 往返（撤销载荷持久化后同一形态）。
    await store.restore(BookArtSnapshot.fromJson(snap.toJson()));
    expect(store.coverFileFor('a')!.readAsBytesSync(), original);
    expect(store.recordFor('a')!.scrapedAt, 1);
    expect(store.recordFor('a')!.source, 'mangabaka');
    expect(await store.fingerprint('a'), isNot(after));
  });

  test('从无到有的写入，恢复 = 清除（连同贴上的横幅）', () async {
    final ItemScrapeKey a = await seed('a');
    final BookArtSnapshot snap = await store.snapshot('a');
    await fetchBanner('a', cover: png(4, 6));
    await store.restore(snap);
    expect(store.hasCover('a'), isFalse);
    expect(store.recordFor('a'), isNull);
    expect(await backdrop(a), isNull);
  });

  test('备份文件不在时恢复抛 StateError，不拿别的图凑数', () async {
    await store.write(record: record('a'), coverBytes: png(4, 6));
    final BookArtSnapshot snap = await store.snapshot('a');
    await File(snap.coverBackupPath!).delete();
    await expectLater(store.restore(snap), throwsStateError);
  });

  test('清除后撤销：横幅从备份贴回背景图（清除时共用文件已回收）', () async {
    final ItemScrapeKey a = await seed('a');
    await fetchBanner('a', cover: png(4, 6));
    final String shared = (await backdrop(a))!.path;
    final BookArtSnapshot snap = await store.snapshot('a');
    expect(snap.bannerBackupPath, isNotNull);
    await store.remove('a');
    expect(File(shared).existsSync(), isFalse);
    expect(await store.canRestore(snap), isTrue);

    await store.restore(BookArtSnapshot.fromJson(snap.toJson()));
    final ItemImageRow row = (await backdrop(a))!;
    expect(row.sourceUrl, kBannerUrl);
    expect(File(row.path).existsSync(), isTrue);
    expect(await store.bannerStateOf('a'), BookArtBannerState.fetched);
    expect(store.hasCover('a'), isTrue);
  });

  test('别处换了背景图后指纹变化（撤销据此判 superseded）', () async {
    final ItemScrapeKey a = await seed('a');
    await fetchBanner('a');
    final Map<String, Object?> after = await store.fingerprint('a');
    await foreignBackdrop(a);
    expect(await store.fingerprint('a'), isNot(after));
  });

  test('备份按文件名时间戳过期，不看 copy 继承来的修改时间', () async {
    await store.write(record: record('a'), coverBytes: png(4, 6));
    await store.write(record: record('b'), coverBytes: png(4, 6, shade: 3));
    // 封面写于很久以前：File.copy 在 Windows / macOS 上会把这个修改时间带给备份。
    final DateTime old = DateTime(2020);
    await File(store.coverPathFor('a')).setLastModified(old);
    await File(store.coverPathFor('b')).setLastModified(old);
    final BookArtSnapshot first = await store.snapshot('a');
    // 第二本的 snapshot 会先 prune：不能把第一本刚做的备份当过期删掉。
    await store.snapshot('b');
    expect(File(first.coverBackupPath!).existsSync(), isTrue);
    expect(await store.canRestore(first), isTrue);
  });

  test('编辑弹窗展示的记录：有卷封面或只有横幅都算，只剩否决记录不算', () async {
    expect(store.displayableRecordFor('none'), isNull);

    await store.write(record: record('cover'), coverBytes: png(4, 6));
    expect(store.displayableRecordFor('cover')!.seriesId, '42');

    // 本地更清晰时只贴了横幅：没有卷封面文件，仍要能看到来源 / 署名并移除。
    await seed('banner');
    await fetchBanner('banner');
    expect(store.hasCover('banner'), isFalse);
    expect(store.displayableRecordFor('banner')!.usesMangaBaka, isTrue);

    await store.rejectCover('cover');
    expect(store.recordFor('cover'), isNotNull);
    expect(store.displayableRecordFor('cover'), isNull);
  });

  group('旧版 scraped_banners/ 一次性搬家', () {
    late Directory legacy;

    /// 旧版（BUG-5609 前）写下的记录：没有 `bannerOnBackdrop`，横幅在旧目录里。
    void writeLegacy(String bookKey, {required String bannerKey}) {
      Directory(p.join(thumbs.path, 'scraped')).createSync(recursive: true);
      final Map<String, Object?> json = record(
        bookKey,
        bannerKey: bannerKey,
      ).toJson()..remove('bannerOnBackdrop');
      File(
        '${store.coverPathFor(bookKey)}.json',
      ).writeAsStringSync(jsonEncode(json));
    }

    setUp(() {
      legacy = Directory(p.join(thumbs.path, 'scraped_banners'))
        ..createSync(recursive: true);
      File(p.join(legacy.path, 'mangabaka_1')).writeAsBytesSync(png(16, 9));
    });

    test('没有背景图的书贴上；已有别处来的保留并去掉记录认领；旧目录删掉', () async {
      final ItemScrapeKey a = await seed('a');
      final ItemScrapeKey b = await seed('b');
      final ItemScrapeKey c = await seed('c');
      final String foreign = await foreignBackdrop(c);
      for (final String k in <String>['a', 'b', 'c', 'gone']) {
        writeLegacy(k, bannerKey: 'mangabaka_1');
      }
      // 横幅文件已经不在的旧记录。
      writeLegacy('d', bannerKey: 'mangabaka_404');
      await seed('d');

      BookArtStore.resetForTesting();
      final BookArtStore migrated = open();
      await migrated.migrateLegacyBanners();

      expect(legacy.existsSync(), isFalse);
      final ItemImageRow rowA = (await backdrop(a))!;
      expect(rowA.sourceUrl, kBannerUrl);
      expect((await backdrop(b))!.path, rowA.path);
      expect(File(rowA.path).existsSync(), isTrue);
      expect(migrated.recordFor('a')!.bannerKey, 'mangabaka_1');
      expect(await migrated.bannerStateOf('a'), BookArtBannerState.fetched);

      expect((await backdrop(c))!.path, foreign);
      expect(migrated.recordFor('c')!.bannerKey, isNull);
      expect(migrated.recordFor('gone')!.bannerKey, isNull);
      expect(migrated.recordFor('d')!.bannerKey, isNull);

      // 书详情页 / 首页读同一份。
      expect((await ItemScrapeDetail.load(db, a)).backdropPath, rowA.path);
    });

    test('搬家后清除只撤搬进去的横幅；再跑一次是空操作', () async {
      final ItemScrapeKey a = await seed('a');
      writeLegacy('a', bannerKey: 'mangabaka_1');
      await store.migrateLegacyBanners();
      expect(await backdrop(a), isNotNull);

      await store.remove('a');
      expect(await backdrop(a), isNull);
      await store.migrateLegacyBanners();
      expect(await backdrop(a), isNull);
    });

    test('写入口先等搬家跑完：直接清除也会撤掉旧横幅', () async {
      final ItemScrapeKey a = await seed('a');
      writeLegacy('a', bannerKey: 'mangabaka_1');
      await store.remove('a');
      expect(await backdrop(a), isNull);
      expect(legacy.existsSync(), isFalse);
    });

    // BUG-5609 审查：删旧目录失败（文件被占着）后重跑，不能把已搬过、之后被用户
    // 清掉的横幅再贴回去——进度按记录落盘，不只靠旧目录在不在。
    test('逐条推进：旧目录没删掉时重跑，已搬过又被清掉的横幅不复活', () async {
      final ItemScrapeKey a = await seed('a');
      writeLegacy('a', bannerKey: 'mangabaka_1');
      await store.migrateLegacyBanners();
      expect(await backdrop(a), isNotNull);
      expect(store.recordFor('a')!.bannerOnBackdrop, isTrue);
      // 模拟「删旧目录失败」：旧目录与横幅文件都还在。
      legacy.createSync(recursive: true);
      File(p.join(legacy.path, 'mangabaka_1')).writeAsBytesSync(png(16, 9));
      // 用户在书详情页清掉了背景图。
      await itemScrape.clearImage(a, MediaImageKind.backdrop);

      BookArtStore.resetForTesting();
      final BookArtStore rerun = open();
      await rerun.migrateLegacyBanners();
      expect(await backdrop(a), isNull);
      expect(legacy.existsSync(), isFalse);
    });

    // BUG-5609 审查：「书没有背景图」的判断与贴图必须原子——期间插进来的书籍刮削
    // 不能被搬家覆盖。各种起跑先后都以书籍刮削那张收场。
    test('搬家与同时进行的书籍刮削：别处来的背景图永不被覆盖', () async {
      for (int round = 0; round < 6; round++) {
        final String k = 'r$round';
        final ItemScrapeKey key = await seed(k);
        legacy.createSync(recursive: true);
        File(p.join(legacy.path, 'mangabaka_1')).writeAsBytesSync(png(16, 9));
        writeLegacy(k, bannerKey: 'mangabaka_1');
        BookArtStore.resetForTesting();
        final BookArtStore migrating = open();
        final File src = File(p.join(thumbs.path, 'scrape_$round.png'))
          ..writeAsBytesSync(png(20, 9, shade: 90));
        late String foreign;
        Future<void> later(int ticks, Future<void> Function() body) async {
          for (int i = 0; i < ticks; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          await body();
        }

        await Future.wait(<Future<void>>[
          later(round % 3, migrating.migrateLegacyBanners),
          later(round ~/ 3 * 2, () async {
            foreign = await itemScrape.setImageFromFile(
              key,
              MediaImageKind.backdrop,
              src,
              sourceUrl: 'https://s4.anilist.co/banner/$round.jpg',
            );
          }),
        ]);
        expect((await backdrop(key))!.path, foreign, reason: 'round $round');
        expect(
          await migrating.bannerStateOf(k),
          BookArtBannerState.other,
          reason: 'round $round',
        );
      }
    });
  });

  // BUG-5609 审查：归属不单看 source_url。书籍刮削 / 手选恰好用了与获取同一个横幅
  // URL 时，那张背景图仍是它们的：清除不撤、获取不当成自己的覆盖。
  test('同 URL 的别处背景图不算本层的：清除不撤，指纹能区分', () async {
    final ItemScrapeKey a = await seed('a');
    await fetchBanner('a');
    final Map<String, Object?> after = await store.fingerprint('a');
    final File src = File(p.join(thumbs.path, 'picked.png'))
      ..writeAsBytesSync(png(20, 9, shade: 40));
    final String picked = await itemScrape.setImageFromFile(
      a,
      MediaImageKind.backdrop,
      src,
      sourceUrl: kBannerUrl,
    );
    expect(await store.bannerStateOf('a'), BookArtBannerState.other);
    expect(await store.fingerprint('a'), isNot(after));
    expect(
      await store.applyBanner(
        'a',
        bannerSource,
        url: 'https://images.mangabaka.dev/banner/2',
        ownedUrl: kBannerUrl,
      ),
      isFalse,
    );
    await store.remove('a');
    expect((await backdrop(a))!.path, picked);
    expect(File(picked).existsSync(), isTrue);
  });

  // BUG-5609 审查：撤销时背景图位置已被别处的图占着，横幅贴不回去——记录也不能
  // 照快照写回横幅四项（否则署名 / 清除认领一张不是本层写的图）。
  test('撤销时横幅贴不回去（位置被别处占着）：记录不写回横幅', () async {
    final ItemScrapeKey a = await seed('a');
    await fetchBanner('a', cover: png(4, 6));
    final BookArtSnapshot snap = await store.snapshot('a');
    await store.remove('a');
    final String foreign = await foreignBackdrop(a);

    await store.restore(snap);
    expect((await backdrop(a))!.path, foreign);
    expect(store.hasCover('a'), isTrue);
    expect(store.recordFor('a')!.seriesId, '42');
    expect(store.recordFor('a')!.bannerKey, isNull);
    expect(store.recordFor('a')!.bannerUrl, isNull);
    expect(await store.bannerStateOf('a'), BookArtBannerState.other);
  });

  // BUG-5609 审查：一次获取 / 清除整套几十卷，横幅备份按内容只存一份，各卷快照
  // 共用；恢复完一卷不能删掉别的卷还要用的那份。修改时间随每次被用到刷新，过期
  // 清理照常回收。
  test('横幅备份按内容共用一份，逐卷恢复都拿得到，过期照常清理', () async {
    DateTime clock = DateTime(2026, 11, 1);
    BookArtStore.resetForTesting();
    store = BookArtStore.of(
      thumbs,
      database: db,
      itemScrape: itemScrape,
      now: () => clock,
    );
    final ItemScrapeKey a = await seed('a');
    final ItemScrapeKey b = await seed('b');
    await fetchBanner('a');
    await fetchBanner('b');
    final BookArtSnapshot snapA = await store.snapshot('a');
    final BookArtSnapshot snapB = await store.snapshot('b');
    expect(snapA.bannerBackupPath, isNotNull);
    expect(snapB.bannerBackupPath, snapA.bannerBackupPath);
    final Directory backups = Directory(
      p.join(thumbs.path, 'undo_backups', 'book_art'),
    );
    expect(
      backups.listSync().whereType<File>().map((File f) => p.basename(f.path)),
      <String>[p.basename(snapA.bannerBackupPath!)],
    );

    await store.remove('a');
    await store.remove('b');
    await store.restore(snapA);
    expect(await store.canRestore(snapB), isTrue);
    await store.restore(snapB);
    expect((await backdrop(a))!.sourceUrl, kBannerUrl);
    expect((await backdrop(b))!.path, (await backdrop(a))!.path);
    expect(File(snapA.bannerBackupPath!).existsSync(), isTrue);

    // 过期：31 天后再做快照时清理掉没人再用的横幅备份。
    clock = clock.add(const Duration(days: 31));
    await store.write(record: record('c'), coverBytes: png(4, 6));
    await store.snapshot('c');
    expect(File(snapA.bannerBackupPath!).existsSync(), isFalse);
  });
}
