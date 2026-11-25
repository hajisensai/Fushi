import 'package:fushi_engine/media/metadata/book_art/anilist_banner.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:fushi_engine/media/metadata/books/book_catalog.dart';
import 'package:test/test.dart';

BookCatalogRecord _record({
  String id = '72451',
  String title = 'ホリミヤ',
  String? originalTitle = 'Horimiya',
  String? author = '萩原ダイスケ, HERO',
  BookCatalogFormat? format = BookCatalogFormat.manga,
  bool isAdult = false,
  String? bannerUrl = 'https://s4.anilist.co/banner/72451.jpg',
}) => BookCatalogRecord(
  id: id,
  title: title,
  originalTitle: originalTitle,
  author: author,
  format: format,
  isAdult: isAdult,
  bannerUrl: bannerUrl,
);

BookCatalogRecord? _pick(
  List<BookCatalogRecord> records, {
  List<String> titles = const <String>['ホリミヤ'],
  BookArtCandidateKind kind = BookArtCandidateKind.manga,
  String? author = 'HERO',
}) => pickAniListSameWork(
  seriesTitles: titles,
  kind: kind,
  author: author,
  records: records,
);

void main() {
  group('aniListBookKind', () {
    test('漫画 / 韩漫 / 国漫 / 短篇算漫画，轻小说算小说，认不出算 other', () {
      expect(
        aniListBookKind(BookCatalogFormat.manga),
        BookArtCandidateKind.manga,
      );
      expect(
        aniListBookKind(BookCatalogFormat.manhwa),
        BookArtCandidateKind.manga,
      );
      expect(
        aniListBookKind(BookCatalogFormat.oneShot),
        BookArtCandidateKind.manga,
      );
      expect(
        aniListBookKind(BookCatalogFormat.novel),
        BookArtCandidateKind.novel,
      );
      expect(aniListBookKind(null), BookArtCandidateKind.other);
    });
  });

  group('aniListBannerOption', () {
    test('有横幅出 AniList 候选图（尺寸未知）', () {
      final BookArtImageOption? o = aniListBannerOption(_record());
      expect(o?.source, BookArtSource.anilist);
      expect(o?.url, 'https://s4.anilist.co/banner/72451.jpg');
      expect(o?.hasSize, isFalse);
    });

    test('没有横幅 / 成人向为 null', () {
      expect(aniListBannerOption(_record(bannerUrl: null)), isNull);
      expect(aniListBannerOption(_record(isAdult: true)), isNull);
    });
  });

  group('pickAniListSameWork', () {
    test('唯一严格同名、同种类、作者不冲突：采用', () {
      expect(_pick(<BookCatalogRecord>[_record()])?.id, '72451');
    });

    test('罗马字写法严格同名也算', () {
      expect(
        _pick(<BookCatalogRecord>[_record()], titles: <String>['Horimiya'])?.id,
        '72451',
      );
    });

    test('同名但种类不同（轻小说）、成人向、副标题衍生作：都不算', () {
      expect(
        _pick(<BookCatalogRecord>[
          _record(id: '1', format: BookCatalogFormat.novel),
          _record(id: '2', isAdult: true),
          _record(id: '3', title: 'ホリミヤ 外伝', originalTitle: null),
        ]),
        isNull,
      );
    });

    test('作者明确不同：不算；AniList 没写作者：不算冲突', () {
      expect(
        _pick(<BookCatalogRecord>[_record(author: 'Someone Else')]),
        isNull,
      );
      expect(_pick(<BookCatalogRecord>[_record(author: null)])?.id, '72451');
    });

    test('同名同种类两条（重名作品）：不猜，返回 null', () {
      expect(
        _pick(<BookCatalogRecord>[_record(id: '1'), _record(id: '2')]),
        isNull,
      );
    });

    test('同一条目重复出现不算重名', () {
      expect(_pick(<BookCatalogRecord>[_record(), _record()])?.id, '72451');
    });

    test('系列种类认不出（other）：不取', () {
      expect(
        _pick(<BookCatalogRecord>[_record()], kind: BookArtCandidateKind.other),
        isNull,
      );
    });

    test('唯一的同一部作品没有横幅：照样返回它（调用方看出没有横幅就不取）', () {
      final BookCatalogRecord? r = _pick(<BookCatalogRecord>[
        _record(bannerUrl: null),
      ]);
      expect(r?.id, '72451');
      expect(aniListBannerOption(r!), isNull);
    });
  });

  test('BookArtSource.tryParseSeries 不收 anilist（不能钉死系列）', () {
    expect(BookArtSource.tryParse('anilist'), BookArtSource.anilist);
    expect(BookArtSource.tryParseSeries('anilist'), isNull);
    expect(BookArtSource.tryParseSeries('bangumi'), BookArtSource.bangumi);
    expect(BookArtSource.tryParseSeries('mangabaka'), BookArtSource.mangabaka);
  });
}
