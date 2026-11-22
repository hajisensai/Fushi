/// 首页（[HomeDashboardPage]）的派生数据：按输入身份记忆的计算结果与视频行索引。
///
/// 首页 build 频繁（`ref.watch(appProvider)` 任一通知、封面解析 / 系列元数据到达
/// 的 setState……），此前每次 build 都把「继续」「最近添加」「近 7 天柱条」从整库
/// 行重算一遍，且逐行拼 `MediaKind.compositeKey` 查合集归属（「继续」每张视频卡
/// 取封面还要把整个视频库扫一遍找同合集的其它集）——实测 1400 视频 / 84 合集的库
/// 切回首页每帧 30–90 ms。这里把这些派生量收成「输入不变就复用」：
/// - [HomeDashboardMemo]：按依赖列表逐项身份比对的单槽记忆；
/// - [HomeDashboardVideoIndex]：每轮视频行 + 合集归属只建一次的索引（合集 →
///   成员、合集 → 组内序排好的成员、散视频），取代逐条全库扫描。
library;

import 'package:fushi_core/fushi_core.dart' show MediaKind, VideoBookRow;

/// 单槽记忆：[get] 的依赖列表与上次逐项相同（引用身份；字符串 / 数值 / 布尔 /
/// 枚举按值）就直接返回上次的结果，否则重算并记住。
///
/// 依赖传的是派生量的**全部**输入：列表 / Map 等按身份比对，所以调用方必须保证
/// 输入「内容变了就换新对象」（首页的状态字段都是整份替换、从不原地改）。
class HomeDashboardMemo<T> {
  List<Object?>? _deps;
  T? _value;

  /// 依赖与上次相同则返回缓存，否则调用 [compute] 重算。
  T get(List<Object?> deps, T Function() compute) {
    final List<Object?>? prev = _deps;
    if (prev != null && homeDashboardSameDeps(prev, deps)) return _value as T;
    final T value = compute();
    _deps = List<Object?>.unmodifiable(deps);
    _value = value;
    return value;
  }

  /// 丢掉缓存（下次 [get] 必定重算）。
  void clear() {
    _deps = null;
    _value = null;
  }
}

/// 两份依赖列表是否逐项相同：值类型（字符串 / 数值 / 布尔 / 枚举）按 `==`，其余
/// 按引用身份（集合类的 `==` 就是身份，内容比对正是要省掉的开销）。
bool homeDashboardSameDeps(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final Object? x = a[i];
    final Object? y = b[i];
    if (identical(x, y)) continue;
    final bool valueLike =
        (x is String && y is String) ||
        (x is num && y is num) ||
        (x is bool && y is bool) ||
        (x is Enum && y is Enum);
    if (!valueLike || x != y) return false;
  }
  return true;
}

/// 一轮视频行在合集维度上的索引（[HomeDashboardVideoIndex.build] 一次 O(n)）。
///
/// 口径与首页原先逐处现算的完全一致：
/// - 归属 = `primaryCollectionByEntry['video|<bookUid>']`（主折叠合集）；
/// - [membersOf] / [standalone] 保持 [videos] 的原顺序，[collectionIds] 按首次
///   出现的顺序（与原先边扫边建 `Map` 的插入序相同）；
/// - [sortedMembersOf]：组内 sortIndex（缺失沉底 `1 << 30`）→ bookUid 排序。
class HomeDashboardVideoIndex {
  HomeDashboardVideoIndex._({
    required this.videos,
    required this.primaryCollectionByEntry,
    required this.memberSortIndex,
    required List<VideoBookRow> standalone,
    required Map<int, List<VideoBookRow>> byCollection,
    required Map<String, int> collectionByUid,
    required Map<String, int> sortIndexByUid,
  }) : _standalone = standalone,
       _byCollection = byCollection,
       _collectionByUid = collectionByUid,
       _sortIndexByUid = sortIndexByUid;

  /// 建索引：每行只拼一次复合键。
  factory HomeDashboardVideoIndex.build({
    required List<VideoBookRow> videos,
    required Map<String, int> primaryCollectionByEntry,
    required Map<String, int> memberSortIndex,
  }) {
    final List<VideoBookRow> standalone = <VideoBookRow>[];
    final Map<int, List<VideoBookRow>> byCollection =
        <int, List<VideoBookRow>>{};
    final Map<String, int> collectionByUid = <String, int>{};
    final Map<String, int> sortIndexByUid = <String, int>{};
    for (final VideoBookRow v in videos) {
      final String key = MediaKind.video.compositeKey(v.bookUid);
      final int? sortIndex = memberSortIndex[key];
      if (sortIndex != null) sortIndexByUid[v.bookUid] = sortIndex;
      final int? cid = primaryCollectionByEntry[key];
      if (cid == null) {
        standalone.add(v);
      } else {
        collectionByUid[v.bookUid] = cid;
        (byCollection[cid] ??= <VideoBookRow>[]).add(v);
      }
    }
    return HomeDashboardVideoIndex._(
      videos: videos,
      primaryCollectionByEntry: primaryCollectionByEntry,
      memberSortIndex: memberSortIndex,
      standalone: standalone,
      byCollection: byCollection,
      collectionByUid: collectionByUid,
      sortIndexByUid: sortIndexByUid,
    );
  }

  /// 建索引时的三份输入（[isFor] 按身份比对）。
  final List<VideoBookRow> videos;
  final Map<String, int> primaryCollectionByEntry;
  final Map<String, int> memberSortIndex;

  final List<VideoBookRow> _standalone;
  final Map<int, List<VideoBookRow>> _byCollection;
  final Map<String, int> _collectionByUid;
  final Map<String, int> _sortIndexByUid;
  final Map<int, List<VideoBookRow>> _sortedByCollection =
      <int, List<VideoBookRow>>{};

  /// 组内序缺失时的沉底值（与书架 / 视频页同口径）。
  static const int missingSortIndex = 1 << 30;

  /// 这份索引是否正是由这三份输入建的。
  bool isFor(
    List<VideoBookRow> videos,
    Map<String, int> primaryCollectionByEntry,
    Map<String, int> memberSortIndex,
  ) =>
      identical(this.videos, videos) &&
      identical(this.primaryCollectionByEntry, primaryCollectionByEntry) &&
      identical(this.memberSortIndex, memberSortIndex);

  /// 不在任何合集里的视频（[videos] 原顺序）。
  List<VideoBookRow> get standalone => _standalone;

  /// 有成员的合集 id（首次出现顺序）。
  Iterable<int> get collectionIds => _byCollection.keys;

  /// 合集 → 成员（[videos] 原顺序）；未知合集返回空表。
  List<VideoBookRow> membersOf(int collectionId) =>
      _byCollection[collectionId] ?? const <VideoBookRow>[];

  /// 这条视频的主折叠合集；不在合集里为 null。
  int? collectionOf(String bookUid) => _collectionByUid[bookUid];

  /// 这条视频在主合集里的组内序；缺失为 [missingSortIndex]。
  int sortIndexOf(String bookUid) =>
      _sortIndexByUid[bookUid] ?? missingSortIndex;

  /// 合集成员按组内序（缺失沉底）→ bookUid 排好（首次访问时排一次，之后复用）。
  List<VideoBookRow> sortedMembersOf(int collectionId) =>
      _sortedByCollection[collectionId] ??= List<VideoBookRow>.unmodifiable(
        List<VideoBookRow>.of(membersOf(collectionId))
          ..sort((VideoBookRow a, VideoBookRow b) {
            final int ai = sortIndexOf(a.bookUid);
            final int bi = sortIndexOf(b.bookUid);
            if (ai != bi) return ai.compareTo(bi);
            return a.bookUid.compareTo(b.bookUid);
          }),
      );

  /// 同一主合集里除 [except] 外其它集的封面路径（[videos] 原顺序）。
  List<String?> memberCoversOf(int collectionId, {required String except}) =>
      <String?>[
        for (final VideoBookRow v in membersOf(collectionId))
          if (v.bookUid != except) v.coverPath,
      ];
}
