import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';
import 'package:fushi/src/pages/implementations/manga_hibiki_page.dart';

void main() {
  group('mangaWindowRange', () {
    test('窗口在起点被 clamp', () {
      expect(
        MangaHibikiPage.mangaWindowRange(
            spreadCount: 10, current: 0, radius: 1),
        <int>[0, 1],
      );
    });

    test('窗口居中', () {
      expect(
        MangaHibikiPage.mangaWindowRange(
            spreadCount: 10, current: 5, radius: 1),
        <int>[4, 5, 6],
      );
    });

    test('窗口在终点被 clamp', () {
      expect(
        MangaHibikiPage.mangaWindowRange(
            spreadCount: 10, current: 9, radius: 1),
        <int>[8, 9],
      );
    });

    test('单 spread 书绝不越界', () {
      expect(
        MangaHibikiPage.mangaWindowRange(spreadCount: 1, current: 0, radius: 2),
        <int>[0],
      );
    });

    test('零页书回空', () {
      expect(
        MangaHibikiPage.mangaWindowRange(spreadCount: 0, current: 0, radius: 1),
        isEmpty,
      );
    });
  });

  group('spread index <-> page', () {
    test('double 布局无偏移：0/1、2/3 配对', () {
      final List<MangaSpreadEntry> spreads = buildMangaSpreads(
        4,
        layout: MangaPageLayout.double,
        spreadOffset: 0,
      );
      expect(MangaHibikiPage.firstPageOfSpread(spreads, 0), 0);
      expect(MangaHibikiPage.firstPageOfSpread(spreads, 1), 2);
      expect(MangaHibikiPage.spreadIndexForPage(spreads, 3), 1);
    });

    test('single 布局：spread 序号 == 页码', () {
      final List<MangaSpreadEntry> spreads = buildMangaSpreads(
        3,
        layout: MangaPageLayout.single,
        spreadOffset: 0,
      );
      for (int i = 0; i < 3; i++) {
        expect(MangaHibikiPage.firstPageOfSpread(spreads, i), i);
        expect(MangaHibikiPage.spreadIndexForPage(spreads, i), i);
      }
    });
  });

  group('mangaProgressForSpread', () {
    final List<MangaSpreadEntry> spreads = buildMangaSpreads(
      6,
      layout: MangaPageLayout.double,
      spreadOffset: 0,
    );

    test('spread 模式落 spread 首页页码，fraction 钉 0', () {
      final (int page, double fraction) =
          MangaHibikiPage.mangaProgressForSpread(spreads, 2,
              webtoonFraction: 0.5, isWebtoon: false);
      expect(page, 4); // spread 2 -> pages 4/5
      expect(fraction, 0.0);
    });

    test('webtoon 模式落 top 页 + 页内 fraction', () {
      final (int page, double fraction) =
          MangaHibikiPage.mangaProgressForSpread(spreads, 2,
              webtoonFraction: 0.5, isWebtoon: true);
      expect(page, 4);
      expect(fraction, 0.5);
    });
  });

  group('restoreSpreadFromProgress', () {
    final List<MangaSpreadEntry> spreads = buildMangaSpreads(
      6,
      layout: MangaPageLayout.double,
      spreadOffset: 0,
    );

    test('持久化页码映射回所属 spread', () {
      expect(MangaHibikiPage.restoreSpreadFromProgress(spreads, 4), 2);
      expect(MangaHibikiPage.restoreSpreadFromProgress(spreads, 5), 2);
      expect(MangaHibikiPage.restoreSpreadFromProgress(spreads, 0), 0);
    });

    test('越界存档 clamp 到末 spread', () {
      expect(MangaHibikiPage.restoreSpreadFromProgress(spreads, 999),
          spreads.length - 1);
    });

    test('空书回 0', () {
      expect(
        MangaHibikiPage.restoreSpreadFromProgress(
            const <MangaSpreadEntry>[], 3),
        0,
      );
    });
  });

  group('阅读模式覆盖', () {
    test('toggleMangaMode 双向翻转', () {
      expect(MangaHibikiPage.toggleMangaMode(MangaReadingMode.spread),
          MangaReadingMode.webtoon);
      expect(MangaHibikiPage.toggleMangaMode(MangaReadingMode.webtoon),
          MangaReadingMode.spread);
    });

    test('模式 <-> DB 字符串双向映射', () {
      expect(MangaHibikiPage.modeToDbString(MangaReadingMode.spread), 'spread');
      expect(
          MangaHibikiPage.modeToDbString(MangaReadingMode.webtoon), 'webtoon');
      expect(MangaHibikiPage.modeFromDbString('webtoon'),
          MangaReadingMode.webtoon);
      expect(
          MangaHibikiPage.modeFromDbString('spread'), MangaReadingMode.spread);
      expect(MangaHibikiPage.modeFromDbString('???'), MangaReadingMode.spread);
    });

    test('modeOverrideFromDb：null/空 = 自动判定（回 null）', () {
      expect(MangaHibikiPage.modeOverrideFromDb(null), isNull);
      expect(MangaHibikiPage.modeOverrideFromDb(''), isNull);
      expect(MangaHibikiPage.modeOverrideFromDb('spread'),
          MangaReadingMode.spread);
      expect(MangaHibikiPage.modeOverrideFromDb('webtoon'),
          MangaReadingMode.webtoon);
    });
  });

  group('webtoon fraction <-> charOffset（千分比 0..1000）', () {
    test('往返换算', () {
      expect(MangaHibikiPage.webtoonFractionToCharOffset(0), 0);
      expect(MangaHibikiPage.webtoonFractionToCharOffset(0.5), 500);
      expect(MangaHibikiPage.webtoonFractionToCharOffset(1.0), 1000);
      expect(MangaHibikiPage.charOffsetToWebtoonFraction(500), 0.5);
      expect(MangaHibikiPage.charOffsetToWebtoonFraction(1000), 1.0);
    });

    test('脏值容错（越界/负值/null clamp）', () {
      expect(MangaHibikiPage.webtoonFractionToCharOffset(-0.5), 0);
      expect(MangaHibikiPage.webtoonFractionToCharOffset(1.5), 1000);
      expect(MangaHibikiPage.charOffsetToWebtoonFraction(null), 0);
      expect(MangaHibikiPage.charOffsetToWebtoonFraction(-1), 0);
      expect(MangaHibikiPage.charOffsetToWebtoonFraction(99999), 1.0);
    });

    test('恢复语义：round-trip 后落回同一 fraction（千分之一精度）', () {
      for (final double f in <double>[0.0, 0.123, 0.5, 0.999, 1.0]) {
        final int stored = MangaHibikiPage.webtoonFractionToCharOffset(f);
        final double restored =
            MangaHibikiPage.charOffsetToWebtoonFraction(stored);
        expect((restored - f).abs() <= 0.0005, isTrue,
            reason: 'fraction $f 存取往返漂移超过千分之一（stored=$stored）');
      }
    });
  });

  group('mangaImageUrl', () {
    test('逐段 percent-encode，保留 / 结构（与拦截器 decodeComponent 对称）', () {
      expect(MangaHibikiPage.mangaImageUrl('p001.jpg'),
          'https://manga.local/img/p001.jpg');
      expect(MangaHibikiPage.mangaImageUrl('vol 1/p 01.jpg'),
          'https://manga.local/img/vol%201/p%2001.jpg');
      expect(MangaHibikiPage.mangaImageUrl('images/p001.jpg'),
          'https://manga.local/img/p001.jpg');
      expect(MangaHibikiPage.mangaImageUrl(r'.\images\p001.jpg'),
          'https://manga.local/img/p001.jpg');
      // 子目录结构保留（不被整体 encode 成 %2F）。
      expect(
          MangaHibikiPage.mangaImageUrl('a/b/c.png').contains('%2F'), isFalse);
    });
  });
}
