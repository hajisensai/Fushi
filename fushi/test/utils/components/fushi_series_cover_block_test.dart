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
