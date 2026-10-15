import 'package:fushi_engine/media/collections/book_series_key.dart';

/// 书架上一张已归属合集的卡（[key] 是书架折叠键 `'<mediaType>|<entryKey>'`）。
typedef SeriesCollectionMember = ({
  String key,
  String title,
  int collectionId,
  int sortIndex,
});

/// 书架上一张没有合集归属、等待按系列归位的卡。
typedef SeriesLooseVolume = ({String key, String title});

/// 归位结果：[collectionIdByKey] 只含被归位的散卡；[sortIndexByKey] 覆盖受影响合集的
/// **全部**成员（原成员按原序，散卡按卷号插进去后整体重编 0..n-1）。
typedef SeriesCollectionPlacement = ({
  Map<String, int> collectionIdByKey,
  Map<String, int> sortIndexByKey,
});

/// 把书架上的散卡按系列键（[parseBookSeriesKey]）放进已有的同系列合集——**只用于
/// 显示**，不落库。
///
/// 用途：互联 / 云盘的远端占位卡。本地分卷由 `BookSeriesGrouper` 持久归组，但远端
/// 占位卡本机没有行，归组碰不到；对端没把它归进合集（对端还没跑过归组、旧版 host、
/// 无头服务端）时清单不带 `collection`，占位卡就散在同系列合集旁边（「志乃と恋」
/// 1–2 卷成组、3–4 卷两张散卡）。下载入库后由归组器持久收进同一个合集。
///
/// 判据与 `BookSeriesGrouper` 同源：目标合集是**同系列成员 ≥2** 的合集（一卷碰巧在
/// 主题合集里不算），多个时取成员最多者、再取 id 小者；组内按卷号插入（无卷号当第 0
/// 卷，与本地成员同卷号时排在其后），不动原成员的相对顺序（用户手排过的序保留）。
SeriesCollectionPlacement placeLooseVolumesInSeriesCollections({
  required List<SeriesCollectionMember> members,
  required List<SeriesLooseVolume> loose,
}) {
  final Map<String, int> collectionIdByKey = <String, int>{};
  final Map<String, int> sortIndexByKey = <String, int>{};
  if (loose.isEmpty || members.isEmpty) {
    return (
      collectionIdByKey: collectionIdByKey,
      sortIndexByKey: sortIndexByKey,
    );
  }

  final Map<String, num?> memberVolume = <String, num?>{};
  final Map<String, Map<int, int>> hits = <String, Map<int, int>>{};
  for (final SeriesCollectionMember m in members) {
    final BookSeriesKey? k = parseBookSeriesKey(m.title);
    if (k == null) continue;
    memberVolume[m.key] = k.volume ?? 0;
    hits
        .putIfAbsent(k.key, () => <int, int>{})
        .update(m.collectionId, (int c) => c + 1, ifAbsent: () => 1);
  }
  final Map<String, int> collectionBySeries = <String, int>{};
  hits.forEach((String series, Map<int, int> byCollection) {
    int? best;
    byCollection.forEach((int cid, int count) {
      if (count < 2) return;
      final int? b = best;
      if (b == null ||
          count > byCollection[b]! ||
          (count == byCollection[b]! && cid < b)) {
        best = cid;
      }
    });
    if (best != null) collectionBySeries[series] = best!;
  });

  final Map<int, List<({String key, num volume})>> incoming =
      <int, List<({String key, num volume})>>{};
  for (final SeriesLooseVolume v in loose) {
    final BookSeriesKey? k = parseBookSeriesKey(v.title);
    if (k == null) continue;
    final int? cid = collectionBySeries[k.key];
    if (cid == null) continue;
    collectionIdByKey[v.key] = cid;
    incoming.putIfAbsent(cid, () => <({String key, num volume})>[]).add((
      key: v.key,
      volume: k.volume ?? 0,
    ));
  }

  incoming.forEach((int cid, List<({String key, num volume})> volumes) {
    volumes.sort((a, b) {
      final int c = a.volume.compareTo(b.volume);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    final List<SeriesCollectionMember> locals = <SeriesCollectionMember>[
      for (final SeriesCollectionMember m in members)
        if (m.collectionId == cid) m,
    ]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final List<String> merged = <String>[];
    int next = 0;
    for (final SeriesCollectionMember m in locals) {
      final num? lv = memberVolume[m.key];
      if (lv != null) {
        while (next < volumes.length && volumes[next].volume < lv) {
          merged.add(volumes[next++].key);
        }
      }
      merged.add(m.key);
    }
    while (next < volumes.length) {
      merged.add(volumes[next++].key);
    }
    for (int i = 0; i < merged.length; i++) {
      sortIndexByKey[merged[i]] = i;
    }
  });
  return (collectionIdByKey: collectionIdByKey, sortIndexByKey: sortIndexByKey);
}
