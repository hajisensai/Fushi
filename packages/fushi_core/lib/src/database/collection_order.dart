/// 合集成员顺序的**纯规则**：身份键类型 + 保序合并。
///
/// 存在理由（BUG-1194 根因）：合集详情页天然只渲染成员的一个**子集**——视频合集
/// 详情页按 mediaType 过滤（只显示 video），书架网格详情页按标签过滤。用户在子集上
/// 拖出的新顺序，必须先合并回**全表**顺序才能落盘；否则未被点名的成员留着旧
/// sortIndex，与新写的致密 `0..n-1` 碰撞，`getCollectionItems` 平手退化按 entryKey
/// 排，用户在别处排好的跨种类顺序就被静默打乱。
///
/// 这条规则原本被复制在两个页面里（且各写各的身份键），本文件是唯一真相源：
/// [FushiDatabase.reorderCollectionItems] 用它守住落盘不变量，页面用它维护内存
/// 展示序，两侧同一份实现不会漂开。
library;

/// 合集成员的身份键：`(mediaType, entryKey)` 记录。
///
/// **值相等的 record，不是拼分隔符的字符串**：entryKey 是用户数据（epub=bookKey /
/// srt=uid / video=bookUid / game=galgames.id，其中不乏路径与用户命名），任何分隔符
/// 都可能出现在数据里造成歧义碰撞。record 的相等性按字段逐个比，无此风险。
typedef CollectionMemberKey = ({String mediaType, String entryKey});

/// 保序合并：把「一部分成员的新相对顺序」合并回全表顺序。
///
/// [all] 是合集当前的**全表**顺序，[subset] 是其中一部分成员被重排后的新相对顺序，
/// [keyOf] 把元素映射到身份键。返回新的全表顺序：[all] 中被 [subset] 点名的**槽位**
/// 按 [subset] 的顺序依次填入，未点名的成员**留在其原槽位**。
///
/// 「留在原槽位」而不是「挤到表尾」是关键：筛选态下若把隐藏成员挤到末尾，一次拖拽
/// 就会把全部隐藏成员从原位冲到表尾落盘。
///
/// 健壮性（调用方无需自己过滤）：
/// - [subset] 里不在 [all] 中的键（并发移出）被丢弃；
/// - [subset] 里的重复键只认第一次出现。
///
/// 二者保证「被点名的槽位数」恒等于「有效 subset 长度」，合并时不会越界。
/// [all] 内部键唯一是表约束（`media_collection_items` 复合主键含 mediaType +
/// entryKey），故同一槽位不会被重复点名。
List<T> mergeCollectionOrder<T>({
  required List<T> all,
  required List<T> subset,
  required CollectionMemberKey Function(T item) keyOf,
}) {
  final Set<CollectionMemberKey> allKeys = <CollectionMemberKey>{
    for (final T item in all) keyOf(item),
  };
  // named 与 namedKeys 一起建：能进 named 的元素其键恰好进 namedKeys（add 返回 true
  // 才收），故 named.length == namedKeys.length。
  final Set<CollectionMemberKey> namedKeys = <CollectionMemberKey>{};
  final List<T> named = <T>[
    for (final T item in subset)
      if (allKeys.contains(keyOf(item)) && namedKeys.add(keyOf(item))) item,
  ];
  int next = 0;
  return <T>[
    for (final T item in all)
      if (namedKeys.contains(keyOf(item))) named[next++] else item,
  ];
}
