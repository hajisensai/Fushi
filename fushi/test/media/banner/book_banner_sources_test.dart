import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/book_banner_sources.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';

/// 书 / 漫画「横幅…」的在线来源：认系列（刮削资料来源 id、追踪映射链接）→ AniList
/// `bannerImage` + MangaBaka 全部横幅；认不出时按书名搜；某个源失败不挡别的源。
class _FakeScraper extends BookMetadataScraper {
  final List<String> calls = <String>[];
  bool failMangaBaka = false;

  @override
  Future<BookScrapeCandidate?> fetchCatalogById(
    BookScrapeSource source,
    String id,
  ) async {
    calls.add('anilist:$id');
    return BookScrapeCandidate(
      subjectId: id,
      title: 'Series $id',
      coverUrl: 'https://img.example/cover-$id.jpg',
      source: BookScrapeSource.anilist,
      bannerUrl: 'https://img.example/anilist-$id.jpg',
    );
  }

  @override
  Future<List<BookBannerImage>> fetchMangaBakaBanners(String seriesId) async {
    calls.add('mangabaka:$seriesId');
    if (failMangaBaka) throw const BookScrapeException('MangaBaka 503');
    return <BookBannerImage>[
      BookBannerImage(
        url: 'https://img.example/mb-$seriesId-a.jpg',
        width: 2000,
        height: 800,
        thumbnailUrl: 'https://img.example/mb-$seriesId-a-thumb.jpg',
      ),
      BookBannerImage(
        url: 'https://img.example/mb-$seriesId-b.jpg',
        width: 1600,
        height: 900,
      ),
    ];
  }

  @override
  Future<List<BookScrapeCandidate>> searchAniList(
    String keyword, {
    int limit = 10,
    bool includeNsfw = false,
  }) async {
    calls.add('search-anilist:$keyword');
    return <BookScrapeCandidate>[
      BookScrapeCandidate(
        subjectId: '7',
        title: 'Found',
        coverUrl: 'https://img.example/c7.jpg',
        source: BookScrapeSource.anilist,
        bannerUrl: 'https://img.example/anilist-7.jpg',
      ),
      const BookScrapeCandidate(
        subjectId: '8',
        title: 'No banner',
        coverUrl: 'https://img.example/c8.jpg',
        source: BookScrapeSource.anilist,
      ),
    ];
  }

  @override
  Future<List<BookScrapeCandidate>> searchMangaBaka(
    String keyword, {
    int limit = 10,
  }) async {
    calls.add('search-mangabaka:$keyword');
    return <BookScrapeCandidate>[
      const BookScrapeCandidate(
        subjectId: '55',
        title: 'MB Found',
        coverUrl: 'https://img.example/c55.jpg',
        source: BookScrapeSource.mangabaka,
      ),
    ];
  }
}

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final ItemScrapeKey key = ItemScrapeKey(MediaKind.epub, 'uid-1');

  Future<File> noDownload(String url) async => throw UnimplementedError(url);

  test('认系列：刮削资料来源 id + 追踪映射里的 AniList / MangaBaka 链接，去重', () async {
    await ItemScrapeStore(db).writeMeta(
      key,
      const ItemScrapeDetails(source: 'anilist', subjectId: '42'),
    );
    Future<void> link(String provider, int id) => db
        .into(db.mediaTrackingMappings)
        .insert(
          MediaTrackingMappingsCompanion.insert(
            provider: Value<String>(provider),
            mediaType: 'book',
            mediaKey: 'bk-1',
            mediaTitle: 'Book',
            kind: 'manga',
            subjectId: id,
            subjectName: 'S',
            progressMode: 'volume',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await link('mangabaka', 9);
    await link('anilist', 42);
    await link('bangumi', 3);

    final BookBannerSeriesIds ids = await identifyBookBannerSeries(
      db: db,
      key: key,
      bookKey: 'bk-1',
    );
    expect(ids.aniList, <String>['42']);
    expect(ids.mangaBaka, <String>['9']);
  });

  test('认出系列：AniList 横幅 + MangaBaka 全部横幅，不搜书名', () async {
    final _FakeScraper scraper = _FakeScraper();
    final List<BannerCandidate> out = await loadBookBannerOnlineCandidates(
      ids: const BookBannerSeriesIds(
        aniList: <String>['42'],
        mangaBaka: <String>['9'],
      ),
      title: 'Whatever 3',
      scraper: scraper,
      download: noDownload,
    );
    expect(
      <String>[for (final BannerCandidate c in out) c.id],
      <String>['anilist-42', 'mangabaka-9-0', 'mangabaka-9-1'],
    );
    expect(out.first.sourceUrl, 'https://img.example/anilist-42.jpg');
    expect(out[1].width, 2000);
    expect(scraper.calls.where((String c) => c.startsWith('search')), isEmpty);
  });

  test('认不出：按书名（去卷号）搜，只要带横幅的，角标写系列名', () async {
    final _FakeScraper scraper = _FakeScraper();
    final List<BannerCandidate> out = await loadBookBannerOnlineCandidates(
      ids: const BookBannerSeriesIds(),
      title: '魔女之旅 3',
      scraper: scraper,
      download: noDownload,
    );
    expect(scraper.calls, contains('search-anilist:魔女之旅'));
    expect(
      <String?>[for (final BannerCandidate c in out) c.label],
      <String?>[
        'AniList · Found',
        'MangaBaka · MB Found',
        'MangaBaka · MB Found',
      ],
    );
  });

  test('一个源失败不挡别的源；全部失败且没有候选时抛出', () async {
    final _FakeScraper scraper = _FakeScraper()..failMangaBaka = true;
    final List<BannerCandidate> out = await loadBookBannerOnlineCandidates(
      ids: const BookBannerSeriesIds(
        aniList: <String>['1'],
        mangaBaka: <String>['2'],
      ),
      title: 'x',
      scraper: scraper,
      download: noDownload,
    );
    expect(
      <String>[for (final BannerCandidate c in out) c.id],
      <String>['anilist-1'],
    );
    await expectLater(
      loadBookBannerOnlineCandidates(
        ids: const BookBannerSeriesIds(mangaBaka: <String>['2']),
        title: 'x',
        scraper: scraper,
        download: noDownload,
      ),
      throwsA(isA<BookScrapeException>()),
    );
  });
}
