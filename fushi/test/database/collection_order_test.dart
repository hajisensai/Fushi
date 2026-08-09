import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// [mergeCollectionOrder] 纯规则测试（BUG-1194 根因修复的地基）。
///
/// 这条规则同时被 `FushiDatabase.reorderCollectionItems`（守落盘不变量）和
/// `MediaCollectionGridDetailPage._onReorder`（维护内存展示序）使用，一处写错两处
/// 一起漂，所以单独直测。
CollectionMemberKey _k(String mediaType, String entryKey) =>
    (mediaType: mediaType, entryKey: entryKey);

List<CollectionMemberKey> _merge(
  List<CollectionMemberKey> all,
  List<CollectionMemberKey> subset,
) =>
    mergeCollectionOrder<CollectionMemberKey>(
      all: all,
      subset: subset,
      keyOf: (CollectionMemberKey k) => k,
    );

void main() {
  test('未点名的成员留在原槽位，点名的按 subset 顺序依次填入', () {
    // 交错基线：video / game / video / epub / video。
    final List<CollectionMemberKey> all = <CollectionMemberKey>[
      _k('video', 'v1'),
      _k('game', 'g1'),
      _k('video', 'v2'),
      _k('epub', 'e1'),
      _k('video', 'v3'),
    ];
    // 只点名三个 video，倒排。
    expect(
      _merge(all, <CollectionMemberKey>[
        _k('video', 'v3'),
        _k('video', 'v2'),
        _k('video', 'v1'),
      ]),
      <CollectionMemberKey>[
        _k('video', 'v3'),
        _k('game', 'g1'),
        _k('video', 'v2'),
        _k('epub', 'e1'),
        _k('video', 'v1'),
      ],
      reason: 'video 只在 video 槽位（0/2/4）内部换位，g1/e1 原地不动',
    );
  });

  test('未点名成员绝不被挤到表尾', () {
    final List<CollectionMemberKey> all = <CollectionMemberKey>[
      _k('game', 'g1'),
      _k('video', 'v1'),
      _k('video', 'v2'),
    ];
    // 「挤到表尾」的错误实现会得到 [v2, v1, g1]。
    expect(
      _merge(all, <CollectionMemberKey>[_k('video', 'v2'), _k('video', 'v1')]),
      <CollectionMemberKey>[
        _k('game', 'g1'),
        _k('video', 'v2'),
        _k('video', 'v1'),
      ],
      reason: '筛选态下若把隐藏成员挤到末尾，一次拖拽就会把它们从原位全冲到表尾',
    );
  });

  test('subset 点名全部成员 → 结果就是 subset 顺序（一键整理路径）', () {
    final List<CollectionMemberKey> all = <CollectionMemberKey>[
      _k('video', 'v1'),
      _k('game', 'g1'),
      _k('epub', 'e1'),
    ];
    final List<CollectionMemberKey> sorted = <CollectionMemberKey>[
      _k('epub', 'e1'),
      _k('video', 'v1'),
      _k('game', 'g1'),
    ];
    expect(_merge(all, sorted), sorted);
  });

  test('subset 为空 → 全表顺序零变化', () {
    final List<CollectionMemberKey> all = <CollectionMemberKey>[
      _k('video', 'v1'),
      _k('game', 'g1'),
    ];
    expect(_merge(all, const <CollectionMemberKey>[]), all);
  });

  test('subset 含已不在 all 中的键（并发移出）→ 丢弃，不越界', () {
    final List<CollectionMemberKey> all = <CollectionMemberKey>[
      _k('video', 'v1'),
      _k('game', 'g1'),
      _k('video', 'v3'),
    ];
    expect(
      _merge(all, <CollectionMemberKey>[
        _k('video', 'v3'),
        _k('video', 'v2'), // 已被移出
        _k('video', 'v1'),
      ]),
      <CollectionMemberKey>[
        _k('video', 'v3'),
        _k('game', 'g1'),
        _k('video', 'v1'),
      ],
    );
  });

  test('subset 含重复键 → 只认第一次出现，不越界', () {
    final List<CollectionMemberKey> all = <CollectionMemberKey>[
      _k('video', 'v1'),
      _k('game', 'g1'),
      _k('video', 'v2'),
    ];
    expect(
      _merge(all, <CollectionMemberKey>[
        _k('video', 'v2'),
        _k('video', 'v2'),
        _k('video', 'v1'),
      ]),
      <CollectionMemberKey>[
        _k('video', 'v2'),
        _k('game', 'g1'),
        _k('video', 'v1'),
      ],
    );
  });

  test('身份键是 record 不是拼串：entryKey 含分隔符也不误判同一成员', () {
    // 拼 '<mediaType>|<entryKey>' 的旧写法下，('video', 'a|b') 与 ('video|a', 'b')
    // 都拼成 'video|a|b' → 被当成同一成员，合并时槽位计数错乱。
    final List<CollectionMemberKey> all = <CollectionMemberKey>[
      _k('video', 'a|b'),
      _k('video|a', 'b'),
      _k('game', 'g1'),
    ];
    expect(
      _merge(
          all, <CollectionMemberKey>[_k('video|a', 'b'), _k('video', 'a|b')]),
      <CollectionMemberKey>[
        _k('video|a', 'b'),
        _k('video', 'a|b'),
        _k('game', 'g1'),
      ],
      reason: 'record 逐字段比较，分隔符出现在用户数据里也不歧义',
    );
  });
}
