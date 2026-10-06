/// 库页「重置阅读状态 / 清除观看进度」的落地层（用户 2026-10-05：「不小心点到书」
/// 之后要能把它变回没读过的样子，并可选择连学习记录一起撤掉）。
///
/// 三件事分开、各走既有的同步安全原语，**不裸删任何会被对端回灌的行**：
///
/// * **位置**（书 / 漫画 / PDF）：不删 `reader_positions` 行，而是写一条「回到开头」
///   的新位置（section 0、分数 0、精确锚 -1）并把 `updatedAt` 抬到严格新于旧行。
///   删行在两条同步通道上都会被对端原样灌回：互联三方判定把「本端无记录」判成
///   `applyRemote`（`resolveBookProgressThreeWay`），云通道把本端 null 时间戳判成
///   从云导入；写一条新位置则是「本端动过」，两边都按推送处理，对端随之归零。
///   页式阅读器（漫画 / PDF）落位置恒传 `charOffset >= 0`，所以「section 0 + 精确锚
///   缺席」这一形状只会来自本函数，书架据此把它判成未读（见
///   `ReaderFushiSource._bookToMediaItem` 的页式分支）。
/// * **读完标记**：`EpubBooks.completedAt` 置空（与「取消已读完」同一原语）。
/// * **学习记录**（可选，默认不动）：
///   - [StudyRecordResetScope.lastSession]：只撤最近一次会话——经引擎唯一入口
///     `deleteStudySession`（先在在跑的 `StudyClock` 上退役段 uid，再按 uid 写零；
///     零值是新的绝对值写，经 uid LWW 传到对端），**不立按身份的墓碑**（那会把整段
///     历史一起压死）。
///   - [StudyRecordResetScope.all]：清这一项的全部统计——走删书 / 删视频时「同时删除
///     统计数据」的同一条路径（`deleteReadingStatisticsForTitle` /
///     `deleteVideoStatisticsForIdentity`：删段 + 按身份立碑 + legacy 行 + title 碑）。
///
/// 收藏、制卡历史、书签、高亮一律不动。
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';

/// 重置时对学习记录做什么。
enum StudyRecordResetScope {
  /// 不动学习记录（默认：统计是用户的学习数据，误删代价高）。
  keep,

  /// 只撤销最近一次打开产生的那一次会话。
  lastSession,

  /// 清除这一项的全部学习记录（同步安全的按身份删除 + 墓碑）。
  all,
}

/// 从会话流 [sessions] 里挑出属于 ([mediaKind], [mediaKeys]) 的最近一次会话
/// （按结束时刻；写零的段本就不进会话流）。纯函数，没有返回 null。
StudySession? latestStudySessionFor(
  Iterable<StudySession> sessions, {
  required String mediaKind,
  required Set<String> mediaKeys,
}) {
  StudySession? latest;
  for (final StudySession s in sessions) {
    if (s.mediaKind != mediaKind || !mediaKeys.contains(s.mediaKey)) continue;
    if (latest == null || s.endAt > latest.endAt) latest = s;
  }
  return latest;
}

/// 「撤销最近一次会话」只看这个窗口内结束的会话（用户 2026-10-05 拍板）：误点开
/// 往往不产生任何段（关书不入账，BUG-2264），不限时间就会把几天前、甚至别的设备上
/// 的真实阅读当成「最近一次」写零并同步到所有设备。
const Duration kUndoLatestStudySessionWindow = Duration(hours: 24);

/// 撤销 ([mediaKind], [mediaKeys]) 最近一次会话；返回是否真的撤了一次。
///
/// 会话只从统一事实面 [loadStatFacts] 派生（当前 Profile），删除走引擎唯一入口
/// [deleteStudySession]（退役在跑时钟的 uid → 按 uid 写零，同步安全、不立碑）。
/// 只撤结束于 [kUndoLatestStudySessionWindow] 之内的会话；[nowMs] 仅供测试注入。
Future<bool> undoLatestStudySession(
  FushiDatabase db, {
  required String mediaKind,
  required Set<String> mediaKeys,
  int? nowMs,
}) async {
  final Set<String> keys = <String>{
    for (final String k in mediaKeys)
      if (k.isNotEmpty) k,
  };
  if (keys.isEmpty) return false;
  final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
  final StudySession? latest = latestStudySessionFor(
    facts.sessions,
    mediaKind: mediaKind,
    mediaKeys: keys,
  );
  if (latest == null) return false;
  final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  if (latest.endAt < now - kUndoLatestStudySessionWindow.inMilliseconds) {
    return false;
  }
  await deleteStudySession(db, latest);
  return true;
}

/// 把书（EPUB / 漫画 / PDF，或配对了 EPUB 的有声书）重置为未读。
///
/// [bookKey] 是书架身份；[extraStatKeys] 是同一本书在统计域里的其它身份（配对
/// 字幕书的 SRT uid——后台听书时钟对它记账）。[title] 只给全部清除时 legacy 行的
/// title 墓碑用。[nowMs] 仅供测试注入。
Future<void> resetBookReadingState({
  required FushiDatabase db,
  required String bookKey,
  required String title,
  Set<String> extraStatKeys = const <String>{},
  StudyRecordResetScope records = StudyRecordResetScope.keep,
  int? nowMs,
}) async {
  if (bookKey.isEmpty) return;
  final EpubBookRow? book = await db.getEpubBook(bookKey);
  final String uid = book?.uid ?? '';
  if (uid.isNotEmpty) {
    final ReaderPositionRow? existing = await db.getReaderPosition(uid);
    // 从没留过位置 = 本来就是未读，不凭空造一行（否则它会顶进「最近阅读」排序）。
    if (existing != null) {
      final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      // 严格新于旧行：云通道按时间戳三方判定，同毫秒会被判成「没变」。
      final int ts = now > existing.updatedAt ? now : existing.updatedAt + 1;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(uid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(0),
          charOffset: const Value<int>(-1),
          updatedAt: Value<int>(ts),
        ),
      );
    }
  }
  await db.setEpubBookCompleted(bookKey, null);
  // 带有声书时开书以音频位置为主（BUG-2390），只回写阅读位置会被音频位置原样拉回去、
  // 再被阅读器落库成「在读」；音频位置一并归零（带时间戳，互联 LWW 随之推送）。
  final AudiobookRepository audiobooks = AudiobookRepository(db);
  if (await audiobooks.findByBookKey(bookKey) != null) {
    await audiobooks.updatePositionMs(bookKey: bookKey, positionMs: 0);
  }

  final Set<String> statKeys = <String>{
    bookKey,
    for (final String k in extraStatKeys)
      if (k.isNotEmpty) k,
  };
  switch (records) {
    case StudyRecordResetScope.keep:
      break;
    case StudyRecordResetScope.lastSession:
      await undoLatestStudySession(
        db,
        mediaKind: kActivityMediaBook,
        mediaKeys: statKeys,
        nowMs: nowMs,
      );
    case StudyRecordResetScope.all:
      await ReaderFushiSource.deleteBookStatistics(
        db: db,
        title: title,
        mediaKeys: statKeys,
      );
  }
}

/// 把一集视频重置为未看：位置 / 播放时刻 / 完成标记 / 当前集清零并写互联 LWW
/// 镜像键（[VideoBookRepository.clearWatchProgress]），再按 [records] 处理统计。
Future<void> resetVideoWatchState({
  required FushiDatabase db,
  required VideoBookRepository repo,
  required String bookUid,
  required String title,
  StudyRecordResetScope records = StudyRecordResetScope.keep,
  int? nowMs,
}) async {
  if (bookUid.isEmpty) return;
  await repo.clearWatchProgress(bookUid);
  switch (records) {
    case StudyRecordResetScope.keep:
      break;
    case StudyRecordResetScope.lastSession:
      await undoLatestStudySession(
        db,
        mediaKind: kActivityMediaVideo,
        mediaKeys: <String>{bookUid},
        nowMs: nowMs,
      );
    case StudyRecordResetScope.all:
      // 与删视频时「同时删除统计数据」同一条路径（含「已看过区间」并集，删统计 =
      // 当没看过）；只删挂在这条 uid 名下的行，不按标题连坐同名视频。
      await db.deleteVideoStatisticsForIdentity(title: title, bookUid: bookUid);
  }
}
