// 原盘「哪些标题该进库」筛选链里与盘格式无关的那几步。
//
// 蓝光（MPLS + m2ts 片段）与 DVD（title + PGC cell）的筛选链是同一套推理：去掉不可
// 能是内容的 → 合并同一内容的不同写法 → 丢掉「全部播放」→ 按相对时长取档。差别只在
// 「片段」是什么：蓝光是 `STREAM/<id>.m2ts` 的编号，DVD 是 VTS 里一段扇区范围。所以
// 这里的判据只看「片段身份的列表 + 总时长 + 章节数」，具体格式各自把自己的标题投影
// 成这三样再交进来。判据本身的取舍说明见 `bluray_disc.dart` 文件头。

/// 内容签名：片段多重集（排序后）+ 总时长。顺序被打乱的诱饵标题在这里与正片同签名。
String discContentSignature(Iterable<String> clipIds, int durationTicks) {
  final List<String> ids = clipIds.toList()..sort();
  return '${ids.join(",")}@$durationTicks';
}

/// 同签名里谁更可能是「真正那条」：章节多的优先，其次编号小的。
bool discPrefersOver({
  required int candidateChapters,
  required String candidateId,
  required int incumbentChapters,
  required String incumbentId,
}) {
  if (candidateChapters != incumbentChapters) {
    return candidateChapters > incumbentChapters;
  }
  return candidateId.compareTo(incumbentId) < 0;
}

/// [pool] 里有几条别的标题的片段集合被 [item] 严格包住（集合比较）。
int discSupersetCount<T>(
  T item,
  List<T> pool,
  List<String> Function(T value) clipIdsOf,
) {
  final Set<String> own = clipIdsOf(item).toSet();
  int count = 0;
  for (final T other in pool) {
    if (identical(other, item)) continue;
    final Set<String> ids = clipIdsOf(other).toSet();
    if (ids.isEmpty || ids.length >= own.length) continue;
    if (own.containsAll(ids)) count++;
  }
  return count;
}

/// [item] 是否只是把 [pool] 里另外两条及以上标题串起来的「全部播放」。
bool discIsPlayAllOf<T>(
  T item,
  List<T> pool,
  List<String> Function(T value) clipIdsOf,
) {
  final List<String> clips = clipIdsOf(item);
  if (clips.length < 2) return false;
  final Set<String> own = clips.toSet();
  if (own.length != clips.length) return false;

  final Set<String> covered = <String>{};
  int parts = 0;
  for (final T other in pool) {
    if (identical(other, item)) continue;
    final Set<String> ids = clipIdsOf(other).toSet();
    if (ids.isEmpty || !own.containsAll(ids)) continue;
    covered.addAll(ids);
    parts++;
  }
  return parts >= 2 && covered.length == own.length;
}

/// 相对时长下限的锚点：不是「片段集合包住另外 ≥2 条」的 play-all 形状里最长的那条；
/// 全是 play-all 形状时退回整体最长。返回 0 表示 [pool] 为空。
int discRelativeFloorAnchor<T>(
  List<T> pool,
  List<String> Function(T value) clipIdsOf,
  int Function(T value) durationOf,
) {
  int longest = 0;
  for (final T item in pool) {
    if (discSupersetCount(item, pool, clipIdsOf) >= 2) continue;
    final int duration = durationOf(item);
    if (duration > longest) longest = duration;
  }
  if (longest == 0) {
    for (final T item in pool) {
      final int duration = durationOf(item);
      if (duration > longest) longest = duration;
    }
  }
  return longest;
}
