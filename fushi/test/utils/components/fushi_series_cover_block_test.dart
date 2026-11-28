import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show galgameSeriesMeta;
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi_core/fushi_core.dart' show CollectionScrapeMetaRow;
import 'package:material_ui/material_ui.dart';

/// 系列色块共享元数据（视频库系列卡 / 书架与漫画库合集卡 / 游戏库色块卡同一份）：
/// 概览、chip、标签解析、年份解析与「有没有资料」判据。
void main() {
  CollectionScrapeMetaRow scrape({
    String? airDate,
    double? rating,
    String? tagsJson,
  }) => CollectionScrapeMetaRow(
    collectionId: 1,
    source: 'anilist',
    subjectId: '1',
    title: 'x',
    airDate: airDate,
    rating: rating,
    tagsJson: tagsJson,
    scrapedAt: DateTime(2026, 11, 16),
  );

  test('概览 = 类型前两个 · ★ 评分；chip = 年份 · 数量', () {
    final FushiSeriesMeta? meta = collectionSeriesMeta(
      scrape: scrape(
        airDate: '2014-04-01',
        rating: 8.8,
        tagsJson: '[{"name":"日常"},{"name":"喜剧"},{"name":"校园"}]',
      ),
      backdrop: null,
      countLabel: '3 卷',
    );
    expect(meta, isNotNull);
    expect(meta!.overview, '日常 / 喜剧 · ★ 8.8');
    expect(meta.chip, '2014 · 3 卷');
  });

  test('没有刮削资料也没有背景图 → null（保持原摆法）', () {
    expect(
      collectionSeriesMeta(scrape: null, backdrop: null, countLabel: '3 卷'),
      isNull,
    );
  });

  test('只有背景图也算系列：概览为空、chip 只剩数量', () {
    final FushiSeriesMeta? meta = collectionSeriesMeta(
      scrape: null,
      backdrop: MemoryImage(Uint8List(1)),
      countLabel: '2 卷',
    );
    expect(meta, isNotNull);
    expect(meta!.backdrop, isNotNull);
    expect(meta.overview, isNull);
    expect(meta.chip, '2 卷');
  });

  test('标签 JSON 坏 / 非数组 → 空表；评分 ≤0 不画', () {
    expect(fushiScrapeTagNames('{bad', limit: 2), isEmpty);
    expect(fushiScrapeTagNames('{"a":1}', limit: 2), isEmpty);
    expect(fushiSeriesOverview(rating: 0), isNull);
  });

  test('年份解析：裸年份 / 残缺日期可读，1900 以前当脏数据', () {
    expect(fushiScrapeYear('2014'), 2014);
    expect(fushiScrapeYear(' 2014-04 '), 2014);
    expect(fushiScrapeYear('1800-01-01'), isNull);
    expect(fushiScrapeYear('unknown'), isNull);
  });

  // BUG-5609 审查：合集有资料行（Bangumi 刮过）但没有背景图时，「获取各卷封面与
  // 横幅」贴在每卷上的横幅必须经借来那卷显示；书架 / 合集页 / 首页共用这一个口径。
  group('fushiCollectionSeriesInfo（合集资料 + 借来那卷）', () {
    final ImageProvider ownBackdrop = MemoryImage(Uint8List(1));
    final ImageProvider lentBackdrop = MemoryImage(Uint8List(2));
    final FushiSeriesInfo lent = (
      meta: FushiSeriesMeta(
        backdrop: lentBackdrop,
        backdropHasText: true,
        overview: 'lent',
      ),
      summary: 'lent summary',
    );

    test('合集没有资料：整份用借来的', () {
      expect(
        fushiCollectionSeriesInfo(own: null, borrowed: () => lent),
        same(lent),
      );
    });

    test('合集有背景图：只用自己的，不去借', () {
      final FushiSeriesInfo own = (
        meta: FushiSeriesMeta(backdrop: ownBackdrop, overview: 'own'),
        summary: 'own summary',
      );
      expect(
        fushiCollectionSeriesInfo(own: own, borrowed: () => fail('不该借')),
        same(own),
      );
    });

    test('合集有资料行但没有背景图：资料 / 简介用自己的，背景图借成员的', () {
      final FushiSeriesMeta ownMeta = collectionSeriesMeta(
        scrape: scrape(
          airDate: '2014-04-01',
          rating: 8.8,
          tagsJson: '[{"name":"日常"}]',
        ),
        backdrop: null,
      )!;
      final FushiSeriesInfo merged = fushiCollectionSeriesInfo(
        own: (meta: ownMeta, summary: 'own summary'),
        borrowed: () => lent,
      )!;
      expect(merged.meta.backdrop, same(lentBackdrop));
      expect(merged.meta.backdropHasText, isTrue);
      expect(merged.meta.overview, ownMeta.overview);
      expect(merged.meta.year, 2014);
      expect(merged.summary, 'own summary');
    });

    test('合集没有背景图、借来的也没有：保持自己的', () {
      const FushiSeriesInfo own = (
        meta: FushiSeriesMeta(overview: 'own'),
        summary: null,
      );
      expect(
        fushiCollectionSeriesInfo(
          own: own,
          borrowed: () =>
              (meta: const FushiSeriesMeta(overview: 'x'), summary: null),
        ),
        same(own),
      );
      expect(
        fushiCollectionSeriesInfo(own: own, borrowed: () => null),
        same(own),
      );
    });

    // 书架合集块、合集详情页 hero、首页系列合并卡都经这一个函数合并，不各写一份
    // 「own 不为 null 就不借」的判断（曾因此漏掉横幅）。
    test('三个合集资料入口都走同一个合并函数', () {
      for (final String path in <String>[
        'lib/src/pages/implementations/reader_fushi_history_page.dart',
        'lib/src/pages/implementations/media_collection_grid_detail_page.dart',
        'lib/src/pages/implementations/home_dashboard_page.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          contains('fushiCollectionSeriesInfo('),
          reason: path,
        );
      }
    });
  });

  group('galgameSeriesMeta', () {
    GalgameEntry game({
      String? releaseDate,
      GalgameMetadataDraft metadata = const GalgameMetadataDraft(),
    }) => GalgameEntry(
      id: 'g',
      name: 'G',
      exePath: r'C:\g\g.exe',
      workdir: r'C:\g',
      addedAt: DateTime(2026),
      releaseDate: releaseDate,
      metadata: metadata,
    );

    test('未刮削 → null（保持盒封摆法）', () {
      expect(galgameSeriesMeta(game()), isNull);
    });

    test('有标签 / 评分 / 发行日 → 概览与 chip', () {
      final FushiSeriesMeta? meta = galgameSeriesMeta(
        game(
          releaseDate: '2004-01-30',
          metadata: const GalgameMetadataDraft(
            tags: <String>['纯爱', '校园', '奇幻'],
            score: 8.3,
          ),
        ),
      );
      expect(meta, isNotNull);
      expect(meta!.overview, '纯爱 / 校园 · ★ 8.3');
      expect(meta.chip, '2004');
      expect(meta.backdrop, isNull);
    });
  });
}
