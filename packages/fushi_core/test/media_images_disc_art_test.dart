// 原盘盘面图（media_images kind=disc_art）由源库扫描写入，不属于刮削投影：
// 刮削整组重写图组时不能把它清掉，而它自己每个合集只留一张。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    collectionId = await db.createMediaCollection(
      'Disc',
      collectionType: 'playlist',
    );
  });

  tearDown(() => db.close());

  Future<List<(String, String)>> images() async => <(String, String)>[
    for (final MediaImageRow row in await db.getMediaImagesForCollection(
      collectionId,
    ))
      (row.kind, row.path),
  ];

  MediaImagesCompanion scraped(MediaImageKind kind, String path) =>
      MediaImagesCompanion.insert(
        collectionId: Value<int?>(collectionId),
        kind: kind.dbValue,
        path: path,
        sourceUrl: Value<String?>('https://images.example/$path'),
      );

  test('重刮整组替换只换刮削种类，盘面图留着', () async {
    await db.setCollectionDiscArt(collectionId, 'disc.jpg');
    await db
        .replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
          scraped(MediaImageKind.backdrop, 'b1.jpg'),
          scraped(MediaImageKind.titleCard, 't1.jpg'),
        ]);
    await db.replaceMediaImagesForCollection(
      collectionId,
      <MediaImagesCompanion>[scraped(MediaImageKind.backdrop, 'b2.jpg')],
    );
    expect(
      await images(),
      unorderedEquals(<(String, String)>[
        ('disc_art', 'disc.jpg'),
        ('backdrop', 'b2.jpg'),
      ]),
    );
  });

  test('盘面图每合集一张，再设置即替换', () async {
    await db.setCollectionDiscArt(collectionId, 'old.jpg');
    await db.setCollectionDiscArt(collectionId, 'new.jpg');
    expect(await images(), <(String, String)>[('disc_art', 'new.jpg')]);
    expect(
      (await db.getMediaImagesForCollection(collectionId)).single.sourceUrl,
      isNull,
      reason: 'sourceUrl=null：全量清理刮削记录时按手动附加图保留',
    );
  });

  test('旧版本读到未知种类不抛', () {
    expect(MediaImageKind.tryParse('disc_art'), MediaImageKind.discArt);
    expect(MediaImageKind.scrapeOwned, isNot(contains(MediaImageKind.discArt)));
  });
}
