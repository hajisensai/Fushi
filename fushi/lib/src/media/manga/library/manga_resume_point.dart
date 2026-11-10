import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 在线漫画「重新打开时回到哪里」（偏好 `manga_resume_target`）。
///
/// 两种口径只在「读完过的章」上分歧——`manga_chapter_states.readAt` 一经写入就
/// 一直留着（[FushiDatabase.saveMangaChapterState] 回填旧值），所以：
///
/// - [furthestProgress]（默认，2026-10 前唯一的行为）：读完过的章算「已经过去
///   了」。继续阅读跳到它之后更新的一话；重开一章读完过的章从第 1 页开始。按进度
///   往前推，重读旧章时停下的那一页不会被记住。
/// - [lastPosition]：和书的阅读器同一口径（`reader_positions` 恒存最后停下的
///   位置）。继续阅读回到最近停下的那一章那一页，哪怕那章以前读完过；只有停在
///   一章的最后一页（真的读到头）才前进到下一话 / 从头开始。
enum MangaResumeTarget { furthestProgress, lastPosition }

/// 偏好默认值：保持既有行为。
const String kMangaResumeTargetDefault = 'furthest';

extension MangaResumeTargetKey on MangaResumeTarget {
  String get key => switch (this) {
    MangaResumeTarget.furthestProgress => 'furthest',
    MangaResumeTarget.lastPosition => 'last',
  };

  /// 未知值回落默认（[MangaResumeTarget.furthestProgress]）。
  static MangaResumeTarget fromKey(String raw) => switch (raw) {
    'last' => MangaResumeTarget.lastPosition,
    _ => MangaResumeTarget.furthestProgress,
  };
}

/// 新读者从哪一章开始：选过章就是那一章，否则最旧的一话（源按新→旧返回，
/// 最旧 = 列表末尾）。
int mangaInitialChapterIndex(OnlineMangaLibraryEntry entry) {
  final int? selected = entry.currentChapterIndex;
  if (selected != null && selected >= 0 && selected < entry.chapters.length) {
    return selected;
  }
  return entry.chapters.isEmpty ? -1 : entry.chapters.length - 1;
}

/// 书架进度里每一章占多少单位：章内进度（翻到第几页）按它细分，否则「读了
/// 当前章一半」只能取整成 0 或 1 章。
const int kMangaShelfUnitsPerChapter = 100;

/// 在线漫画在书架上的进度（`MediaItem.position / duration`）。
///
/// 口径 = 已读章数（`manga_chapter_states.readAt` 非空，作品页「标记此章及更早
/// 为已读」与阅读器读到章末写的是同一个列）+ 当前章（[entry.currentChapter]）
/// 的章内进度，除以总章数。每章 [kMangaShelfUnitsPerChapter] 个单位。
///
/// - 当前章已读：已计入已读章数，不再加章内进度；
/// - 当前章未读：按 `lastPage+1 / pageCount` 折算，夹在 [1, 单位-1]——打开过就
///   算「在读」（position>0 进「继续阅读」），没读完就绝不凑成一整章；页数未知
///   （还没落过章状态）按 1 个单位记「已打开」。
///
/// BUG-4349：此前只看 `currentChapterIndex`，按「从最旧数到当前章」算位置——
/// 标记章节已读完全不影响书架，而打开过最新一话（下标 0）就直接是 total/total
/// 「读完」。
({int position, int duration}) onlineMangaShelfProgress(
  OnlineMangaLibraryEntry entry,
  Map<String, MangaChapterStateRow> states,
) {
  final int total = entry.chapters.length;
  if (total == 0) return (position: 0, duration: 1);
  int readChapters = 0;
  for (final OnlineMangaChapter chapter in entry.chapters) {
    if (states[chapter.key]?.readAt != null) readChapters++;
  }
  int partial = 0;
  final OnlineMangaChapter? current = entry.currentChapter;
  if (current != null) {
    final MangaChapterStateRow? state = states[current.key];
    if (state?.readAt == null) {
      final int? pageCount = state?.pageCount;
      partial = pageCount != null && pageCount > 0
          ? ((state!.lastPage + 1) * kMangaShelfUnitsPerChapter ~/ pageCount)
                .clamp(1, kMangaShelfUnitsPerChapter - 1)
          : 1;
    }
  }
  return (
    position: readChapters * kMangaShelfUnitsPerChapter + partial,
    duration: total * kMangaShelfUnitsPerChapter,
  );
}

/// [state] 这一章是否「停在了末尾」：读完过，且最后停下的页就是最后一页（页数
/// 未知时——「标记已读」批量写的行没有页信息——按读完算）。
bool mangaChapterStoppedAtEnd(MangaChapterStateRow state) {
  if (state.readAt == null) return false;
  final int? pageCount = state.pageCount;
  if (pageCount == null || pageCount <= 0) return true;
  return state.lastPage >= pageCount - 1;
}

/// 「继续阅读」落到哪一章（续播三层的「选条目」，见 docs/agent/naming.md 命名术语表）。
///
/// 先找**最近动过**的那一章（`updatedAt` 最大）；一次没读过就走
/// [mangaInitialChapterIndex]。之后按 [target]：
/// - furthestProgress：那章读完过（`readAt` 非空）→ 前进到更新的一话；
/// - lastPosition：只有停在那章末尾（[mangaChapterStoppedAtEnd]）才前进。
///
/// 已经是最新一话就停在原地，让用户看到自己读到头了。
int continueMangaChapterIndex(
  OnlineMangaLibraryEntry entry,
  Map<String, MangaChapterStateRow> states, {
  MangaResumeTarget target = MangaResumeTarget.furthestProgress,
}) {
  if (entry.chapters.isEmpty) return -1;
  int bestIndex = -1;
  int bestUpdatedAt = -1;
  for (int index = 0; index < entry.chapters.length; index++) {
    final MangaChapterStateRow? state = states[entry.chapters[index].key];
    if (state == null) continue;
    if (state.updatedAt > bestUpdatedAt) {
      bestUpdatedAt = state.updatedAt;
      bestIndex = index;
    }
  }
  if (bestIndex < 0) return mangaInitialChapterIndex(entry);
  final MangaChapterStateRow best = states[entry.chapters[bestIndex].key]!;
  final bool advance = switch (target) {
    MangaResumeTarget.furthestProgress => best.readAt != null,
    MangaResumeTarget.lastPosition => mangaChapterStoppedAtEnd(best),
  };
  if (!advance) return bestIndex;
  // 列表是新→旧，「更新的一话」= 下标 -1。
  return bestIndex > 0 ? bestIndex - 1 : bestIndex;
}

/// 阅读器打开一部在线漫画时落到哪一章。
///
/// - 调用方点名了章（作品页点某一章、作品页「继续阅读」按钮）：就是那一章；
/// - 没点名（首页「继续」、历史、合集、统计等直接开书）：与作品页「继续阅读」同一
///   判据 [continueMangaChapterIndex]，按偏好 [target] 走——不再用
///   `currentChapterIndex`（只记「最后一次选了哪章」），否则偏好选「最远进度」时
///   直接开书会回到读完的那一章，而作品页的「继续阅读」去的是下一话（BUG-3246）。
int mangaReaderOpenChapterIndex(
  OnlineMangaLibraryEntry entry,
  Map<String, MangaChapterStateRow> states, {
  int? requested,
  MangaResumeTarget target = MangaResumeTarget.furthestProgress,
}) {
  if (requested != null &&
      requested >= 0 &&
      requested < entry.chapters.length) {
    return requested;
  }
  return continueMangaChapterIndex(entry, states, target: target);
}

/// 打开一章时从第几页开始（0-based；续播三层的「定起点」）。
///
/// - furthestProgress：读完过的章从头看（「重读」视为明确意图），没读完且翻过页
///   的落回 `lastPage`。
/// - lastPosition：落回 `lastPage`，除非停在了末尾（那就从头）。
int resolveMangaChapterResumePoint(
  MangaChapterStateRow? state, {
  MangaResumeTarget target = MangaResumeTarget.furthestProgress,
}) {
  if (state == null || state.lastPage <= 0) return 0;
  return switch (target) {
    MangaResumeTarget.furthestProgress =>
      state.readAt == null ? state.lastPage : 0,
    MangaResumeTarget.lastPosition =>
      mangaChapterStoppedAtEnd(state) ? 0 : state.lastPage,
  };
}
