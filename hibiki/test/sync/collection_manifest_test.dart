import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';

/// 合集清单编解码纯函数测试（多端库联合视图 §2.3 任务3）：
/// roundtrip 无损 + 确定性排序（内容相等 ⇒ 字节相等）+ 非法输入拒绝。
void main() {
  CollectionManifest sample({bool shuffled = false}) {
    final List<CollectionManifestMember> members = <CollectionManifestMember>[
      const CollectionManifestMember(
          mediaType: 'video', entryKey: 'v1', sortIndex: 0),
      const CollectionManifestMember(
          mediaType: 'epub', entryKey: 'b1', sortIndex: 1),
      const CollectionManifestMember(
          mediaType: 'video', entryKey: 'v2', sortIndex: 2),
    ];
    final List<CollectionMemberTombstone> tombs = <CollectionMemberTombstone>[
      const CollectionMemberTombstone(
          mediaType: 'video', entryKey: 'gone1', removedAt: 111),
      const CollectionMemberTombstone(
          mediaType: 'epub', entryKey: 'gone2', removedAt: 222),
    ];
    final List<CollectionManifestEntry> entries = <CollectionManifestEntry>[
      CollectionManifestEntry(
        name: '番剧',
        collectionType: 'playlist',
        orderUpdatedAt: 1000,
        members: shuffled ? members.reversed.toList() : members,
        memberTombstones: shuffled ? tombs.reversed.toList() : tombs,
      ),
      const CollectionManifestEntry(
        name: '已删',
        collectionType: 'collection',
        deletedAt: 999,
      ),
      const CollectionManifestEntry(
        name: '收藏',
        collectionType: 'collection',
        members: <CollectionManifestMember>[
          CollectionManifestMember(
              mediaType: 'epub', entryKey: 'x', sortIndex: 0),
        ],
      ),
    ];
    return CollectionManifest(
      collections: shuffled ? entries.reversed.toList() : entries,
    );
  }

  test('roundtrip 无损：decode(encode(m)) 与 m 字节等价', () {
    final CollectionManifest m = sample();
    final CollectionManifest decoded =
        CollectionManifest.fromJson(jsonDecode(m.canonicalJson()));
    expect(decoded.canonicalJson(), m.canonicalJson());
    expect(decoded.version, CollectionManifest.currentVersion);
    expect(decoded.collections, hasLength(3));

    final CollectionManifestEntry playlist = decoded.collections
        .firstWhere((CollectionManifestEntry e) => e.name == '番剧');
    expect(playlist.orderUpdatedAt, 1000);
    expect(playlist.deletedAt, isNull);
    expect(playlist.members.map((m) => m.entryKey).toList(),
        <String>['v1', 'b1', 'v2'],
        reason: '成员按 sortIndex 序');
    expect(playlist.memberTombstones, hasLength(2));

    final CollectionManifestEntry dead = decoded.collections
        .firstWhere((CollectionManifestEntry e) => e.name == '已删');
    expect(dead.deletedAt, 999);
    expect(dead.members, isEmpty);
  });

  test('确定性排序：乱序输入产出相同 canonical 字节', () {
    expect(sample(shuffled: true).canonicalJson(), sample().canonicalJson(),
        reason: '合集按自然键、成员按 sortIndex、墓碑按成员键排序——'
            '内容相等必须字节相等（同步靠它跳过无意义回写）');
  });

  test('空清单与 version 字段', () {
    final Map<String, dynamic> json = CollectionManifest.empty.toJson();
    expect(json['version'], CollectionManifest.currentVersion);
    expect(json['collections'], isEmpty);
    final CollectionManifest decoded = CollectionManifest.fromJson(json);
    expect(decoded.collections, isEmpty);
  });

  test('非法输入拒绝（FormatException），不静默吞坏清单', () {
    expect(() => CollectionManifest.fromJson(null), throwsFormatException);
    expect(() => CollectionManifest.fromJson('nope'), throwsFormatException);
    expect(() => CollectionManifest.fromJson(<String, dynamic>{}),
        throwsFormatException);
    expect(
        () => CollectionManifest.fromJson(<String, dynamic>{
              'version': 1,
              'collections': 'not a list',
            }),
        throwsFormatException);
    expect(
        () => CollectionManifest.fromJson(<String, dynamic>{
              'version': 1,
              'collections': <Object?>[
                <String, dynamic>{'name': '', 'collectionType': 'collection'}
              ],
            }),
        throwsFormatException,
        reason: '空自然键非法');
  });

  test('更新版清单拒绝解析（保护新端数据不被旧语义降级回写）', () {
    expect(
        () => CollectionManifest.fromJson(<String, dynamic>{
              'version': CollectionManifest.currentVersion + 1,
              'collections': <Object?>[],
            }),
        throwsFormatException);
  });
}
