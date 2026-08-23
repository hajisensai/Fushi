import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_scrape_metadata_compat.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    collectionId = await db.createMediaCollection('历史合集');
  });

  tearDown(() => db.close());

  Future<void> seed({
    required String source,
    String? tagsJson,
    String? infoboxJson,
  }) =>
      db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(collectionId),
          source: source,
          subjectId: '42',
          title: '历史标题',
          tagsJson: Value<String?>(tagsJson),
          infoboxJson: Value<String?>(infoboxJson),
          scrapedAt: DateTime(2026, 1, 1),
        ),
      );

  test('历史来源、标签和 infobox 继续可读', () async {
    await seed(
      source: 'bangumi',
      tagsJson: '[{"name":"奇幻","count":12}]',
      infoboxJson: '[{"key":"导演","value":"某导演"}]',
    );

    final ScrapeMetadata meta = decodeCollectionScrapeMeta(
      await db.getCollectionScrapeMeta(collectionId),
    )!;
    expect(meta.source, ScrapeSource.bangumi);
    expect(meta.tags.single.name, '奇幻');
    expect(meta.infobox.single.value, '某导演');
  });

  test('未知来源保持本地语义，损坏 JSON 只丢对应列表', () async {
    await seed(
      source: 'retired-provider',
      tagsJson: '{broken',
      infoboxJson: 'not-a-list',
    );

    final ScrapeMetadata meta = decodeCollectionScrapeMeta(
      await db.getCollectionScrapeMeta(collectionId),
    )!;
    expect(meta.source, ScrapeSource.local);
    expect(meta.tags, isEmpty);
    expect(meta.infobox, isEmpty);
  });
}
