import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v64 `media_collection_items.group_key` DAO 契约：
/// - addToCollection 可携带分组键落库（默认 null = 未分组）；
/// - setCollectionItemGroupKeys 只改点名成员；
/// - reorderCollectionItems 只写 sortIndex，不得抹掉分组键。
void main() {
  late HibikiDatabase db;
  late int cid;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    cid = await db.createMediaCollection('多季番', collectionType: 'playlist');
    await db.addToCollection(cid, MediaKind.video, 'v1', groupKey: 's1');
    await db.addToCollection(cid, MediaKind.video, 'v2', groupKey: 's2');
    await db.addToCollection(cid, MediaKind.video, 'v3');
  });

  tearDown(() => db.close());

  Future<Map<String, String?>> keys() async => <String, String?>{
        for (final MediaCollectionItemRow r in await db.getCollectionItems(cid))
          r.entryKey: r.groupKey,
      };

  test('addToCollection 携带 groupKey 落库；不带 = null', () async {
    expect(await keys(), <String, String?>{'v1': 's1', 'v2': 's2', 'v3': null});
  });

  test('setCollectionItemGroupKeys 只改点名成员，显式 null 清组', () async {
    await db.setCollectionItemGroupKeys(cid, <CollectionMemberKey, String?>{
      (mediaType: MediaKind.video.dbValue, entryKey: 'v3'): 'extras',
      (mediaType: MediaKind.video.dbValue, entryKey: 'v1'): null,
    });
    expect(
      await keys(),
      <String, String?>{'v1': null, 'v2': 's2', 'v3': 'extras'},
    );
  });

  test('reorderCollectionItems 重排后分组键原样保留', () async {
    await db.reorderCollectionItems(cid, <CollectionMemberKey>[
      (mediaType: MediaKind.video.dbValue, entryKey: 'v3'),
      (mediaType: MediaKind.video.dbValue, entryKey: 'v1'),
      (mediaType: MediaKind.video.dbValue, entryKey: 'v2'),
    ]);
    final List<MediaCollectionItemRow> items = await db.getCollectionItems(cid);
    expect(items.map((r) => r.entryKey), <String>['v3', 'v1', 'v2']);
    expect(await keys(), <String, String?>{'v1': 's1', 'v2': 's2', 'v3': null});
  });
}
