/// 漫画阅读器的学习计时 / 统计侧栏用的纯函数（无 widget 依赖，便于定向测试）。
library;

import 'package:fushi/src/reader/reader_statistics_sheet.dart'
    show ReaderPositionSnapshot;

/// 统计侧栏（`ReaderStatisticsSheet(media: ReaderStatsMedia.manga)`）的位置读口：
///
/// - 第一行 = 本章（本地卷 = 整卷）当前页（从 1 起）/ 页数；
/// - 第二行 = 当前章序（从 1 起）/ 章数，只有书架在线条目才有章表。
///
/// [currentPage] 是 0 起的当前页（spread 模式 = 当前 entry 的首页）；[pageCount] ≤ 0
/// （还没装好正文 / 本章未下载）两项都给 null，侧栏不画进度条。
///
/// [chapterIndex] 是 `OnlineMangaLibraryEntry.chapters` 的下标。源按**新→旧**返回
/// （列表 0 = 最新一话，见 `kMangaNextChapterStep`），所以阅读顺序的章序 =
/// `chapterCount - chapterIndex`。下标越界（本地卷恒 -1）章序两项都给 null。
ReaderPositionSnapshot mangaStatsPosition({
  required int currentPage,
  required int pageCount,
  required int chapterIndex,
  required int chapterCount,
}) {
  final bool hasPages = pageCount > 0;
  final bool hasChapter = chapterIndex >= 0 && chapterIndex < chapterCount;
  return (
    chapterCurrent: hasPages ? (currentPage + 1).clamp(1, pageCount) : null,
    chapterTotal: hasPages ? pageCount : null,
    bookCurrent: hasChapter ? chapterCount - chapterIndex : null,
    bookTotal: hasChapter ? chapterCount : null,
  );
}

/// 漫画页「屏上没有可读正文」：加载失败 / 本章未下载（换去的在线章既没下载、直读也
/// 没成）。这两种状态整块正文被替换成提示页，用户不在读——学习计时按页内遮挡停表
/// （`StudyClockRunGate.setLocallyCovered`）。
///
/// 换章装载中的加载指示（`_switchingChapter`）**不**算：换章时旧章末页要在新章
/// `_presentPayload` 里 `leave()` 结算，那一刻时钟必须还在走，否则这页的字数 / 页数按
/// 停表丢弃（BUG-2210 的对称丢弃口径）。装载通常一两秒，卡住的由空闲门兜底。
bool mangaStudyContentAbsent({
  required bool loadFailed,
  required bool chapterNotDownloaded,
}) => loadFailed || chapterNotDownloaded;
