/// 统计侧栏的学习面与位置读口类型（叶子文件，只依赖 dart:core）。
///
/// 从 `reader_statistics_sheet.dart` 拆出，让纯函数侧（如
/// `manga_reader_study_stats.dart`）拿到类型时不必 import UI 文件、不进 import 环。
library;

/// 侧栏服务的学习面。决定位置卡 / 预计读完 / 指标卡的单位与文案，账本与骨架不变。
///
/// - [book]：EPUB——本章 / 全书字数位置，按字速预计读完；
/// - [manga]：漫画——本章页位置 + 章序，按页速预计本章读完，指标以页数为主；
/// - [video]：视频——本集播放位置 + 集序，本集剩余片长（按倍速），指标里的字数是
///   字幕字数。
enum ReaderStatsMedia { book, manga, video }

/// 阅读位置读口：本章 / 全书的已读与总字数（任一未知为 null）。
typedef ReaderPositionSnapshot = ({
  int? chapterCurrent,
  int? chapterTotal,
  int? bookCurrent,
  int? bookTotal,
});
