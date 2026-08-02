import 'package:flutter/foundation.dart';

/// 阅读器「恢复锚」：**若此刻新建一个 WebView（首载 / `reloadWithCurrentSettings`
/// / renderer 死后换 key 重建），它该把用户放回书里的哪个位置**。
///
/// ## 它以前错在哪（TODO-2603 · BUG-1386 派生）
///
/// 阅读器 State 里有两组坐标：
///
/// | 字段 | 语义 | 谁写 |
/// |---|---|---|
/// | `_initialProgress` / `_initialCharOffset` / `_initialCharOffsetEnd` / `_initialFragment` | 恢复锚 | 导航发起方 |
/// | `_lastProgressValue` / `_lastProgressCharOffset` | 当前实时进度 | 进度采样 |
///
/// 原来的恢复锚**只在导航发起那一刻写一次**：`_beginNavigation` 跨章翻页时把它写成
/// `0.0 / -1`（「去新章章首」），章内滚动此后只更新 `_lastProgress*`。于是恢复锚在
/// 恢复落定之后就变成了一张**过期的进章快照**。
///
/// 只要在那之后再建一次 WebView（renderer 被 OOM 回收 → 换 key 重建），restore 就按
/// 这张过期快照回到**章首**，紧接着 `_onRestoreComplete → _refreshProgress →
/// _debouncedSavePosition` 把这个回退位置如实落库，**把 DB 里更靠后的真实进度覆盖
/// 掉**。这不是「重建不了」，是「一旦重建就丢进度」——所以阅读器当时只能救命
/// （`WebViewDeathGuard.afterRebuild == null`）不重建。
///
/// ## 修法：改所有权与更新时机，不加分支
///
/// 病根不是「某个值偶尔是 0」，是**这一个状态被两种语义共用**：既当「本次导航的目标」
/// 又被当成「新 WebView 该去哪」。修法是把它的生命周期切成两段、各有唯一所有者：
///
/// - **阶段 ①「待消费的导航目标」**：`_restoreInFlight == true` 期间。所有者是导航发起
///   方（`_beginNavigation` / `_initBook` / reload / 有声书 cue 恢复）。此时实时进度采样
///   读到的还是**旧页面**，绝不能覆盖尚未被消费的目标。
/// - **阶段 ②「当前阅读位置」**：恢复落定（`_restoreInFlight == false`）之后。所有者变成
///   实时进度采样（`_refreshProgress` / `_syncPositionFromWebViewProgress`）——每采到一次
///   进度，恢复锚就跟着走。
///
/// 于是「恢复锚始终反映当前进度」成为**结构性事实**，而不是靠调用方在崩溃回调里临时
/// 补写。原先设想的「崩溃时把 `_lastProgress*` 拷进 `_initial*`」那种补丁被消掉了：崩溃
/// 路径不需要知道恢复锚这回事。
@immutable
class ReaderRestoreAnchor {
  const ReaderRestoreAnchor({
    required this.progress,
    required this.charOffset,
    this.charOffsetEnd = -1,
    this.fragment,
  });

  /// 章首：无精确字符锚、无句尾锚、无片段，分数 0。
  ///
  /// 这正是修复前重建会落到的地方——测试用它当「丢进度」的反例基准。
  static const ReaderRestoreAnchor chapterStart =
      ReaderRestoreAnchor(progress: 0, charOffset: -1);

  /// 章内进度分数 [0,1]。精确字符锚存在时它只是兜底（JS 侧 `C.initialCharOffset >= 0`
  /// 优先走 `restoreToCharOffset`）。
  final double progress;

  /// 章内绝对字符偏移；`-1` = 无精确锚（旧存档 / 书签分数跳转）。
  final int charOffset;

  /// 收藏句跳转的句尾绝对字符偏移（BUG-461）；`-1` = 无。**一次性**：只对发起它的那
  /// 一次导航有效。
  final int charOffsetEnd;

  /// 内链导航的 URL fragment；`null` = 无。**一次性**，同上。
  final String? fragment;

  /// 是否等价于「章首」。恢复锚退化成它 = 用户进度被丢。
  bool get isChapterStart =>
      charOffset < 0 && charOffsetEnd < 0 && fragment == null && progress <= 0;

  @override
  bool operator ==(Object other) =>
      other is ReaderRestoreAnchor &&
      other.progress == progress &&
      other.charOffset == charOffset &&
      other.charOffsetEnd == charOffsetEnd &&
      other.fragment == fragment;

  @override
  int get hashCode =>
      Object.hash(progress, charOffset, charOffsetEnd, fragment);

  @override
  String toString() => 'ReaderRestoreAnchor(progress: $progress, '
      'charOffset: $charOffset, charOffsetEnd: $charOffsetEnd, '
      'fragment: $fragment)';
}

/// 恢复锚生命周期的**唯一状态转移**：一次实时进度采样到达时，恢复锚应该变成什么。
///
/// - [restoreInFlight] 为真 = 阶段 ①，导航目标还没被消费，采样读的是旧页面 → 原样保留
///   [current]。
/// - 否则 = 阶段 ②，实时进度接管恢复锚。一次性字段（`charOffsetEnd` / `fragment`）在此
///   清空：它们描述的是**那一次导航**的落点意图，恢复既已落定、用户又已滚动，再把它们
///   带进下一次 WebView 创建就是把无关的整句对齐 / 内链跳转当成恢复目标（TODO-1308 那
///   类泄漏）。
ReaderRestoreAnchor restoreAnchorOnLiveProgress({
  required ReaderRestoreAnchor current,
  required bool restoreInFlight,
  required double liveProgress,
  required int liveCharOffset,
}) {
  if (restoreInFlight) {
    return current;
  }
  return ReaderRestoreAnchor(
    progress: liveProgress,
    charOffset: liveCharOffset,
  );
}
