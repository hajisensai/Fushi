/// 本机播放器记下的每集**真实片长**（BUG-3491）。
///
/// `video_books` 没有片长列：库里只有断点（`lastPositionMs`）和一次性的看完标记
/// （`completedAt`）。缺了片长，下游两件事都做不对：
///
/// * 合集续播分不清「已打勾的集**重看到一半**」与「已看完」（[CollectionMemberProgress.isRewatching]）
///   ——重看第 12 集退出后「继续观看」直接跳到第 13 集；
/// * 集卡只能写「看到 19:35」，算不出观看百分比（刮削资料的整分钟片长只覆盖刮过的作品）。
///
/// 播放器每打开一集就知道精确时长，第一次落断点时顺手记一笔。按视频稳定身份
/// bookUid 键控，与断点镜像键 `video_remote_position_<uid>`、覆盖并集键
/// `video_watch_coverage_<uid>` 同一种「每视频一个偏好」的存放形态，不动 schema。
/// 片长是文件事实、不会因重看改变，所以只在变化时重写。
library;

import 'package:fushi_core/fushi_core.dart' show FushiDatabase, PrefCodec;

/// 片长偏好键前缀；值是 int 毫秒。
const String kVideoDurationPrefPrefix = 'video_duration_ms_';

/// [bookUid] 的片长偏好键。
String videoDurationPrefKey(String bookUid) =>
    '$kVideoDurationPrefPrefix$bookUid';

/// 偏好原值（[PrefCodec] 解码前 / 后均可）→ 片长毫秒；非正数或解析不出 → null。
int? videoDurationMsFromPref(Object? raw) {
  final Object? value = raw is String ? PrefCodec.decodeUntyped(raw) : raw;
  final int? ms = switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
  return ms != null && ms > 0 ? ms : null;
}

/// 一次取回全部已知片长（bookUid → 毫秒）。详情页一次 `LIKE` 查完，不按集 N+1。
Future<Map<String, int>> loadKnownVideoDurationsMs(FushiDatabase db) async {
  final Map<String, String> raw = await db.getPrefsByPrefix(
    kVideoDurationPrefPrefix,
  );
  return <String, int>{
    for (final MapEntry<String, String> entry in raw.entries)
      if (videoDurationMsFromPref(entry.value) case final int ms)
        entry.key.substring(kVideoDurationPrefPrefix.length): ms,
  };
}
