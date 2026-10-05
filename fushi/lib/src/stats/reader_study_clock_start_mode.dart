/// 小说阅读器（reader_fushi）阅读计时的「开始方式」（用户 2026-10-05）。
///
/// 只决定**打开书那一刻**时钟处于什么状态、以及何时自动起表；起表之后的一切
/// （手动暂停 / 继续、切后台停表、面板压正文停表、空闲门、有声书在播豁免）照旧只经
/// `studyClockMayRun` 一个判据，三种模式不改 `study_segments` 的任何数据口径。
///
/// 偏好键 [kReaderStudyClockStartModePrefKey]，存 [storageValue]；与阅读空闲门同为
/// 普通偏好（未进 `ProfileKeys` 排除表 = 随 Profile 快照，各 Profile 各自一份）。
enum ReaderStudyClockStartMode {
  /// 打开书时计时处于暂停，用户点「继续阅读计时」（状态行计时键 / 统计侧栏 / 快捷键
  /// P）才开始。
  manual('manual'),

  /// 打开书即开始计时（默认，= 此前的唯一行为）。
  onOpen('on_open'),

  /// 打开书时暂停；首次翻页 / 滚动把阅读位置往前推进后自动开始（仅打开或误触不计）。
  onPageTurn('on_page_turn');

  const ReaderStudyClockStartMode(this.storageValue);

  /// 持久化值（偏好里存的字符串）。
  final String storageValue;

  /// 解析持久化值；缺失 / 未知值回落默认 [kDefaultReaderStudyClockStartMode]。
  static ReaderStudyClockStartMode parse(String? raw) {
    for (final ReaderStudyClockStartMode mode in values) {
      if (mode.storageValue == raw) return mode;
    }
    return kDefaultReaderStudyClockStartMode;
  }

  /// 打开书时是否处于（手动）暂停态——[manual] 与 [onPageTurn] 都是。
  bool get startsPaused => this != onOpen;

  /// 打开书后是否在等首次翻页自动起表。
  bool get awaitsFirstPageTurn => this == onPageTurn;
}

/// 偏好键：阅读计时开始方式。
const String kReaderStudyClockStartModePrefKey =
    'stats_reading_clock_start_mode';

/// 默认：打开即开始（用户拍板，与改造前行为一致）。
const ReaderStudyClockStartMode kDefaultReaderStudyClockStartMode =
    ReaderStudyClockStartMode.onOpen;

/// 「翻页后开始」模式的触发判据：阅读位置从 [previous] 单元落定到 `[start, end)`
/// 是否算一次**向前翻页 / 滚动推进**。
///
/// 只比较**相邻两次**落定（跳转 / 换章 / 进度条 / 显式跳句都会先清掉当前单元，
/// [previous] 为 null 时不触发——跳转是导航，不是翻页，落定后再翻一页才算）。
///
/// 推进 = 新单元起点越过上一单元的**中点**：
///  * 分页 / VN：下一页起点 = 上一页终点，必然越过；
///  * 连续滚动：往下滚过半屏才算，滚一两行（误触 / 微调）不算；
///  * 重排 / 宽变 / 字号变：重锚保持视口首字，起点只会小幅漂移，不越过中点；
///  * 回翻：起点变小，不算（「推进」阅读位置）。
bool readerStudyClockTurnAdvanced({
  required (int, int)? previous,
  required int start,
  required int end,
}) {
  if (previous == null || end <= start) return false;
  final (int prevStart, int prevEnd) = previous;
  if (prevEnd <= prevStart) return false;
  final int midpoint = prevStart + (prevEnd - prevStart) ~/ 2;
  return start > prevStart && start >= midpoint;
}
