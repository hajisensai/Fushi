import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';

void main() {
  group('mangaWindowRange', () {
    test('窗口在起点被 clamp', () {
      expect(
        MangaFushiPage.mangaWindowRange(
            spreadCount: 10, current: 0, radius: 1),
        <int>[0, 1],
      );
    });

    test('窗口居中', () {
      expect(
        MangaFushiPage.mangaWindowRange(
            spreadCount: 10, current: 5, radius: 1),
        <int>[4, 5, 6],
      );
    });

    test('窗口在终点被 clamp', () {
      expect(
        MangaFushiPage.mangaWindowRange(
            spreadCount: 10, current: 9, radius: 1),
        <int>[8, 9],
      );
    });

    test('单 spread 书绝不越界', () {
      expect(
        MangaFushiPage.mangaWindowRange(spreadCount: 1, current: 0, radius: 2),
        <int>[0],
      );
    });

    test('零页书回空', () {
      expect(
        MangaFushiPage.mangaWindowRange(spreadCount: 0, current: 0, radius: 1),
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
      expect(MangaFushiPage.firstPageOfSpread(spreads, 0), 0);
      expect(MangaFushiPage.firstPageOfSpread(spreads, 1), 2);
      expect(MangaFushiPage.spreadIndexForPage(spreads, 3), 1);
    });

    test('single 布局：spread 序号 == 页码', () {
      final List<MangaSpreadEntry> spreads = buildMangaSpreads(
        3,
        layout: MangaPageLayout.single,
        spreadOffset: 0,
      );
      for (int i = 0; i < 3; i++) {
        expect(MangaFushiPage.firstPageOfSpread(spreads, i), i);
        expect(MangaFushiPage.spreadIndexForPage(spreads, i), i);
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
          MangaFushiPage.mangaProgressForSpread(spreads, 2,
              webtoonFraction: 0.5, isWebtoon: false);
      expect(page, 4); // spread 2 -> pages 4/5
      expect(fraction, 0.0);
    });

    test('webtoon 模式落 top 页 + 页内 fraction', () {
      final (int page, double fraction) =
          MangaFushiPage.mangaProgressForSpread(spreads, 2,
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
      expect(MangaFushiPage.restoreSpreadFromProgress(spreads, 4), 2);
      expect(MangaFushiPage.restoreSpreadFromProgress(spreads, 5), 2);
      expect(MangaFushiPage.restoreSpreadFromProgress(spreads, 0), 0);
    });

    test('越界存档 clamp 到末 spread', () {
      expect(MangaFushiPage.restoreSpreadFromProgress(spreads, 999),
          spreads.length - 1);
    });

    test('空书回 0', () {
      expect(
        MangaFushiPage.restoreSpreadFromProgress(
            const <MangaSpreadEntry>[], 3),
        0,
      );
    });
  });

  group('阅读模式覆盖', () {
    test('toggleMangaMode 双向翻转', () {
      expect(MangaFushiPage.toggleMangaMode(MangaReadingMode.spread),
          MangaReadingMode.webtoon);
      expect(MangaFushiPage.toggleMangaMode(MangaReadingMode.webtoon),
          MangaReadingMode.spread);
    });

    test('模式 <-> DB 字符串双向映射', () {
      expect(MangaFushiPage.modeToDbString(MangaReadingMode.spread), 'spread');
      expect(
          MangaFushiPage.modeToDbString(MangaReadingMode.webtoon), 'webtoon');
      expect(MangaFushiPage.modeFromDbString('webtoon'),
          MangaReadingMode.webtoon);
      expect(
          MangaFushiPage.modeFromDbString('spread'), MangaReadingMode.spread);
      expect(MangaFushiPage.modeFromDbString('???'), MangaReadingMode.spread);
    });

    test('modeOverrideFromDb：null/空 = 自动判定（回 null）', () {
      expect(MangaFushiPage.modeOverrideFromDb(null), isNull);
      expect(MangaFushiPage.modeOverrideFromDb(''), isNull);
      expect(MangaFushiPage.modeOverrideFromDb('spread'),
          MangaReadingMode.spread);
      expect(MangaFushiPage.modeOverrideFromDb('webtoon'),
          MangaReadingMode.webtoon);
    });
  });

  group('webtoon fraction <-> charOffset（千分比 0..1000）', () {
    test('往返换算', () {
      expect(MangaFushiPage.webtoonFractionToCharOffset(0), 0);
      expect(MangaFushiPage.webtoonFractionToCharOffset(0.5), 500);
      expect(MangaFushiPage.webtoonFractionToCharOffset(1.0), 1000);
      expect(MangaFushiPage.charOffsetToWebtoonFraction(500), 0.5);
      expect(MangaFushiPage.charOffsetToWebtoonFraction(1000), 1.0);
    });

    test('脏值容错（越界/负值/null clamp）', () {
      expect(MangaFushiPage.webtoonFractionToCharOffset(-0.5), 0);
      expect(MangaFushiPage.webtoonFractionToCharOffset(1.5), 1000);
      expect(MangaFushiPage.charOffsetToWebtoonFraction(null), 0);
      expect(MangaFushiPage.charOffsetToWebtoonFraction(-1), 0);
      expect(MangaFushiPage.charOffsetToWebtoonFraction(99999), 1.0);
    });

    test('恢复语义：round-trip 后落回同一 fraction（千分之一精度）', () {
      for (final double f in <double>[0.0, 0.123, 0.5, 0.999, 1.0]) {
        final int stored = MangaFushiPage.webtoonFractionToCharOffset(f);
        final double restored =
            MangaFushiPage.charOffsetToWebtoonFraction(stored);
        expect((restored - f).abs() <= 0.0005, isTrue,
            reason: 'fraction $f 存取往返漂移超过千分之一（stored=$stored）');
      }
    });
  });

  group('mangaImageUrl', () {
    test('逐段 percent-encode，保留 / 结构（与拦截器 decodeComponent 对称）', () {
      expect(MangaFushiPage.mangaImageUrl('p001.jpg'),
          'https://manga.local/img/p001.jpg');
      expect(MangaFushiPage.mangaImageUrl('vol 1/p 01.jpg'),
          'https://manga.local/img/vol%201/p%2001.jpg');
      expect(MangaFushiPage.mangaImageUrl('images/p001.jpg'),
          'https://manga.local/img/p001.jpg');
      expect(MangaFushiPage.mangaImageUrl(r'.\images\p001.jpg'),
          'https://manga.local/img/p001.jpg');
      // 子目录结构保留（不被整体 encode 成 %2F）。
      expect(
          MangaFushiPage.mangaImageUrl('a/b/c.png').contains('%2F'), isFalse);
    });
  });
}
