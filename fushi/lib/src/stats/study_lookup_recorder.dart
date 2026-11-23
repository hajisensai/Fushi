import 'package:fushi_audio/fushi_audio_core.dart'
    show creditLookupToRunningStudyClock;
import 'package:fushi_core/fushi_core.dart';

/// 记一次查词的**唯一入口**（app 层；拍板台 4KOWK3c2mn 方案 b，2026-11-23）。
///
/// 查词归属的媒体（[bookKey] 非空）在本进程里有正在计时的 `StudyClock` 时，查词记进
/// 那只时钟的当前段（`study_segments.lookups`）：与字数 / 时长同一行、同一小时粒度，
/// 编辑会话改日期时一起平移、删会话时一起写零、同步走段的 uid LWW。
///
/// 否则（无书查词、时钟停着、浮窗 / 副屏等别的进程、身份对不上）照旧记按天的
/// `lookup_mining_counters`（[FushiDatabase.addLookupCount]，dateKey 由 [at] 经
/// [FushiDatabase.statDateKeyOf] 派生）。两处互斥写入，读取面相加
/// （`StatCounterFacts.lookupCounters`），不双计。
///
/// [sourceType] 与段的 `media_kind` 同值域（[kStatSourceBook] / [kStatSourceVideo] /
/// [kStatSourceGame] / [kStatSourceMusic]）。时钟分支是同步的、不做 IO；计数表分支
/// 返回 DB 写的 future，调用方按各自的 best-effort 口径处理异常。
Future<void> recordStudyLookup(
  FushiDatabase db, {
  required String? bookKey,
  required String title,
  required String sourceType,
  required DateTime at,
}) {
  final String key = bookKey ?? '';
  if (key.isNotEmpty &&
      creditLookupToRunningStudyClock(mediaKind: sourceType, mediaKey: key)) {
    return Future<void>.value();
  }
  return db.addLookupCount(
    bookKey: bookKey,
    title: title,
    sourceType: sourceType,
    dateKey: FushiDatabase.statDateKeyOf(at),
  );
}
