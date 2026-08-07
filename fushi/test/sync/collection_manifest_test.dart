import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/collection_manifest.dart';

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

  // ── finding 2：publishedAt 字段编解码 ────────────────────────────────────
  test('publishedAt roundtrip：墓碑/合集级删除的发布戳无损，缺省不写', () {
    final CollectionManifest m = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'P',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            // 已发布（带 publishedAt）。
            CollectionMemberTombstone(
                mediaType: 'video',
                entryKey: 'pub',
                removedAt: 100,
                publishedAt: 150),
            // 未发布（publishedAt 缺省 null，toJson 不写该字段）。
            CollectionMemberTombstone(
                mediaType: 'video', entryKey: 'unpub', removedAt: 200),
          ],
        ),
        const CollectionManifestEntry(
          name: 'D',
          collectionType: 'collection',
          deletedAt: 300,
          deletedPublishedAt: 350,
        ),
      ],
    );
    final CollectionManifest decoded =
        CollectionManifest.fromJson(jsonDecode(m.canonicalJson()));
    expect(decoded.canonicalJson(), m.canonicalJson(), reason: '字节等价');

    final CollectionManifestEntry p = decoded.collections
        .firstWhere((CollectionManifestEntry e) => e.name == 'P');
    final CollectionMemberTombstone pub =
        p.memberTombstones.firstWhere((t) => t.entryKey == 'pub');
    final CollectionMemberTombstone unpub =
        p.memberTombstones.firstWhere((t) => t.entryKey == 'unpub');
    expect(pub.publishedAt, 150);
    expect(unpub.publishedAt, isNull, reason: '缺省 publishedAt 解码为 null');

    final CollectionManifestEntry d = decoded.collections
        .firstWhere((CollectionManifestEntry e) => e.name == 'D');
    expect(d.deletedPublishedAt, 350);
  });

  // ── finding 12：负时间戳拒绝 + 非法条目跳过发布 ──────────────────────────
  test('负 removedAt / 负 publishedAt / 负 deletedAt 一律 FormatException', () {
    Object entryWith(Map<String, dynamic> tomb) => <String, dynamic>{
          'version': 1,
          'collections': <Object?>[
            <String, dynamic>{
              'name': 'X',
              'collectionType': 'collection',
              'members': <Object?>[],
              'memberTombstones': <Object?>[tomb],
            },
          ],
        };
    expect(
        () => CollectionManifest.fromJson(entryWith(<String, dynamic>{
              'mediaType': 'epub',
              'entryKey': 'z',
              'removedAt': -1,
            })),
        throwsFormatException,
        reason: '负 removedAt（历史 `(lt ?? -1)` 哨兵撞车会崩）');
    expect(
        () => CollectionManifest.fromJson(entryWith(<String, dynamic>{
              'mediaType': 'epub',
              'entryKey': 'z',
              'removedAt': 5,
              'publishedAt': -9,
            })),
        throwsFormatException,
        reason: '负 publishedAt');
    expect(
        () => CollectionManifest.fromJson(<String, dynamic>{
              'version': 1,
              'collections': <Object?>[
                <String, dynamic>{
                  'name': 'X',
                  'collectionType': 'collection',
                  'deletedAt': -3,
                  'members': <Object?>[],
                  'memberTombstones': <Object?>[],
                },
              ],
            }),
        throwsFormatException,
        reason: '负 deletedAt');
  });

  // ── finding 1：文件级 lastWrittenAt 编解码 + 不进 canonicalJson ──────────────
  test('lastWrittenAt roundtrip via toJson，且不参与 canonicalJson（幂等）', () {
    final CollectionManifest m = CollectionManifest(
      lastWrittenAt: 4242,
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'collection',
          members: <CollectionManifestMember>[
            CollectionManifestMember(
                mediaType: 'epub', entryKey: 'x', sortIndex: 0),
          ],
        ),
      ],
    );
    // toJson 携带 lastWrittenAt（写盘用）；fromJson 无损解回。
    expect(m.toJson()['lastWrittenAt'], 4242);
    final CollectionManifest decoded = CollectionManifest.fromJson(m.toJson());
    expect(decoded.lastWrittenAt, 4242);

    // canonicalJson 不含 lastWrittenAt：两份 lastWrittenAt 不同但内容相同的清单
    // canonical 字节相等（否则每轮写盘时戳变化会破坏「内容相等 ⇒ 跳过回写」的幂等）。
    final CollectionManifest other = m.withLastWrittenAt(9999);
    expect(other.canonicalJson(), m.canonicalJson(),
        reason: 'lastWrittenAt 不进内容等价判据');
    expect(m.canonicalJson().contains('lastWrittenAt'), isFalse);
  });

  test('缺 / 非法 lastWrittenAt 解码为 0（向后兼容，恒陈旧）', () {
    // 旧清单无该字段。
    final CollectionManifest legacy = CollectionManifest.fromJson(
        <String, dynamic>{'version': 1, 'collections': <Object?>[]});
    expect(legacy.lastWrittenAt, 0);
    // 负值 / 非 int 一律 0（不因脏字段拒绝解析）。
    final CollectionManifest negative =
        CollectionManifest.fromJson(<String, dynamic>{
      'version': 1,
      'lastWrittenAt': -5,
      'collections': <Object?>[],
    });
    expect(negative.lastWrittenAt, 0);
  });

  test('toJson 跳过非法条目：空自然键合集 / 空键成员 / 空键墓碑不发布毒害对端', () {
    final CollectionManifest dirty = CollectionManifest(
      collections: <CollectionManifestEntry>[
        // 空 name 合集：整条不发布。
        const CollectionManifestEntry(name: '', collectionType: 'collection'),
        CollectionManifestEntry(
          name: 'Good',
          collectionType: 'collection',
          members: const <CollectionManifestMember>[
            CollectionManifestMember(
                mediaType: '', entryKey: 'x', sortIndex: 0), // 空 mediaType
            CollectionManifestMember(
                mediaType: 'epub', entryKey: 'y', sortIndex: 1), // 合法
          ],
          memberTombstones: const <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'epub', entryKey: '', removedAt: 5), // 空 entryKey
          ],
        ),
      ],
    );
    // 关键：脏清单编码后必须能被严格 codec 无异常解回（证明没发布非法条目）。
    final CollectionManifest reparsed =
        CollectionManifest.fromJson(jsonDecode(dirty.canonicalJson()));
    expect(reparsed.collections, hasLength(1), reason: '空 name 合集被跳过');
    final CollectionManifestEntry good = reparsed.collections.single;
    expect(good.name, 'Good');
    expect(good.members.map((m) => m.entryKey).toList(), <String>['y'],
        reason: '空键成员被跳过，只剩合法成员');
    expect(good.memberTombstones, isEmpty, reason: '空键墓碑被跳过');
  });

  // ── 合集标签（collection-tags §5.2）：tagNames additive 字段 codec ──────────
  test('tagNames round-trips through toJson/fromJson', () {
    const entry = CollectionManifestEntry(
      name: 'C',
      collectionType: 'collection',
      members: <CollectionManifestMember>[
        CollectionManifestMember(
            mediaType: 'video', entryKey: 'u1', sortIndex: 0),
      ],
      tagNames: <String>['zebra', 'alpha'],
    );
    final decoded = CollectionManifestEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())));
    expect(decoded.tagNames, <String>['alpha', 'zebra']); // 排序确定性
  });

  test('missing tagNames decodes to empty (backward compat)', () {
    final decoded = CollectionManifestEntry.fromJson(<String, dynamic>{
      'name': 'C',
      'collectionType': 'collection',
      'members': <dynamic>[],
      'memberTombstones': <dynamic>[],
    });
    expect(decoded.tagNames, isEmpty);
  });

  test('empty tagNames omits key (byte-identical to pre-feature)', () {
    const entry =
        CollectionManifestEntry(name: 'C', collectionType: 'collection');
    expect(entry.toJson().containsKey('tagNames'), isFalse);
  });
}
