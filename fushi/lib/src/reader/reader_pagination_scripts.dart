import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        fullwidthAsciiToHalfwidth,
        halfwidthKatakanaToFullwidth,
        katakanaToHiragana;

enum ReaderNavigationDirection {
  forward('forward'),
  backward('backward');

  const ReaderNavigationDirection(this.jsValue);
  final String jsValue;
}

/// `paginate()` 一次翻页的纯数据结果：是否真的滚动了（[scrolled]）以及目标
/// 滚动量（[targetScroll]，未滚动时为当前对齐页，调用方可忽略）。
class ReaderPageStep {
  const ReaderPageStep({required this.scrolled, required this.targetScroll});

  /// 是否在边界内成功翻了一页（false ⇒ 已到首/末页，调用方走 limit 分支）。
  final bool scrolled;

  /// 翻页后应落到的滚动量（已 clamp 到 [min,max] 整页边界）。
  final double targetScroll;
}

/// Groups the many horizontal wheel ticks emitted by one macOS trackpad swipe
/// into one page-turn intent.
///
/// The gate belongs to the reader State rather than the WebView document, so a
/// chapter navigation in the middle of momentum cannot reset it and admit a
/// second page turn. A tick that belongs to an already-claimed gesture moves the
/// trailing edge; only a full quiet interval starts the next gesture.
class ReaderWheelGestureGate {
  /// 最后一个**属于某个已认领手势**的 tick 时刻。被丢弃、翻不动页的 tick 不属于
  /// 任何手势，不写这里（见 [shouldStartNewGesture] 的 [canTurnPage]）。
  DateTime? _lastTickAt;

  /// BUG-1380：手势 token 的消费必须晚于「这一 tick 确实能翻页」的确认。
  ///
  /// [canTurnPage] 由调用方给出（阅读器侧是 `!_paginationInFlight`）：为 false 时
  /// 这一 tick 已知落不了地（换章加载 / restore 在飞），于是**不认领新手势**——
  /// 否则整段惯性的首个 tick 白白吃掉 token，加载落定后的后续 tick 全部在闸门早退，
  /// 用户这一次滑动零反馈。返回值仍是纯查询「本 tick 不属于已认领的手势」，让调用方
  /// 把 tick 继续送进下游（跨章冷却窗要靠这些 tick 续窗）。
  ///
  /// 已在手势内的 tick（返回 false）无条件滑动 trailing edge：它属于已认领的手势，
  /// 延长静默窗正是闸门的本意。
  bool shouldStartNewGesture({
    required DateTime now,
    required Duration settleInterval,
    required bool canTurnPage,
  }) {
    final DateTime? lastTickAt = _lastTickAt;
    final bool startsNewGesture =
        lastTickAt == null || now.difference(lastTickAt) >= settleInterval;
    if (!startsNewGesture || canTurnPage) {
      _lastTickAt = now;
    }
    return startsNewGesture;
  }
}

/// 一条 sasayaki cue 的运行时定位输入：归一化原文 [needle]、匹配时算出的
/// 归一化偏移提示 [hint]、提示长度 [length]（仅在未命中回落时用于推进游标）。
class SentenceAudioCueHint {
  const SentenceAudioCueHint({
    required this.needle,
    required this.hint,
    required this.length,
  });

  final String needle;
  final int hint;
  final int length;
}

class ReaderPaginationScripts {
  ReaderPaginationScripts._();

  /// sasayaki 高亮就近重定位的搜索半径（归一化字符）。整句 needle 很长，
  /// 半径内出现同一整句重复的概率极低；半径限制 + 单调游标 ⇒ 不会跳到远处
  /// 重复句（BUG-060 用户担心的「来回跳动」）。
  static const int kSentenceAudioSearchWindow = 256;

  /// 把 cue 的归一化偏移（提示）+ 原文，映射成在 [fullNorm]（实时 DOM 的
  /// 归一化文本）里的解析起点。这是 JS `collectSasayakiCueRanges` 搜索逻辑的
  /// 纯 Dart 影子，供单测验证「漂移自愈 / 不跳远处重复 / 未命中回落提示」三
  /// 不变量；JS 侧实现同一算法（见同文件脚本字符串 + 源码守卫测试）。
  ///
  /// 规则：单调游标 `cursor` 只增不减；每条 cue 在 `[max(cursor, hint-window),
  /// hint+window]` 内取**离 hint 最近**的整句出现位置（对齐既有
  /// scrollToSearchMatch 的就近策略）；窗口内无命中则回落到裁剪后的 hint。
  @visibleForTesting
  static List<int> resolveCueNormStartsForTesting({
    required String fullNorm,
    required List<SentenceAudioCueHint> cues,
    int window = kSentenceAudioSearchWindow,
  }) {
    final List<int> out = <int>[];
    int cursor = 0;
    for (final SentenceAudioCueHint c in cues) {
      final String needle = c.needle;
      final int hint = c.hint;
      int resolved;
      if (needle.isNotEmpty) {
        final int lo = cursor > (hint - window) ? cursor : (hint - window);
        final int start = lo < 0 ? 0 : lo;
        int best = -1;
        int bestDist = 1 << 30;
        if (start <= fullNorm.length) {
          int from = start;
          while (true) {
            final int i = fullNorm.indexOf(needle, from);
            if (i < 0 || i > hint + window) {
              break;
            }
            final int d = (i - hint).abs();
            if (d < bestDist) {
              bestDist = d;
              best = i;
            }
            from = i + 1;
          }
        }
        if (best >= 0) {
          resolved = best;
          cursor = best + needle.length;
        } else {
          // BUG-282：未命中只为这一条 cue 选一个尽力而为的回落位置，**绝不推进
          // 单调游标**。游标只在「DOM 真命中」时前进；若让回落按未经核实的 hint
          // 猜测推进 cursor，就可能越过后面真正能命中的 cue 的真实位置，使其搜索
          // 窗口下界 max(cursor, hint-window) 把真实位置排除掉 → 整本逐句累积漂移
          // （BUG-060 想消除的正是累积漂移，这里是它的回落漏洞）。
          resolved = _clampInt(hint, cursor, fullNorm.length);
        }
      } else {
        // 空 needle 同理：只给回落位置，不污染游标。
        resolved = _clampInt(hint, cursor, fullNorm.length);
      }
      out.add(resolved);
    }
    return out;
  }

  /// JS `window.fushiReader.paginate` 的纯 Dart 影子，供单测验证「错位不跳页」
  /// 不变量（BUG-169）。两侧同算法：
  ///
  /// - forward → 严格在 [currentScroll] 之后的最近整页边界
  ///   （`floor(currentScroll/pitch) + 1`）；
  /// - backward → 严格在 [currentScroll] 之前的最近整页边界
  ///   （`ceil(currentScroll/pitch) - 1`）。
  ///
  /// 若除法商与最近整数页号在像素空间相差不超过 1px，先把商规范化为该整数，避免
  /// 已归一的亚像素页边界被二进制除法重新落到整数两侧。
  ///
  /// 当 [currentScroll] 已对齐到整页时与「当前页 ±1」完全等价；当它落在两页之间
  /// （snap 监听器尚未把它对齐 / pitch 微变导致瞬时错位）时，floor/ceil 也只走一页，
  /// 不会像旧实现 `round((currentScroll ± pitch)/pitch)` 那样把当前页算成相邻页而跳 2 页。
  /// 目标值再 clamp 到 [[minAlignedScroll], [maxAlignedScroll]]。
  @visibleForTesting
  static ReaderPageStep resolvePaginateStepForTesting({
    required ReaderNavigationDirection direction,
    required double currentScroll,
    required double columnPitch,
    required double minAlignedScroll,
    required double maxAlignedScroll,
  }) {
    if (columnPitch <= 0) {
      return ReaderPageStep(scrolled: false, targetScroll: currentScroll);
    }
    // 先把 1px 内的 WebView sub-pixel 漂移视为已落到整页边界，再算出「严格相邻
    // 整页边界」并 clamp 到 [min,max]；是否真的翻了一页由 clamp 后
    // 的目标与当前位置比较得出。这样首/末页判定与步长计算共用同一个 target，不再有
    // 「currentScroll 错位 → guard 用 cur±pitch 误判已到边界 / round 跳 2 页」的特例。
    final double stepScroll = _pageStepPosition(currentScroll, columnPitch);
    final double rawPageCoordinate = stepScroll / columnPitch;
    final int nearestPage = rawPageCoordinate.round();
    final double pageCoordinate =
        (rawPageCoordinate - nearestPage).abs() * columnPitch <= 1
            ? nearestPage.toDouble()
            : rawPageCoordinate;
    final double target;
    if (direction == ReaderNavigationDirection.forward) {
      final int basePage = pageCoordinate.floor();
      target = _clampDouble(
          (basePage + 1) * columnPitch, minAlignedScroll, maxAlignedScroll);
      // 已对齐在末页时 target == currentScroll（差值 <=1px 视为同页）→ 无下一页。
      final bool scrolled = target > stepScroll + 1;
      return ReaderPageStep(scrolled: scrolled, targetScroll: target);
    } else {
      final int basePage = pageCoordinate.ceil();
      target = _clampDouble(
          (basePage - 1) * columnPitch, minAlignedScroll, maxAlignedScroll);
      final bool scrolled = target < stepScroll - 1;
      return ReaderPageStep(scrolled: scrolled, targetScroll: target);
    }
  }

  /// JS `window.fushiReader.scrollToRange` 落页锚的纯 Dart 影子（TODO-881）。
  ///
  /// cue 高亮 reveal / search-highlight 共用这条落页路径。历史上它用首段 client
  /// rect 的**几何中点**当锚（`(top+bottom)/2` 或 `(left+right)/2`）再 `alignToPage`
  /// (floor) 落页；这是分页引擎里**唯一**用中点的落页路径，其余（恢复 `restoreToCharOffset`
  /// / `jumpToFragment` / `scrollToCharOffset`）全用**起始边**。
  ///
  /// 当一句 cue 首行 rect 在分页轴向占大半列宽/列高、且这句可见**起点**落在当前列
  /// 后半段时，rect 中点越界进相邻列，floor 落到下一页（前翻）；下一句中点又落回 →
  /// 翻回。逐句在「中点越界/不越界」间摆动 = 有声书自动读来回抖动（手机分页 + 列窄
  /// 字大最明显）。
  ///
  /// 修复：锚取**起始边**，与引擎其余统一（竖排 `rect.top`、横排 `rect.left`，轴向
  /// 语义被 `restoreToCharOffset` :706 / `jumpToFragment` 锁定，**不自创轴向**）。
  /// 起始边锚恒等于「这句开头所在那一页」，不越界。
  ///
  /// 返回 floor 对齐后的目标滚动量（`alignToPage`：
  /// `floor((anchor − contentStart)/pageSize)*pageSize`，差先 clamp 到 >=0）。
  ///
  /// [contentStart] 是分页网格的**相位** —— turn 轴起始 padding（竖排 `padding-top`、
  /// 横排 `padding-left`）。滚动坐标原点是 body 的 padding box，列内容却从 content box
  /// 起始边开始，故列 j 的起始滚动坐标 = `contentStart + j*pageSize`。不减相位就等于把
  /// 网格整体平移了 contentStart，见 `alignToPage` 注释与 BUG-1764/BUG-875。
  @visibleForTesting
  static double revealAnchorTargetScrollForTesting({
    required double rectStart,
    required double currentScroll,
    required double pageSize,
    double contentStart = 0,
  }) {
    if (pageSize <= 0) return currentScroll;
    final double anchor = rectStart + currentScroll - contentStart;
    final double safe = anchor < 0 ? 0 : anchor;
    return (safe / pageSize).floorToDouble() * pageSize;
  }

  /// JS `scrollToRange` reveal 决策的纯 Dart 影子（BUG-875 / BUG-1764）。
  ///
  /// 返回值：`null` = 不翻页（句首就在本页 / pageSize 非法）；非空 = 应翻到的目标 scroll。
  ///
  /// 判据只有一条：句首所属的那一页是不是当前页（`alignToPage` 减相位后就是精确的列号
  /// 函数，见 [revealAnchorTargetScrollForTesting] 的 [contentStart]）。历史上这里还有
  /// 一条 `rectStart < viewportExtent` 的「已可见即不翻」短路（BUG-875 的旧修法）：
  /// client 视口比一页真正的内容宽出 turn 轴两侧 padding，于是**结束边** padding >
  /// column-gap 时（横排宽屏、竖排大字号/底栏占位/移动端系统 inset），下一页开头那段
  /// 落进 `[pageSize, viewportExtent)` 带被误判成「本页可见」→ 有声书跟随读到下一页第一句
  /// 时不翻页（BUG-1764）。而 BUG-875 的行尾单字与它在 `rectStart` / `targetScroll` 上取值
  /// 完全相同，同一条阈值无法区分 —— 根因不在可见性判据而在网格相位，补相位后两者同时消失。
  static double? revealScrollTargetForTesting({
    required double rectStart,
    required double currentScroll,
    required double pageSize,
    double contentStart = 0,
  }) {
    if (pageSize <= 0) return null;
    final double target = revealAnchorTargetScrollForTesting(
      rectStart: rectStart,
      currentScroll: currentScroll,
      pageSize: pageSize,
      contentStart: contentStart,
    );
    if (target == currentScroll) return null;
    return target;
  }

  /// JS `buildPaginationMetrics` 的 min/maxScroll 落页纯 Dart 影子（TODO-1179）。
  ///
  /// 手动跳章分页恢复用 `contentFirstPageScroll`(=minScroll，前进 progress=0) /
  /// `contentLastPageScroll`(=maxScroll，后退 progress=0.99) 落页。两者的取整边界是
  /// 首/末行是否被跳的唯一决定因素：
  /// - `minScroll` = min(maxAligned, alignContentStartToPage(firstContentEdge))。
  ///   `alignContentStartToPage` 必须 **floor**（落到含首行内容边的那页），旧实现在
  ///   内容边距页边界 <1px 时 `Math.round` 会向上取整 → minScroll 抬一页 → 首行整页被跳。
  /// - `maxAligned` = floor((ctxMaxScroll + 1) / pageStep) * pageStep。**+1px 容差**
  ///   吸收单一量纲下 totalSize 比 numCols*pageStep 少零点几 px 的 sub-pixel 下溢，
  ///   否则裸 floor 把 P*pageStep−ε 砍成 (P−1)*pageStep → 末列整页(含末行)不可达。
  /// - 通常 `maxScroll` = min(maxAligned, lastContentScroll)；若浏览器物理终点落在
  ///   最后一条可达网格与末内容网格之间，则仅保留该非网格物理终点作为 terminal page。
  ///   `lastContentScroll` 始终夹住上界，不会引入空白末页。
  ///
  /// 与 JS 同算法（headless WebView 不可用）。所有量都在滚动轴向、CSS px，pageStep 为
  /// 真实列周期(column-width + gap)。返回 (minScroll, maxScroll)。
  @visibleForTesting
  static ({double minScroll, double maxScroll}) resolveContentBoundsForTesting({
    required double firstContentEdge,
    required double lastContentEdge,
    required double contextMaxScroll,
    required double physicalMaxScroll,
    required double pageStep,
  }) {
    if (pageStep <= 0) {
      return (minScroll: 0, maxScroll: 0);
    }
    final double maxAligned =
        ((contextMaxScroll + 1) / pageStep).floorToDouble() * pageStep;
    // 章首/内容起始边落页：floor，绝不 round-up 跳过首行。
    final double startSafe = firstContentEdge < 0 ? 0 : firstContentEdge;
    final double startAligned =
        (startSafe / pageStep).floorToDouble() * pageStep;
    final double lastContentScroll = lastContentEdge <= 0
        ? 0
        : (((lastContentEdge - 1) < 0 ? 0 : (lastContentEdge - 1)) / pageStep)
                .floorToDouble() *
            pageStep;
    final double physicalMax = physicalMaxScroll < 0 ? 0 : physicalMaxScroll;
    double maxScroll =
        maxAligned < lastContentScroll ? maxAligned : lastContentScroll;
    // The CSS page pitch can be smaller than the scrolling element's client
    // extent after chrome insets. In that case the final full grid line may be
    // unreachable while the browser still exposes a useful partial terminal
    // page beyond [maxAligned]. Preserve that physical endpoint. Conversely,
    // never walk past [lastContentScroll] into trailing blank columns.
    if (maxScroll > physicalMax + 1) {
      maxScroll = physicalMax;
    }
    if (lastContentScroll > maxScroll + 1 && physicalMax > maxScroll + 1) {
      maxScroll =
          lastContentScroll < physicalMax ? lastContentScroll : physicalMax;
    }
    final double minScroll =
        maxScroll < startAligned ? maxScroll : startAligned;
    return (minScroll: minScroll, maxScroll: maxScroll);
  }

  /// JS `pageInfo` 的页号纯 Dart 影子。
  ///
  /// `maxScroll` 通常落在绝对 pageStep 网格上；chrome inset 造成物理终点位于两条
  /// 网格之间时，该非网格终点是一张独立末页，即使剩余不足半页也不能被 `round` 吞掉。
  @visibleForTesting
  static ({int currentPage, int totalPages}) resolvePageInfoForTesting({
    required double minScroll,
    required double maxScroll,
    required double currentScroll,
    required double pageStep,
  }) {
    if (pageStep <= 0) return (currentPage: 1, totalPages: 1);
    final double rawSpan = maxScroll - minScroll;
    final double span = rawSpan < 0 ? 0 : rawSpan;
    final int alignedTurns = ((span + 1) / pageStep).floor();
    final double alignedEnd = minScroll + alignedTurns * pageStep;
    final bool hasPartialTerminal = maxScroll - alignedEnd > 1;
    final int totalPages = alignedTurns + 1 + (hasPartialTerminal ? 1 : 0);
    int currentPage = hasPartialTerminal && currentScroll >= maxScroll - 1
        ? totalPages
        : ((currentScroll - minScroll) / pageStep).round() + 1;
    if (currentPage < 1) currentPage = 1;
    if (currentPage > totalPages) currentPage = totalPages;
    return (currentPage: currentPage, totalPages: totalPages);
  }

  /// 连续(滚动)模式收藏句跳转落点的纯 Dart 影子（BUG-461）。
  ///
  /// 收藏记录存了句子的**起始字符**和**字符长度**（`FavoriteSentence.normCharOffset`
  /// / `normCharLength`）。旧的连续 `scrollToCharOffset` 只把**句首**字符对齐到内容顶
  /// （`scrollTop += startTopInViewport − contentTopPad`），完全不看句尾——长句被滚到
  /// 句首贴顶后，句尾溢出可见区底沿（连续模式可见区 = `clip-path inset` 的
  /// `[chromeTopInset, viewportSize − chromeBottomInset]`，底部那段被阅读底栏盖住），
  /// 于是「句尾被切」。句子是横跨可见区底边还是完整落在区内，随句长/字号/落点变化 →
  /// 用户感知的「五五开」。
  ///
  /// 根因修复把跳转目标当作**字符区间** `[start, end]` 而非单点：先按句首贴内容顶算
  /// 出 `startAligned`；若句尾在该位置会溢出可见区底沿、且整句高度 ≤ 可见区高度，则向
  /// 后(下)多滚 `overflow` 像素把句尾正好拉到可见区底沿——整句完整可见且尽量靠上。句
  /// 子比可见区还高(放不下)则维持句首贴顶(尽力而为，本就无任何落点能整句显示)。连续
  /// 模式是裸 `window.scrollY` 亚像素滚动，多滚这点不破坏任何整页对齐(无分页 snap)。
  ///
  /// 参数都在滚动轴向、CSS px：
  /// - [startTopInViewport]：当前滚动下，句首字符起始边相对视口原点的位置（横排
  ///   `rect.top`、竖排把右沿翻成正向后的等价起始边）。
  /// - [sentenceExtent]：整句在滚动轴向的尺寸（句尾远边 − 句首起始边，≥0）。
  /// - [currentScroll]：当前滚动量（`root.scrollTop` / 翻正后的 `scrollLeft`）。
  /// - [contentTopPad]：内容顶 padding（`paddingTop`，已含 chromeTopInset）——句首理想对齐到这里。
  /// - [bandTop]：可见区顶沿（chromeTopInset）。
  /// - [bandBottom]：可见区底沿（viewportSize − chromeBottomInset）。
  ///
  /// 返回新的目标滚动量（连续模式直接写回 `root.scrollTop`）。
  @visibleForTesting
  static double continuousFavoriteJumpScrollForTesting({
    required double startTopInViewport,
    required double sentenceExtent,
    required double currentScroll,
    required double contentTopPad,
    required double bandTop,
    required double bandBottom,
  }) {
    // 句首贴内容顶：scrollTop += startTop − contentTopPad（== 旧行为的落点）。
    final double startAligned =
        currentScroll + (startTopInViewport - contentTopPad);
    final double band = bandBottom - bandTop;
    // 区间信息不可用(老收藏无句长 / 句尾解析失败 → extent<=0)或整句放不下可见区 →
    // 维持句首贴顶(尽力而为)。
    if (sentenceExtent <= 0 || band <= 0 || sentenceExtent > band) {
      return startAligned < 0 ? 0 : startAligned;
    }
    // 句首贴内容顶后，句尾在视口里的底沿位置 = contentTopPad + sentenceExtent。
    final double sentenceBottomInViewport = contentTopPad + sentenceExtent;
    final double overflow = continuousSentenceTailOverflow(
      sentenceBottomInViewport,
      bandBottom,
    );
    final double target = startAligned + overflow;
    return target < 0 ? 0 : target;
  }

  /// 句尾溢出可见区底沿的像素量（≤0 即不溢出，返回 0）。抽出来便于单测断言。
  static double continuousSentenceTailOverflow(
    double sentenceBottomInViewport,
    double bandBottom,
  ) {
    final double overflow = sentenceBottomInViewport - bandBottom;
    return overflow > 0 ? overflow : 0;
  }

  static double _pageStepPosition(double currentScroll, double columnPitch) {
    if (columnPitch <= 0) return currentScroll;
    final double nearestPage =
        (currentScroll / columnPitch).round() * columnPitch;
    return (currentScroll - nearestPage).abs() <= 1
        ? nearestPage
        : currentScroll;
  }

  static double _clampDouble(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  static int _clampInt(int v, int lo, int hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  // ── TODO-630 / BUG-366：JS sasayaki 归一化「值折叠」的纯 Dart 影子 ────────
  // 运行期 JS `foldNormalize`（reader 脚本字符串里）必须与 `AudioTextNormalizer.
  // normalize` **值口径一致**（不仅剥非白名单，还要片假名→平假名 / 大小写 / 全角→
  // ASCII / 半角片假名→全角片假名），否则折叠类书（SRT 片假名 vs EPUB 平假名、
  // 全角 vs 半角）的 cue needle 在实时 DOM 归一化全文里 `indexOf` 落空 → 高亮回落
  // hint（看似「不显示/错位」）。本影子逐字镜像 JS 的剥+折叠算法，单测断言它对
  // 折叠类输入与 `AudioTextNormalizer.normalize` 输出一致，并守卫 JS 折叠口径不被
  // 回归删除。所有折叠都是单 BMP 码元→单 BMP 码元（1:1），不改 buildSasayakiNormIndex
  // 的逐码元 map 粒度（代理对仍 push 两条）。
  @visibleForTesting
  static String foldNormalizeForTesting(String text) {
    final StringBuffer buf = StringBuffer();
    for (final int cp in text.runes) {
      if (!_jsIsMatchableCodePoint(cp)) {
        continue;
      }
      buf.writeCharCode(_jsFoldCodePoint(cp));
    }
    return buf.toString();
  }

  // JS `isMatchableChar`（白名单正则）的 Dart 影子：与 `AudioTextNormalizer.
  // _isKeepable` 同集合。
  static bool _jsIsMatchableCodePoint(int c) {
    return (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x3005 ||
        c == 0x3006 ||
        c == 0x3007 ||
        (c >= 0x3041 && c <= 0x3096) ||
        (c >= 0x309D && c <= 0x309F) ||
        (c >= 0x30A1 && c <= 0x30FA) ||
        (c >= 0x30FC && c <= 0x30FF) ||
        (c >= 0x3400 && c <= 0x4DBF) ||
        (c >= 0x4E00 && c <= 0x9FFF) ||
        c == 0x25CB ||
        c == 0x25EF ||
        c == 0x303B ||
        (c >= 0x2E80 && c <= 0x2EFF) ||
        (c >= 0x2F00 && c <= 0x2FDF) ||
        (c >= 0xF900 && c <= 0xFAFF) ||
        (c >= 0x20000 && c <= 0x2A6DF) ||
        (c >= 0x2A700 && c <= 0x2EBE0) ||
        (c >= 0x2F800 && c <= 0x2FA1F) ||
        (c >= 0x30000 && c <= 0x323AF) ||
        (c >= 0xFF10 && c <= 0xFF19) ||
        (c >= 0xFF21 && c <= 0xFF3A) ||
        (c >= 0xFF41 && c <= 0xFF5A) ||
        (c >= 0xFF66 && c <= 0xFF9D);
  }

  // JS `foldCodePoint` 的 Dart 影子：与 `AudioTextNormalizer.appendNormalized`
  // 的值转换同口径。改用 hibiki_core 共享码点原语（`jp_codepoint_fold.dart`）后
  // 与 AudioTextNormalizer 同源；在白名单域（`_jsIsMatchableCodePoint` 为 true
  // 的码点）与 JS 分段平移逐码点等价。运行期 JS 副本（`hwKataToFw` 查表）由
  // `fushi/test/utils/jp_codepoint_fold_test.dart` 的 parity 测试逐项锁定。
  static int _jsFoldCodePoint(int cp) {
    int out = fullwidthAsciiToHalfwidth(cp);
    if (out >= 0x41 && out <= 0x5A) {
      out += 0x20;
    }
    out = halfwidthKatakanaToFullwidth(out);
    return katakanaToHiragana(out);
  }

  /// BUG-239 纯谓词：阅读器统一手势 `_gestureEnd` 检测到一次滑动后，是否应当
  /// 回传 `onSwipe`（→ 90% 整屏翻页）。
  ///
  /// - **分页模式**（[continuousMode] == false）：CSS `touch-action:none` 禁掉原生
  ///   pan，水平滑动是唯一翻页通道 → 沿用「水平滑动（`absDx > absDy`）才翻页」。
  /// - **连续模式**（[continuousMode] == true）：靠原生滚动（滚动轴 = 书写轴），
  ///   章间切换由边界手势 IIFE（`onBoundarySwipe`）负责。再让 `_gestureEnd` 回传
  ///   `onSwipe` 会与原生滚动产生轴向冲突（横向滑动错误触发垂直 90% 跳页 / 沿滚动
  ///   轴的滑动被原生滚动吞掉）→ 一律不回传，交给原生滚动 + 边界 IIFE + 按钮/键盘/
  ///   音量键 `_paginate` 连续分支。
  ///
  /// JS `_gestureEnd` 用同一判定（见 setup 脚本注入的 `continuousMode` 门控）。
  @visibleForTesting
  static bool continuousSwipeShouldPaginate({
    required bool continuousMode,
    required double absDx,
    required double absDy,
  }) {
    if (continuousMode) return false;
    return absDx > absDy;
  }

  /// TODO-627 / BUG-349 纯谓词：连续/滚动模式下桌面鼠标**滚轮**到达内容轴尽头时，
  /// 应回传哪个 `onBoundarySwipe` 方向跨章（null ⇒ 不在边界，放行原生滚动，不打断
  /// 正常滚动）。连续模式靠原生滚动翻屏，章间切换原本只有触摸/指针的边界手势 IIFE
  /// 走 `onBoundarySwipe`，滚轮无此通道 → 滚到章末/章首再滚没反应。本函数补齐滚轮
  /// 通道，复用边界 IIFE 同款 atStart/atEnd 判定，只在「到底」才发，统一三种输入。
  ///
  /// 轴向（与 wheel 监听器、`scrollToTarget`、`_gestureEnd` 边界 IIFE 同约定）：
  /// - **横排**（[vertical] == false）：滚动轴 = 纵向。`deltaY > 0`（向下滚）= forward；
  ///   到底（`atBottom`）才发 forward，到顶（`atTop`）才发 backward。
  /// - **竖排**（[vertical] == true，vertical-rl）：滚动轴 = 横向，浏览器把垂直滚轮
  ///   投影到横向（见 wheel 监听器 scrollBy）。forward = 沿书写轴前进 = scrollLeft
  ///   减小（vertical-rl，对齐 paginate 的 forwardSign=-1）。投影后的主 delta `delta`
  ///   > 0 表示用户「向前滚」；到达 forward 尽头（`atEnd`，scrollLeft 最负）发 forward，
  ///   到达起点（`atStart`，scrollLeft≈0）发 backward。
  ///
  /// 入参（实时几何，单位 px）：[delta] 为投影到内容轴的主滚轮位移（横排取 deltaY，
  /// 竖排取 wheel 监听器投影后的主 delta）；[atStart]/[atEnd] 为原生滚动是否已到该轴
  /// 起点/尽头（由调用方按同款公式算好传入）。返回 jsValue 字符串或 null。
  /// TODO-737 纯谓词：分页模式鼠标滚轮翻页的「方向意图」归一化。
  ///
  /// 历史 bug = 分页滚轮回传 `onSwipe('left'/'right')` 被 `invertSwipeDirection`（默认
  /// true）连坐反向，且裸符号 `deltaY < 0 = forward` 与连续滚轮 `deltaY > 0 = forward`
  /// （沿书写轴 delta>0=前进）方向相反 → 滚轮方向反了。修法 = 分页滚轮也按
  /// 「deltaY>0=forward」（对齐连续滚轮），产纯语义意图 forward/backward，经新 handler
  /// `onWheelPaginate` 直送 `_paginate`，**不读 invertSwipeDirection**（该开关从此只管
  /// 触摸滑动 / 鼠标拖动）。竖排 RTL 的物理滚向由 JS `paginate()` 内部按 writingMode
  /// 决定，这里只产语义意图、不二次过 writingMode（防双重反转）。
  ///
  /// [deltaY]/[deltaX] = wheel 事件的滚动增量。主轴取绝对值更大的那个，>0 = forward。
  @visibleForTesting
  static String? wheelPaginateDir(
      {required double deltaY, required double deltaX}) {
    final double delta = deltaY.abs() >= deltaX.abs() ? deltaY : deltaX;
    if (delta == 0) return null;
    return delta > 0
        ? ReaderNavigationDirection.forward.jsValue
        : ReaderNavigationDirection.backward.jsValue;
  }

  @visibleForTesting
  static String? continuousWheelBoundaryDirection({
    required bool vertical,
    required double delta,
    required bool atStart,
    required bool atEnd,
  }) {
    if (delta == 0) return null;
    // 横排向下(delta>0)与竖排投影向前(delta>0)都映射为 forward；方向语义已在调用方
    // 把竖排的横向投影归一化成「>0=前进」，故两模式判定同形。
    final bool forward = delta > 0;
    if (forward) {
      return atEnd ? ReaderNavigationDirection.forward.jsValue : null;
    }
    return atStart ? ReaderNavigationDirection.backward.jsValue : null;
  }

  /// BUG-2015：连续模式滚轮到了真实边界后，是否应把这一拍解释为跨章。
  ///
  /// 触摸板的同一手势会先滚正文、再靠惯性喷出多拍卡在边界；这些卡住拍不能替用户
  /// 发起跨章，只有静默后「手势起点就在边界」的新手势才放行。离散滚轮/数位板旋钮
  /// 一格可能只有一个 WheelEvent，因此真实边界上的单拍就应放行。
  @visibleForTesting
  static bool continuousWheelShouldTurnChapter({
    required bool moved,
    required bool isTrackpad,
    required bool startsNewGesture,
  }) {
    if (moved) return false;
    return !isTrackpad || startsNewGesture;
  }

  /// TODO-656 根治：触摸/指针边界手势跨章判据，替代 `_bEnd` 旧的瞬时 `scrollTop<=2`。
  ///
  /// 旧判据在 touchend 那一帧读 `scrollTop<=2`：用户从章中向上滚，momentum/回弹把
  /// scrollPos 滑到边界的瞬态被误当「跨章意图」→ 没到章首就切上一章。新判据只看
  /// **手势起点**（touchstart 时刻）是否已停在边界——从章中滚到边界的那一下起点不在
  /// 边界，不跨章；只有「一开始就贴着章首/章末再发同向手势」才跨章（与移动端到边界
  /// 再拉一下翻页的心智一致）。纯函数、无副作用，供单测。
  ///
  /// [gestureDir] 手势方向（`'forward'`/`'backward'`，由 swipe 位移符号定）；
  /// [downScrollPos] touchstart 时沿内容轴的滚动量（横排 scrollTop、竖排 |scrollLeft|）；
  /// [scrollMax] 该轴最大可滚量（横排 scrollHeight-innerHeight、竖排 scrollWidth-innerWidth）。
  @visibleForTesting
  static String? touchBoundaryCrossDir({
    required String gestureDir,
    required num downScrollPos,
    required num scrollMax,
  }) {
    final bool downAtStart = downScrollPos <= 2;
    final bool downAtEnd = downScrollPos >= scrollMax - 2;
    if (gestureDir == 'backward' && downAtStart) return 'backward';
    if (gestureDir == 'forward' && downAtEnd) return 'forward';
    return null;
  }

  /// TODO-656 根治：滚轮跨章的「到边界」判据，替代 `atStart/atEnd` 瞬时几何。
  ///
  /// 旧判据用 `scrollTop<=2`/`atEnd` 瞬时坐标：短章节（内容≤一屏）`atStart` 与 `atEnd`
  /// 同真、图片未撑开 `scrollHeight` 偏小 → 非真实边界误判 → 一滚就翻页/卡顿。新判据
  /// 看「内容是否真的滚不动」：横排放行原生滚动 → 相邻 wheel 事件 scrollTop 无变化
  /// （[scrollFrom]=上一拍、[scrollTo]=这一拍）；竖排 rAF 缓动 → 投影 target 被 clamp
  /// 卡死（[scrollFrom]=base、[scrollTo]=clamp 后 target）。两轴同形：位移≤1px 即卡边界，
  /// 返回卡住的越界方向（再按输入设备与手势起点决定是否跨章），还能滚（位移>1px）
  /// 则返回 null。纯函数、无副作用，供单测。
  @visibleForTesting
  static String? wheelBoundaryStuckDir({
    required String? wheelDir,
    required num scrollFrom,
    required num scrollTo,
  }) {
    if (wheelDir == null) return null;
    final bool stuck = (scrollTo - scrollFrom).abs() <= 1;
    return stuck ? wheelDir : null;
  }

  /// TODO-629 ②：竖排连续（滚动）模式下，桌面鼠标滚轮的主 delta 投影到横向
  /// （vertical-rl 内容轴 = 横向）滚动时，逐 wheel 事件 `scrollBy(behavior:'auto')`
  /// 是瞬时离散跳，每个事件一次 deltaY 颗粒、丢弃浏览器原生平滑/惯性，看着像「刷新率
  /// 低」「一格一格跳」。横排（轴 = 纵向，与 deltaY 同轴）放行原生滚动相对顺滑。
  ///
  /// 这里把逐事件离散 `scrollBy` 换成 rAF 缓动：wheel 事件只累积目标位置 [target]，
  /// 由 `requestAnimationFrame` 每帧调用本步进函数从当前 [current] 指数逼近 [target]，
  /// 消除颗粒感。指数缓动（每帧走剩余距离的 [factor]）保证单调收敛、永不超调：
  /// - 剩余距离 `remaining = target - current`；
  /// - 当 `|remaining| <= snap`（[snap] = 收尾吸附阈值，含 `factor` 折算后不足 1px 的
  ///   尾巴）时直接吸附到 [target]，避免无限趋近留亚像素抖动；
  /// - 否则走 `current + remaining * factor`，再 clamp 不越过 [target]（因 0<factor<1
  ///   单调逼近，clamp 仅作浮点防御，理论恒不触发，保证不超调）。
  ///
  /// 纯函数，无副作用，轴向无关（[current]/[target] 为原始 scrollLeft，竖排为负值
  /// 同样适用）。供单测锁定「逐帧逼近·单调·收敛不超调」，撤销缓动 → 测试转红。
  ///
  /// [factor] 取值 (0,1]，越大越快收敛（默认调用方传 0.18 ≈ 60fps 下 ~10 帧落定，
  /// 顺滑且不拖沓）；[snap] 为收尾吸附阈值（默认 0.5px）。
  @visibleForTesting
  static double smoothScrollStep({
    required double current,
    required double target,
    double factor = 0.18,
    double snap = 0.5,
  }) {
    final double remaining = target - current;
    if (remaining.abs() <= snap) return target;
    final double next = current + remaining * factor;
    // clamp 不越过 target（指数逼近本不会超调，仅防浮点意外）。
    if (remaining > 0) return next > target ? target : next;
    return next < target ? target : next;
  }

  static String paginateInvocation(ReaderNavigationDirection direction) =>
      "window.fushiReader && window.fushiReader.paginate('${direction.jsValue}')";

  static String progressInvocation() =>
      'window.fushiReader && window.fushiReader.calculateProgress()';

  static String stableProgressInvocation() =>
      'window.fushiReader && !window.fushiReader._reanchorPending '
      '&& window.fushiProgressDetails ? window.fushiProgressDetails() : null';

  static String updatePageSizeInvocation(double width, double height) =>
      'window.fushiReader && window.fushiReader.updatePageSize($width, $height)';

  static ReaderNavigationDirection? navigationDirectionForKey(
    LogicalKeyboardKey key, {
    bool shiftPressed = false,
  }) {
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        (key == LogicalKeyboardKey.space && !shiftPressed)) {
      return ReaderNavigationDirection.forward;
    }
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        (key == LogicalKeyboardKey.space && shiftPressed)) {
      return ReaderNavigationDirection.backward;
    }
    return null;
  }

  static String highlightSentenceAudioCueInvocation(
    String cueId, {
    required bool reveal,
  }) =>
      'window.fushiReader.highlightSentenceAudioCue(${_jsStringLiteral(cueId)}, $reveal)';

  static String clearSentenceAudioCueInvocation() =>
      'window.fushiReader.clearSentenceAudioCue()';

  /// BUG-1743：存在性守卫是第二层防线。裸调 `window.fushiReader.scrollToSearchMatch`
  /// 在未实现该方法的 shell 上抛 TypeError，而 evaluateJavascript 的 JS 异常在
  /// 移动端通道上一般不回传成 Dart 异常——调用点的 try/catch 抓不到，症状只是
  /// 「点了没反应」，且同一次 evaluate 里后续语句会被一并中断。
  /// 同文件 [pageInfoInvocation] 与收藏跳转路径用的都是同款守卫写法。
  static String scrollToSearchMatchInvocation(String query, int hintOffset) =>
      '(window.fushiReader && '
      'typeof window.fushiReader.scrollToSearchMatch === "function") '
      '? window.fushiReader.scrollToSearchMatch('
      '${_jsStringLiteral(query)}, $hintOffset) : null';

  static String clearSearchHighlightInvocation() => '(window.fushiReader && '
      'typeof window.fushiReader.clearSearchHighlight === "function") '
      '? window.fushiReader.clearSearchHighlight() : null';

  /// Returns the current page / total pages within the loaded chapter as a JSON
  /// string (`{"currentPage":N,"totalPages":M}`), or the literal `"null"` when
  /// the reader is in a non-paged mode (continuous) where pages don't apply.
  static String pageInfoInvocation() =>
      'JSON.stringify((window.fushiReader && window.fushiReader.pageInfo) '
      '? window.fushiReader.pageInfo() : null)';

  static String setChromeInsetsInvocation(double topPx, double bottomPx) =>
      'window.fushiReader && window.fushiReader.setChromeInsets($topPx, $bottomPx)';

  /// TODO-693: 连续模式 appUiScale 缩放重锚的第一阶段——在缩放重建那一帧同步采样首个
  /// 可见字符偏移并置 `_reanchorPending`（挡住 reflow 归零 scroll 污染落库）。返回采到
  /// 的字符偏移；-1 = 无可用锚 / 已有重锚在飞 → 调用方跳过提交阶段。
  /// `beginUiScaleReanchor` 只存在于连续模式的 `window.fushiReader`，分页模式缺席，
  /// `typeof` 守卫使分页模式整体 no-op（分页有 snap/lock 保护，无需此重锚）。
  static String beginUiScaleReanchorInvocation() => '(window.fushiReader && '
      "typeof window.fushiReader.beginUiScaleReanchor === 'function') "
      '? window.fushiReader.beginUiScaleReanchor() : -1';

  /// TODO-693: 第二阶段——过渡帧 settle 后把暂存锚滚回视口首边并清 `_reanchorPending`。
  /// 仅当第一阶段成功暂存了有效锚时才生效，否则 no-op（绝不误清别处的重锚旗）。
  static String commitUiScaleReanchorInvocation() => '(window.fushiReader && '
      "typeof window.fushiReader.commitUiScaleReanchor === 'function') "
      '? window.fushiReader.commitUiScaleReanchor() : false';

  /// TODO-736 B-1（必补点2）：样式变更专用两阶段重锚的第一阶段调用——在换样式那一刻
  /// 同步采锚 + 换 CSS（[jsonCss] 须是已 jsonEncode 的 JS 字符串字面量）+ 失效 metrics +
  /// 重置 image-max + 置 `_reanchorPending` + 暂存锚。返回采到的字符偏移；-1 = 无锚 / 已有
  /// 重锚在飞 / pagination 未就绪（无 fushiReader 或非 reader 页）→ 调用方跳过提交阶段并
  /// 自行裸套 CSS 兜底。`beginStyleReanchor` 分页/连续两 shell **各自定义**（不在 _sharedJs，
  /// 因 scrollToCharOffset 签名两 shell 不同）；曾只加进连续 shell、分页缺席致改字号/边距/主题
  /// 等纯 CSS 设置在分页模式不实时生效（守卫见 reader_style_reanchor_both_shells_guard_test）。
  /// 分页/连续各自的 getFirstVisibleCharOffset/scrollToCharOffset 经 `this` 解析（连续含 A-2 兜底）。
  static String beginStyleReanchorInvocation(String jsonCss) =>
      '(window.fushiReader && '
      "typeof window.fushiReader.beginStyleReanchor === 'function') "
      '? window.fushiReader.beginStyleReanchor('
      "document.getElementById('fushi-reader-style'), $jsonCss) : -1";

  /// TODO-736 B-1：第二阶段——过渡帧 settle 后把暂存锚滚回视口首边并清 `_reanchorPending`。
  /// 仅当第一阶段成功暂存了有效锚时才生效，否则 no-op（绝不误清别处的重锚旗）。
  static String commitStyleReanchorInvocation() => '(window.fushiReader && '
      "typeof window.fushiReader.commitStyleReanchor === 'function') "
      '? window.fushiReader.commitStyleReanchor() : false';

  static bool didScroll(String? result) =>
      result?.trim().replaceAll('"', '') == 'scrolled';

  static int? intResult(dynamic result) {
    if (result == null) return null;
    if (result is int) return result;
    if (result is num) return result.toInt();
    if (result is String) {
      return int.tryParse(result.trim().replaceAll('"', ''));
    }
    return null;
  }

  static double? doubleResult(dynamic result) {
    if (result == null) return null;
    if (result is double) return result;
    if (result is num) return result.toDouble();
    if (result is String) {
      return double.tryParse(result.trim().replaceAll('"', ''));
    }
    return null;
  }

  /// 三种 view-mode 的 shell 源码，按模式选一份（零 per-nav 插值）。
  ///
  /// 改动前是 `shellScript({initialProgress, chromeTopInset, sasayakiCuesJson, …})`
  /// —— 每次导航把当次参数插进源码，产出一份全新字符串，Dart 侧每章都要重新拼装 +
  /// 压缩近万行。现在每种 shell 被包成一个只读取运行时 config 的安装函数，源码在一个
  /// 进程里逐字不变，于是可以 memoize（见 `readerEngineSource`）。
  ///
  /// 每个 shell 函数体与改动前对应 shell 的 IIFE 内容逐字对应（`$x` → `C.x`），
  /// 词法作用域自洽：shell 顶层只声明 `_fushiBootInitialize`，其余全部写 `window.*`
  /// 全局，与外层手势层之间没有任何跨作用域引用（守卫
  /// `test/reader/reader_engine_static_source_guard_test.dart`）。
  static String engineShell({
    required bool vnMode,
    required bool continuousMode,
  }) {
    final String shell = vnMode
        ? ReaderVisualNovelScripts.vnShellScript()
        : (continuousMode ? continuousShellSource() : paginatedShellSource());
    return '''<script>
$kStudyUnitJs
window.__fushiShells = {};
${_stripShellScriptTags(shell)}
window.__fushiInstallShell = function(C) {
  if (C.vnMode) return window.__fushiShells.vn(C);
  if (C.continuousMode) return window.__fushiShells.continuous(C);
  return window.__fushiShells.paginated(C);
};
</script>''';
  }

  /// 三个 shell 各自仍以 `<script>…</script>` 形式返回（它们的单测按这个形状钉着），
  /// 拼进引擎时剥掉外层标签。
  static String _stripShellScriptTags(String js) =>
      js.replaceAll('<script>', '').replaceAll('</script>', '').trim();

  // ── Shared JS (properties + methods used by both modes) ────────────

  static const String _sharedJs = r'''
  cueWrappers: new Map(),
  cueRangesMap: new Map(),
  cueRubyElements: new Map(),
  activeCueId: null,
  readerRegexNegated: /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゟァ-ヺー-ヿ０-９Ａ-Ｚａ-ｚｦ-ﾝ\u{2E80}-\u{2EFF}\u{2F00}-\u{2FDF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{F900}-\u{FAFF}\u{20000}-\u{2A6DF}\u{2A700}-\u{2EBE0}\u{2F800}-\u{2FA1F}\u{30000}-\u{323AF}]+/gimu,
  readerRegex: /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゟァ-ヺー-ヿ０-９Ａ-Ｚａ-ｚｦ-ﾝ\u{2E80}-\u{2EFF}\u{2F00}-\u{2FDF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{F900}-\u{FAFF}\u{20000}-\u{2A6DF}\u{2A700}-\u{2EBE0}\u{2F800}-\u{2FA1F}\u{30000}-\u{323AF}]/iu,
  nodeStartOffsets: new WeakMap(),
  // 跨章分段计时（JS 侧）。Dart 的 [ReaderChapterPerfTrace] 只能测到「setup 脚本注入完成
  // → onRestoreComplete 回来」这一整段（真机 ~30ms），无法区分那段里图片等待 / 字符偏移
  // 建表 / 恢复滚动 / IPC 回传各占多少。perfMark 在这几处打点，perfSnapshot 连同浏览器
  // navigation timing（responseEnd / DOMContentLoaded / load）一起随 onRestoreComplete
  // 回传给 Dart。
  //
  // 开关：`_perfOn` 由各 shell 在注入期由 Dart 侧 [ReaderChapterPerfTrace.enabled]
  // 插值写死（见两个 shell 的对象字面量）。生产路径上它恒为 false，perfMark /
  // perfSnapshot 立即 early-return：不读 performance.now()、不走
  // getEntriesByType('navigation')、不做 JSON.stringify。与 Dart 侧同一个开关，
  // 不存在「采集端常开、只 gate 消费端」的无条件热路径开销。
  _perf: {},
  perfMark: function(name) {
    if (this._perfOn !== true) return;
    try { this._perf[name] = performance.now(); } catch (e) {}
  },
  perfSnapshot: function() {
    if (this._perfOn !== true) return '';
    try {
      var out = { marks: this._perf };
      var entries = performance.getEntriesByType ? performance.getEntriesByType('navigation') : null;
      var nav = entries && entries.length ? entries[0] : null;
      if (nav) {
        out.nav = {
          resp: Math.round(nav.responseEnd),
          dcl: Math.round(nav.domContentLoadedEventEnd),
          load: Math.round(nav.loadEventEnd)
        };
      }
      return JSON.stringify(out);
    } catch (e) { return ''; }
  },
  isVertical: function() {
    return window.getComputedStyle(document.body).writingMode === "vertical-rl";
  },
  // BUG-493 根因修复：_reanchorPending 的唯一写入口（清旗单点化，_sharedJs 两 shell 共用）。
  // true→false 转换 = 重锚 settle，那一刻（bridge 可用时）callHandler('onReanchorSettled')
  // 通知 Dart 补刷一次进度（webview.part.dart 注册），事件驱动替代旧的 Dart 侧 120ms×8
  // 轮询重试——setChromeInsets/updatePageSize/begin·commit 系列任何一处清旗（含 commit
  // 成功之外的逃逸路径）都会通知，进度不再锁死等 10s 轮询。
  _setReanchorPending: function(value) {
    var settled = this._reanchorPending === true && value !== true;
    this._reanchorPending = value === true;
    if (settled && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      try { window.flutter_inappwebview.callHandler('onReanchorSettled'); } catch (e) {}
    }
  },
  // wave1 去重：content-box 尺寸探针（body clientWidth/Height 扣 padding）。曾在分页/连续
  // 两 shell 尾部各挂一份逐字相同的 window.fushiReader._contentSize = function(){...}；上移进
  // _sharedJs 作对象字面量属性，两 shell 经 $_sharedJs 各得一份、字节等价（_imageMaxBox 经
  // this._contentSize() 调用，属性先于 initialize 求值，定义先于使用）。
  _contentSize: function() {
    var cs = getComputedStyle(document.body);
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var pt = parseFloat(cs.paddingTop) || 0;
    var pb = parseFloat(cs.paddingBottom) || 0;
    return { w: (document.body.clientWidth || window.innerWidth) - pl - pr, h: (document.body.clientHeight || window.innerHeight) - pt - pb };
  },
  // TODO-1285（图片挤压根因修复）：每页多列(pageColumns>=2)时 multicol 把「turn 轴」
  // （横排=宽 / 竖排=高）切成 N 个子列，但图片 max 约束过去恒用整 content-box（cs.w/cs.h）
  // → 整页插图按整页 turn 轴撑开，远超单个子列 → 溢出本列、盖住相邻列正文（用户报「图片
  // 被挤压」的真相：宽插图横跨两列压字）。修复：turn 轴的图片 max 改用**浏览器 used 子列宽**
  // getComputedStyle(body).columnWidth（与 getScrollContext 读的同一权威真值：横排=子列宽、
  // 竖排=子列高），图片正好落进本列不越界；block 轴（横排=高 / 竖排=宽）仍用整 content-box
  // （每列在 block 轴填满整页），不变。仅当 used 子列明显窄于整轴（真 pageColumns>=2）才夹到
  // 子列；单列 / 连续 / VN（无 column-count → columnWidth=='auto'→NaN，或子列≈整轴）回退整轴、
  // 与旧 cs.w/cs.h 字节等价（零回归，不碰 TODO-729/753/792 分页几何）。ratio 恒作用在宽（与旧同）。
  _imageMaxBox: function() {
    var cs = this._contentSize();
    var ratio = (typeof this._imageWidthRatio === 'number') ? this._imageWidthRatio : 1;
    var vertical = this.isVertical();
    var turnFull = vertical ? cs.h : cs.w;
    var usedColW = parseFloat(getComputedStyle(document.body).columnWidth);
    var multicol = usedColW > 0 && usedColW < turnFull - 1;
    if (vertical) {
      var h = multicol ? Math.round(usedColW) : cs.h;
      return { w: Math.max(1, Math.floor(cs.w * ratio)), h: Math.max(1, h) };
    }
    var w = multicol ? usedColW : cs.w;
    return { w: Math.max(1, Math.floor(w * ratio)), h: Math.max(1, cs.h) };
  },
  isFurigana: function(node) {
    var el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('rt, rp'));
  },
  normalizeText: function(text) {
    return (text || '').replace(this.readerRegexNegated, '');
  },
  // 统计 / 进度口径：学习单位数（无空格文字按码点、空格分词文字按连续串）。与 Dart
  // countStudyChars 逐样本对拍（study_char_count_parity_test.dart）。**不要**改回
  // normalizeText——那套白名单是有声书 cue 匹配与纯图片章判定的坐标系，见
  // reader_study_unit_script.dart 的「与匹配 / 归一化的分界」。
  countChars: function(text) {
    return window.fushiStudyUnits.count(text);
  },
  isMatchableChar: function(char) {
    return this.readerRegex.test(char || '');
  },
  // TODO-630 / BUG-366：sasayaki 高亮运行期把 cue 原文 needle 在实时 DOM 归一化全文
  // full 里做 full.indexOf(needle) 重定位（BUG-060）。匹配坐标系（Dart
  // AudioTextNormalizer.normalize）除剥非白名单字符外还做**值折叠**（片假名→平假名 /
  // 大小写折叠 / 全角→ASCII / 半角片假名→全角片假名）；JS 这边过去只剥不折，于是
  // 折叠类书（SRT 片假名 vs EPUB 平假名、全角 vs 半角）needle 在 full 里 indexOf 落空
  // → 回落 hint → 高亮看似「不显示/错位」。下面 foldCodePoint 与 AudioTextNormalizer
  // 的值转换严格同口径。所有折叠都是单 BMP 码元→单 BMP 码元（1:1 码元），因此
  // buildSasayakiNormIndex 的逐码元 map 粒度（代理对 push 两条）保持不变。
  hwKataToFwBase: 0xFF66,
  hwKataToFw: [0x30F2,0x30A1,0x30A3,0x30A5,0x30A7,0x30A9,0x30E3,0x30E5,0x30E7,0x30C3,0x30FC,0x30A2,0x30A4,0x30A6,0x30A8,0x30AA,0x30AB,0x30AD,0x30AF,0x30B1,0x30B3,0x30B5,0x30B7,0x30B9,0x30BB,0x30BD,0x30BF,0x30C1,0x30C4,0x30C6,0x30C8,0x30CA,0x30CB,0x30CC,0x30CD,0x30CE,0x30CF,0x30D2,0x30D5,0x30D8,0x30DB,0x30DE,0x30DF,0x30E0,0x30E1,0x30E2,0x30E4,0x30E6,0x30E8,0x30E9,0x30EA,0x30EB,0x30EC,0x30ED,0x30EF,0x30F3],
  foldCodePoint: function(cp) {
    var out = cp;
    if (cp >= 0x41 && cp <= 0x5A) out = cp + 0x20;            // ASCII A-Z -> a-z
    else if (cp >= 0xFF21 && cp <= 0xFF3A) out = cp - 0xFEC0; // fullwidth A-Z -> a-z
    else if (cp >= 0xFF41 && cp <= 0xFF5A) out = cp - 0xFEE0; // fullwidth a-z -> a-z
    else if (cp >= 0xFF10 && cp <= 0xFF19) out = cp - 0xFEE0; // fullwidth 0-9 -> 0-9
    else if (cp >= 0xFF66 && cp <= 0xFF9D) out = this.hwKataToFw[cp - this.hwKataToFwBase]; // halfwidth kana -> fullwidth kana
    if (out >= 0x30A1 && out <= 0x30F6) out -= 0x60;          // katakana -> hiragana
    return out;
  },
  foldNormalize: function(text) {
    var stripped = this.normalizeText(text);
    var folded = '';
    var i = 0;
    while (i < stripped.length) {
      var cp = stripped.codePointAt(i);
      var ch = String.fromCodePoint(cp);
      folded += String.fromCodePoint(this.foldCodePoint(cp));
      i += ch.length;
    }
    return folded;
  },
  scrollToProgressContinuous: function(progress) {
    var targetNode = this.findNodeAtProgress(progress);
    if (targetNode && targetNode.parentElement) {
      targetNode.parentElement.scrollIntoView({
        block: progress >= 0.999999 ? 'end' : 'start',
        inline: 'nearest',
        behavior: 'instant'
      });
    }
  },
  findNodeAtProgress: function(progress) {
    var walker = this.createWalker();
    var totalChars = 0;
    var node;
    while (node = walker.nextNode()) {
      totalChars += this.countChars(node.textContent);
    }
    if (totalChars <= 0) return null;
    var targetCharCount = Math.ceil(totalChars * progress);
    var runningSum = 0;
    var targetNode = null;
    walker = this.createWalker();
    while (node = walker.nextNode()) {
      runningSum += this.countChars(node.textContent);
      if (runningSum > targetCharCount) { targetNode = node; break; }
    }
    return targetNode;
  },
  scrollToProgressPaged: function(context, progress) {
    if (context.pageSize <= 0 || progress <= 0) {
      this.setPagePosition(context, this.contentFirstPageScroll(context));
      return;
    }
    if (progress >= 0.99) {
      this.setPagePosition(context, Math.max(0, this.contentLastPageScroll(context)));
      return;
    }
    var targetNode = this.findNodeAtProgress(progress);
    if (targetNode) {
      var range = document.createRange();
      range.setStart(targetNode, 0);
      range.setEnd(targetNode, Math.min(1, targetNode.length));
      var rect = this.getRect(range);
      var scroll = this.getPagePosition(context);
      var anchor = (context.vertical ? rect.top : rect.left) + scroll;
      this.setPagePosition(context, this.alignToPage(context, anchor));
    }
  },
  // TODO-1349（续·用户复诉「文字少也会去到最开头」）：把仍标记 loading="lazy" 的图强制翻成
  // eager 触发 load。往前翻到「文字少+图片」章的章末时，尾部整页插图仍是 lazy（非纯图片章
  // __fushiImageOnlyChapter=false），离屏 → 永不 load → 0 尺寸被 buildPaginationMetrics
  // 排除（分页 maxScroll 塌缩到章首）/ 被 scrollToChapterEnd 可见性判据跳过（连续停章首），
  // 且懒图 __imgReanchorProgress 重锚永不触发（尾图永不进视口 = 鸡生蛋）。这里在章末恢复时
  // 强制 load 打破鸡生蛋，图尺寸解析后走既有 load 回调重锚（分页 scrollToProgressPaged /
  // 连续 scrollToChapterEnd）落到含真实尾图几何的章末。仅往前翻到章末(restoreProgress>=0.99)
  // 触发，正向阅读 / 精确 char 锚不动 → 不回退 TODO-1074 懒加载；幂等（无 lazy 则 no-op）。
  forceLoadPendingImages: function() {
    var imgs = document.querySelectorAll('img[loading="lazy"]');
    for (var i = 0; i < imgs.length; i++) {
      imgs[i].setAttribute('loading', 'eager');
    }
  },
  // ── 迟到图片的语义重锚（TODO-1229 案B 的一般化 · BUG-1140 第二轮）─────────
  //
  // 恢复落点由「章内**语义锚**」定义：精确字符偏移（restoreToCharOffset）、粗粒度
  // progress（restoreProgress —— progressStops 同样是字符域）、或 fragment 目标元素。
  // 这三种锚本身与图片是否已 decode 无关，但把锚**换算成 scroll** 的那一步依赖当下
  // 几何：锚之前若有尚未 load 的懒图（0×0），换算结果就少了那些图的高度。图片随后
  // load、几何后移，冻结的 scroll 便指向别的内容——用户看到的位置漂了，随后
  // onReaderScroll 还会把这个漂掉的读数落库。
  //
  // 修法不是「恢复前等图片」（那正是要消除的整个加载周期），而是**图片 load 后按同一个
  // 语义锚重算一次**：终态与「图片本来就在」等价。仅在恢复落地后、用户尚未翻页的窗口内
  // 有效（paginate 清资格），且只由真正改变几何的 block 图 load 触发。重锚是程序化滚动，
  // 走既有 onReaderScroll 通道把**修正后**的位置落库（既有 >=0.99 章末重锚同一条路）。
  registerImageLateAnchor: function(anchor) {
    this.clearImageLateAnchor();
    if (!anchor) return;
    if (typeof anchor.charOffset === 'number') {
      this.__imgReanchorCharOffset = anchor.charOffset;
      this.__imgReanchorCharOffsetEnd = anchor.endCharOffset;
    } else if (typeof anchor.progress === 'number') {
      this.__imgReanchorProgress = anchor.progress;
    } else if (anchor.fragment) {
      this.__imgReanchorFragment = anchor.fragment;
    }
  },
  clearImageLateAnchor: function() {
    this.__imgReanchorProgress = null;
    this.__imgReanchorCharOffset = null;
    this.__imgReanchorCharOffsetEnd = -1;
    this.__imgReanchorFragment = null;
  },
  // 连续 shell 独有 scrollToChapterEnd —— 与既有重锚回调同一条判别（不能用
  // scrollToProgressPaged，那是 _sharedJs 两 shell 都有的，连续会误走分页分支）。
  _isContinuousShell: function() {
    return typeof this.scrollToChapterEnd === 'function';
  },
  reapplyImageLateAnchor: function() {
    var co = this.__imgReanchorCharOffset;
    if (typeof co === 'number' && co > 0) {
      if (this._isContinuousShell()) {
        this.scrollToCharOffset(co, this.__imgReanchorCharOffsetEnd);
      } else {
        this.scrollToCharOffset(co);
      }
      return true;
    }
    if (this.__imgReanchorFragment) {
      return this.alignToFragmentTarget(this.__imgReanchorFragment);
    }
    var p = this.__imgReanchorProgress;
    if (typeof p !== 'number') return false;
    if (this._isContinuousShell()) {
      if (p >= 0.99) this.scrollToChapterEnd();
      else if (p <= 0) this.scrollToChapterStart();
      else this.scrollToProgressContinuous(p);
      return true;
    }
    var rctx = this.getScrollContext();
    if (!rctx || rctx.pageSize <= 0) return false;
    this.scrollToProgressPaged(rctx, p);
    return true;
  },
  notifyRestoreComplete: function() {
    this.perfMark('restoreDone');
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler(
        'onRestoreComplete',
        this.perfSnapshot(),
        C.navigationGeneration
      );
    }
    if (typeof this.warmPaginationMetrics === 'function') {
      this.warmPaginationMetrics();
    }
  },
  createWalker: function(rootNode) {
    var root = rootNode || document.body;
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => this.isFurigana(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
    });
  },
  getRect: function(target) {
    var rect = target.getClientRects()[0];
    return rect || target.getBoundingClientRect();
  },
  buildNodeOffsets: function() {
    var offsets = new WeakMap();
    var walker = this.createWalker();
    var count = 0;
    var node;
    while (node = walker.nextNode()) {
      offsets.set(node, count);
      count += this.countChars(node.textContent);
    }
    this.nodeStartOffsets = offsets;
    if (this.paginationMetrics !== undefined) this.paginationMetrics = null;
  },
  // BUG-492 (TODO-1053 Bug A) 越界判据（分页/连续共用，_sharedJs）：charOffset 是否落在
  // 本章可匹配字符总数之内。恢复端用它护住旧脏收藏——写入端曾把某句错记成相邻章
  // sectionIndex，恢复加载错章后 charOffset 可能超本章字符总数 → 定位静默失败停错位。
  // 越界即回退章首（确定性落点）而非静默停。与 scrollToCharOffset 的走查同口径
  // （countChars / createWalker，furigana 已 REJECT）。>=0 且在范围内返 true。
  charOffsetInRange: function(charOffset) {
    if (typeof charOffset !== 'number' || charOffset < 0) return false;
    var walker = this.createWalker();
    var runningOffset = 0;
    var node;
    while (node = walker.nextNode()) {
      runningOffset += this.countChars(node.textContent);
      if (runningOffset > charOffset) return true;
    }
    return false;
  },
  // TODO-736 A-1：连续模式进度的「字符级」分子。移植安卓 reader-continuous.js
  // countCharsBeforeViewport（:92-151）：返回本文本节点里**已滚出视口首边**的可匹配字符
  // 数（与 countChars / isMatchableChar 同口径作分子，calculateProgress 总字符作分母）。
  // 旧连续 calculateProgress 是「整节点 in/out」段落级粗粒度——节点只要有一像素还在视口
  // 就把整节点算未读，跨视口的长节点进度按整节点跳变 → 滚动模式进度感觉「没保存/不动」。
  // 这里对整节点先用 getClientRects 的并集矩形做三态短路（全过=满、全未过=0），仅当节点
  // 跨视口首边时才逐字二分定位首个仍可见字符，O(log n) 不全量遍历。空/零尺寸矩形跳过
  // （图片/折叠盒），代理对用 codePointAt/fromCodePoint 迭代（与 buildSasayakiNormIndex
  // 的码元处理一致），createWalker 已排除 rt/rp 振假名（分子分母同套，不重复计数）。
  //
  // 可选 edge（viewport 量纲）：缺省 = 视口**首边**（横排 0 / 竖排 window.innerWidth），
  // 逐字判据走 isTextOffsetBeforeViewport（TODO-773 守卫钉死其 window 量纲三件套，不加
  // 参数）；显式传入时 = 任意边（连续 getLastVisibleCharOffset 传视口**末边**：横排
  // window.innerHeight / 竖排 0），逐字判据走同算法的通用边版本 isTextOffsetBeforeViewportPaged
  // （名字里的 Paged 是它 body-relative 的出身，语义就是「rect 是否已越过给定边」）。
  countCharsBeforeViewport: function(node, vertical, edge) {
    var text = node.textContent || '';
    var totalChars = this.countChars(text);
    if (totalChars <= 0) return 0;
    var atFirstEdge = edge === undefined;
    if (atFirstEdge) edge = vertical ? window.innerWidth : 0;
    var range = document.createRange();
    range.selectNodeContents(node);
    var rects = range.getClientRects();
    if (!rects.length) return 0;
    var minStart = Infinity;
    var maxEnd = -Infinity;
    for (var i = 0; i < rects.length; i++) {
      var rect = rects[i];
      if (rect.width <= 0 || rect.height <= 0) continue;
      var start = vertical ? rect.left : rect.top;
      var end = vertical ? rect.right : rect.bottom;
      minStart = Math.min(minStart, start);
      maxEnd = Math.max(maxEnd, end);
    }
    if (vertical) {
      if (minStart >= edge) return totalChars;
      if (maxEnd <= edge || minStart === Infinity) return 0;
    } else {
      if (maxEnd <= edge) return totalChars;
      if (minStart >= edge || minStart === Infinity) return 0;
    }
    var offsets = [];
    var prefixCounts = [0];
    var count = 0;
    var offset = 0;
    while (offset < text.length) {
      offsets.push(offset);
      var char = String.fromCodePoint(text.codePointAt(offset));
      // 学习单位在**串尾**结算，判据吃位置而不是单个字符（见 reader_study_unit_script.dart）。
      if (window.fushiStudyUnits.isUnitEnd(text, offset)) count += 1;
      offset += char.length;
      prefixCounts.push(count);
    }
    var low = 0;
    var high = offsets.length - 1;
    var firstVisible = offsets.length;
    while (low <= high) {
      var mid = Math.floor((low + high) / 2);
      var passed = atFirstEdge
        ? this.isTextOffsetBeforeViewport(node, offsets[mid], text, vertical)
        : this.isTextOffsetBeforeViewportPaged(node, offsets[mid], text, vertical, edge);
      if (passed) {
        low = mid + 1;
      } else {
        firstVisible = mid;
        high = mid - 1;
      }
    }
    return prefixCounts[firstVisible];
  },
  // TODO-736 A-1：单字符是否已滚出视口首边（横排 rect.bottom<=0 / 竖排 rect.left>=innerWidth）。
  // 移植安卓 isTextOffsetBeforeViewport（:142-151）。零尺寸矩形（折叠/不可见）当未过，
  // 让二分把视口首边收敛到首个**真正可见**字符。
  isTextOffsetBeforeViewport: function(node, offset, text, vertical) {
    var char = String.fromCodePoint(text.codePointAt(offset));
    if (!char) return false;
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, offset + char.length);
    var rect = this.getRect(range);
    if (!rect || rect.width <= 0 || rect.height <= 0) return false;
    return vertical ? rect.left >= window.innerWidth : rect.bottom <= 0;
  },
  // TODO-736 A-2：getFirstVisibleCharOffset 的全文扫描兜底。连续模式下 caretRangeFromPoint
  // 在竖排 / ruby / 图片页 / 视口首边落在折叠盒时返 null → getFirstVisibleCharOffset 退化
  // 返 -1（落库丢精确锚、退回章节粒度分数）。本兜底用 countCharsBeforeViewport 全文累加，
  // 返「视口首边之前的可匹配字符总数」= 首个可见字符的绝对字符偏移（与 scrollToCharOffset
  // 的字符坐标系同口径，逆运算），无 caret 几何依赖。仅连续模式调用（分页有 snap/lock）。
  firstVisibleCharOffsetByScan: function() {
    var vertical = this.isVertical();
    var walker = this.createWalker();
    var explored = 0;
    var node;
    while (node = walker.nextNode()) {
      if (this.countChars(node.textContent) > 0) {
        explored += this.countCharsBeforeViewport(node, vertical);
      }
    }
    return explored;
  },
  // TODO-773 P0：分页版 getFirstVisibleCharOffset 的扫描兜底。竖排切字号/字体/主题后
  // 页顶常落 ruby / 图片 / 折叠盒 → caretRangeFromPoint 返 null → 分页版三个失败出口
  // 裸 return -1 → beginStyleReanchor 返 -1 → Dart 跳过 commit → CSS 已换但 scrollTop
  // 停残值不滚回 → 文字漂移。连续版在相同三失败点早已回退 firstVisibleCharOffsetByScan，
  // 但**不能裸抄连续版**：连续版判据用 window 量纲（window.innerWidth），而分页几何是
  // body-relative（getScrollContext scrollEl=document.body / 分页版 caret 探边用
  // document.body.clientWidth-pr，刻意不用 window.innerWidth）。分页模式下 body
  // overflow:hidden + margin:0 + width:--page-width 使 body 填满视口左上角(0,0)，故横排
  // 视口首边(top)仍是 viewport-y 0（与连续同），唯一差异是竖排首边(right)：连续用
  // window.innerWidth，分页必须用 document.body.clientWidth（与分页 caret 探边同量纲），
  // 否则 body 不满窗时判据相差几像素→兜底锚到错列。故另立分页专版（option a），保持连续
  // 版 window 量纲三件套零改动，各路径量纲就地可见（不靠参数分支）。仅分页 shell 调用。
  firstVisibleCharOffsetByScanPaged: function() {
    var vertical = this.isVertical();
    var firstEdge = vertical ? document.body.clientWidth : 0;
    var walker = this.createWalker();
    var explored = 0;
    var node;
    while (node = walker.nextNode()) {
      if (this.countChars(node.textContent) > 0) {
        explored += this.countCharsBeforeViewportPaged(node, vertical, firstEdge);
      }
    }
    return explored;
  },
  // TODO-773 P0：countCharsBeforeViewport 的分页版（body-relative 首边）。与连续版逐字
  // 二分定位同算法，仅把视口首边参照从 window.innerWidth（竖排）/ 0（横排）改为传入的
  // firstEdge（竖排=document.body.clientWidth / 横排=0），其余三态短路、零尺寸跳过、
  // 代理对迭代全部一致。
  countCharsBeforeViewportPaged: function(node, vertical, firstEdge) {
    var text = node.textContent || '';
    var totalChars = this.countChars(text);
    if (totalChars <= 0) return 0;
    var range = document.createRange();
    range.selectNodeContents(node);
    var rects = range.getClientRects();
    if (!rects.length) return 0;
    var minStart = Infinity;
    var maxEnd = -Infinity;
    for (var i = 0; i < rects.length; i++) {
      var rect = rects[i];
      if (rect.width <= 0 || rect.height <= 0) continue;
      var start = vertical ? rect.left : rect.top;
      var end = vertical ? rect.right : rect.bottom;
      minStart = Math.min(minStart, start);
      maxEnd = Math.max(maxEnd, end);
    }
    if (vertical) {
      if (minStart >= firstEdge) return totalChars;
      if (maxEnd <= firstEdge || minStart === Infinity) return 0;
    } else {
      if (maxEnd <= firstEdge) return totalChars;
      if (minStart >= firstEdge || minStart === Infinity) return 0;
    }
    var offsets = [];
    var prefixCounts = [0];
    var count = 0;
    var offset = 0;
    while (offset < text.length) {
      offsets.push(offset);
      var char = String.fromCodePoint(text.codePointAt(offset));
      // 学习单位在**串尾**结算，判据吃位置而不是单个字符（见 reader_study_unit_script.dart）。
      if (window.fushiStudyUnits.isUnitEnd(text, offset)) count += 1;
      offset += char.length;
      prefixCounts.push(count);
    }
    var low = 0;
    var high = offsets.length - 1;
    var firstVisible = offsets.length;
    while (low <= high) {
      var mid = Math.floor((low + high) / 2);
      if (this.isTextOffsetBeforeViewportPaged(node, offsets[mid], text, vertical, firstEdge)) {
        low = mid + 1;
      } else {
        firstVisible = mid;
        high = mid - 1;
      }
    }
    return prefixCounts[firstVisible];
  },
  // TODO-773 P0：isTextOffsetBeforeViewport 的分页版（body-relative 首边）。竖排判
  // rect.left>=firstEdge（=document.body.clientWidth）、横排判 rect.bottom<=firstEdge（=0）。
  isTextOffsetBeforeViewportPaged: function(node, offset, text, vertical, firstEdge) {
    var char = String.fromCodePoint(text.codePointAt(offset));
    if (!char) return false;
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, offset + char.length);
    var rect = this.getRect(range);
    if (!rect || rect.width <= 0 || rect.height <= 0) return false;
    return vertical ? rect.left >= firstEdge : rect.bottom <= firstEdge;
  },
  buildSentenceAudioNormIndex: function() {
    // 一次性遍历 DOM 文本节点（createWalker 跳过振假名 rt/rp），构建归一化
    // 全文 full 与反查表 map：map[k] = {node,start,end}（第 k 个归一化字符在其
    // 文本节点内的原始 UTF-16 偏移区间）。归一化口径 = isMatchableChar，与
    // normalizeText 同口径（白名单：假名/汉字/字母数字），再经 foldCodePoint
    // 做值折叠（片假名→平假名/大小写/全角→ASCII），与 Dart AudioTextNormalizer 对齐（TODO-630）。
    var walker = this.createWalker();
    var node;
    var map = [];
    var full = '';
    while (node = walker.nextNode()) {
      var text = node.textContent;
      var i = 0;
      var chunk = '';
      while (i < text.length) {
        var ch = String.fromCodePoint(text.codePointAt(i));
        var next = i + ch.length;
        if (this.isMatchableChar(ch)) {
          // full 是 UTF-16 码元串（full.indexOf 返回码元偏移），map 必须与之同粒度：
          // 星平面字符（CJK 扩展 B+，白名单含  0+）占 2 个码元，push 两条
          // 指向同一原始区间的反查项，否则码元偏移索引逐码点 map 会在代理对后错位。
          for (var u = 0; u < ch.length; u++) {
            map.push({ node: node, start: i, end: next });
          }
          // TODO-630/BUG-366：折叠入 full，与 cue needle(foldNormalize) 同口径。
          // 折叠是 1:1 码元，上面 map 的 ch.length 粒度不变。
          chunk += String.fromCodePoint(this.foldCodePoint(text.codePointAt(i)));
        }
        i = next;
      }
      full += chunk;
    }
    return { full: full, map: map };
  },
  rangesForNormSpan: function(map, normStart, normLen) {
    // 把归一化区间 [normStart, normStart+normLen) 映射成按文本节点分组的 DOM
    // 子区间；同一节点内被跨过的非匹配字符（标点等）一并纳入（保持原视觉）。
    var ranges = [];
    if (normLen <= 0 || normStart < 0 || normStart >= map.length) return ranges;
    var endEx = Math.min(normStart + normLen, map.length);
    var curNode = null, curStart = 0, curEnd = 0;
    for (var k = normStart; k < endEx; k++) {
      var e = map[k];
      if (e.node !== curNode) {
        if (curNode) ranges.push({ node: curNode, start: curStart, end: curEnd });
        curNode = e.node; curStart = e.start; curEnd = e.end;
      } else {
        curEnd = e.end;
      }
    }
    if (curNode) ranges.push({ node: curNode, start: curStart, end: curEnd });
    return ranges;
  },
  collectSentenceAudioCueRanges: function(cues) {
    // BUG-060：高亮坐标由实时 DOM 权威定位。匹配时算出的 start/length 仅作
    // 「提示」，运行时用 cue 原文 text 在实时 DOM 的归一化全文里就近、单调地
    // 重新定位 —— 摆脱 package:html(匹配坐标系) 与浏览器 DOM(渲染坐标系) 逐字
    // 不一致导致的累积偏移。不变量：① 游标 cursor 单调不回退；② 搜索窗口有界
    // (整句 needle + 半径 WINDOW)，不跳远处重复句；③ 窗口内取离 hint 最近者；
    // ④ 未命中回落提示偏移，绝不空高亮。与 Dart 影子
    // ReaderPaginationScripts.resolveCueNormStartsForTesting 同算法。
    var out = [];
    if (!cues.length) return out;
    var idx = this.buildSentenceAudioNormIndex();
    var full = idx.full;
    var map = idx.map;
    var WINDOW = 256;
    var cursor = 0;
    for (var ci = 0; ci < cues.length; ci++) {
      var cue = cues[ci];
      // TODO-630/BUG-366：needle 用 foldNormalize（剥+折叠），与 full(已折叠)、
      // 与 Dart matcher 的折叠坐标系对齐，折叠类书才能 indexOf 命中。
      var needle = this.foldNormalize(cue.text || '');
      var hint = (typeof cue.start === 'number') ? cue.start : cursor;
      var len = (typeof cue.length === 'number') ? cue.length : 0;
      var normLen = needle.length;
      var resolved = -1;
      if (normLen > 0) {
        var lo = cursor > (hint - WINDOW) ? cursor : (hint - WINDOW);
        var startAt = lo < 0 ? 0 : lo;
        var best = -1, bestDist = 1 << 30;
        if (startAt <= full.length) {
          var from = startAt;
          while (true) {
            var p = full.indexOf(needle, from);
            if (p < 0 || p > hint + WINDOW) break;
            var d = Math.abs(p - hint);
            if (d < bestDist) { bestDist = d; best = p; }
            from = p + 1;
          }
        }
        if (best >= 0) { resolved = best; cursor = best + normLen; }
      }
      var spanStart, spanLen;
      if (resolved >= 0) {
        spanStart = resolved; spanLen = normLen;
      } else {
        // BUG-282：未命中只给这一条 cue 一个尽力而为的回落区间，**不推进单调
        // 游标 cursor**。游标只在 DOM 真命中时前进；让回落按未核实的 hint 猜测
        // 推进游标会越过后面真正能命中 cue 的真实位置，把其搜索窗口下界顶过去
        // → 整本逐句累积漂移（与 Dart 影子 resolveCueNormStartsForTesting 同改）。
        spanStart = hint < cursor ? cursor : (hint > map.length ? map.length : hint);
        spanLen = len;
      }
      out.push({ id: cue.id, ranges: this.rangesForNormSpan(map, spanStart, spanLen) });
    }
    // TODO-630/BUG-366 observability：full 长度 + 多少 cue 算出空 range（全空=路径/折叠未命中）。
    var emptyRanges = 0;
    for (var oi = 0; oi < out.length; oi++) { if (!out[oi].ranges.length) emptyRanges++; }
    try { console.log('[sentence-audio-hl] collectRanges cues=' + cues.length + ' fullLen=' + full.length +
      ' emptyRanges=' + emptyRanges + (out.length ? ' firstNeedleLen=' + (this.foldNormalize(cues[0].text || '').length) : '')); } catch (e) {}
    return out;
  },
  applySentenceAudioCues: function(cues) {
    if (window.fushiSelection) window.fushiSelection.clearSelection();
    this.resetSentenceAudioCues();
    // TODO-630/BUG-366 observability：payload 是否带 cue、CSS highlights 支持与否、
    // sasayaki 背景色变量值（透明/缺失 → 即使 range 命中也看不见）。一次性诊断只打一行。
    try {
      var n = cues && cues.length ? cues.length : 0;
      if (!this.__sentenceAudioDiagLogged) {
        this.__sentenceAudioDiagLogged = true;
        var bg = '';
        try { bg = getComputedStyle(document.documentElement).getPropertyValue('--fushi-sentence-audio-background-color'); } catch (e) {}
        console.log('[sentence-audio-hl] diag cssHighlightsSupported=' + (!!window.__fushiCssHighlightsSupported) +
          ' sentenceAudioBg="' + (bg || '').trim() + '"');
      }
      console.log('[sentence-audio-hl] applySentenceAudioCues payloadCues=' + n);
    } catch (e) {}
    var cueSegments = this.collectSentenceAudioCueRanges(cues);
    // BUG-643：普通正文也不能再走 ::highlight(fushi-sasayaki)。竖排 WebKit 会按
    // line-height 行盒刷背景，导致无振假名的「の顔色が変わった」比 ruby 基字更宽。
    // 改为：ruby 节点继续收集到 cueRubyElements；普通文本包 fushi-sasayaki-cue span，
    // active 时由 CSS 画同一条 1em 正文 lane。倒序包裹，避免先拆前文导致后续 offset 漂移。
    var range = document.createRange();
    for (var i = cueSegments.length - 1; i >= 0; i--) {
      var id = cueSegments[i].id;
      var segments = cueSegments[i].ranges;
      if (!segments.length) continue;
      var wrappers = [];
      var rubyElements = [];
      for (var j = segments.length - 1; j >= 0; j--) {
        var ruby = this.rubyForNode(segments[j].node);
        if (ruby) {
          if (rubyElements.indexOf(ruby) < 0) rubyElements.push(ruby);
          continue;
        }
        try {
          range.setStart(segments[j].node, segments[j].start);
          range.setEnd(segments[j].node, segments[j].end);
          var wrapper = document.createElement('span');
          wrapper.className = 'fushi-sentence-audio-cue';
          wrapper.appendChild(range.extractContents());
          range.insertNode(wrapper);
          wrappers.push(wrapper);
        } catch (e) {}
      }
      wrappers.reverse();
      rubyElements.reverse();
      if (wrappers.length) this.cueWrappers.set(id, wrappers);
      if (rubyElements.length) this.cueRubyElements.set(id, rubyElements);
    }
    this.buildNodeOffsets();
  },
  rubyForNode: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('ruby') : null;
  },
  highlightSentenceAudioCue: function(cueId, reveal) {
    this.clearSentenceAudioCue();
    if (window.__fushiCssHighlightsSupported) CSS.highlights.delete('fushi-sentence-audio');
    var wrappers = this.cueWrappers.get(cueId) || [];
    var rubyElements = this.cueRubyElements.get(cueId) || [];
    // TODO-630/BUG-366 observability：本 cue 拿到几个文本 span/ruby；0+0 → 直接 return null（不高亮）。
    try { console.log('[sentence-audio-hl] highlightCue ranges=' + wrappers.length + ' ruby=' + rubyElements.length +
      (!wrappers.length && !rubyElements.length ? ' RETURN_NULL_no_segments' : '')); } catch (e) {}
    if (!wrappers.length && !rubyElements.length) return null;
    this.activeCueId = cueId;
    wrappers.forEach(function(wrapper) { wrapper.classList.add('fushi-sentence-audio-active'); });
    // ruby 元素用 class 高亮（背景画在元素上，避免 ::highlight 对 ruby 双绘，BUG-110）
    rubyElements.forEach(function(ruby) { ruby.classList.add('fushi-sentence-audio-ruby-active'); });
    if (reveal) {
      var target = wrappers.length ? wrappers[0] : rubyElements[0];
      if (target && this.revealElement && this.revealElement(target)) {
        return this.calculateProgress();
      }
    }
    return null;
  },
  // 反查：把屏幕坐标解析到所属 cue 的标识，供中键 seek 用。先认合成书可点的
  // [data-cue-id]（sentenceIndex），否则用 caret 点在 cueRangesMap / cueWrappers
  // （键=textFragmentId）里做包含判定。命中回 JSON.stringify({type,id})，无命中
  // 回 null。复用既有 cue↔DOM 映射，不碰 normChar 反查数学（规避码点代理对错位）。
  cueIdAtPoint: function(x, y) {
    var el = document.elementFromPoint(x, y);
    if (el && el.closest) {
      var sidEl = el.closest('[data-cue-id]');
      if (sidEl) {
        var sid = sidEl.getAttribute('data-cue-id');
        if (sid !== null) return JSON.stringify({ type: 'sid', id: sid });
      }
    }
    if (!window.fushiSelection || !window.fushiSelection.getCaretRange) return null;
    var caret = window.fushiSelection.getCaretRange(x, y);
    if (!caret) return null;
    var node = caret.startContainer, off = caret.startOffset;
    var found = null;
    if (this.cueRangesMap && this.cueRangesMap.size) {
      this.cueRangesMap.forEach(function(ranges, id) {
        if (found) return;
        for (var i = 0; i < ranges.length; i++) {
          try { if (ranges[i].comparePoint(node, off) === 0) { found = id; break; } }
          catch (e) {}
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    if (this.cueRubyElements && this.cueRubyElements.size) {
      this.cueRubyElements.forEach(function(rubyElements, id) {
        if (found) return;
        for (var i = 0; i < rubyElements.length; i++) {
          if (rubyElements[i].contains(node)) { found = id; break; }
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    if (this.cueWrappers && this.cueWrappers.size) {
      this.cueWrappers.forEach(function(wrappers, id) {
        if (found) return;
        for (var i = 0; i < wrappers.length; i++) {
          if (wrappers[i].contains(node)) { found = id; break; }
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    return null;
  },
  clearSentenceAudioCue: function() {
    if (!this.activeCueId) return;
    if (window.__fushiCssHighlightsSupported) CSS.highlights.delete('fushi-sentence-audio');
    var rubyElements = this.cueRubyElements.get(this.activeCueId) || [];
    rubyElements.forEach(function(ruby) { ruby.classList.remove('fushi-sentence-audio-ruby-active'); });
    var wrappers = this.cueWrappers.get(this.activeCueId) || [];
    wrappers.forEach(function(wrapper) { wrapper.classList.remove('fushi-sentence-audio-active'); });
    this.activeCueId = null;
  },
  resetSentenceAudioCues: function() {
    if (window.fushiSelection) window.fushiSelection.clearSelection();
    if (window.__fushiCssHighlightsSupported) CSS.highlights.delete('fushi-sentence-audio');
    this.cueRubyElements.forEach(function(rubyElements) {
      rubyElements.forEach(function(ruby) { ruby.classList.remove('fushi-sentence-audio-ruby-active'); });
    });
    this.cueRubyElements.clear();
    this.cueRangesMap.clear();
    var self = this;
    this.cueWrappers.forEach(function(wrappers) { self.unwrap(wrappers); });
    this.cueWrappers.clear();
    this.activeCueId = null;
  },
  unwrap: function(wrappers) {
    wrappers.forEach(function(wrapper) {
      var parent = wrapper.parentNode;
      if (!parent) return;
      while (wrapper.firstChild) {
        parent.insertBefore(wrapper.firstChild, wrapper);
      }
      parent.removeChild(wrapper);
      parent.normalize();
    });
  },
  scrollToSearchMatch: function(query, hintOffset) {
    if (!query) return null;
    var walker = this.createWalker();
    var node;
    var segments = [];
    while (node = walker.nextNode()) {
      segments.push({ node: node, text: node.textContent });
    }
    var fullText = segments.map(function(s) { return s.text; }).join('');
    var lowerQuery = query.toLowerCase();
    var lowerFull = fullText.toLowerCase();
    var matches = [];
    var searchFrom = 0;
    while (searchFrom <= lowerFull.length) {
      var idx = lowerFull.indexOf(lowerQuery, searchFrom);
      if (idx < 0) break;
      matches.push(idx);
      searchFrom = idx + 1;
    }
    if (!matches.length) return null;
    var bestIdx = matches[0];
    var bestDist = Math.abs(bestIdx - hintOffset);
    for (var m = 1; m < matches.length; m++) {
      var dist = Math.abs(matches[m] - hintOffset);
      if (dist < bestDist) { bestIdx = matches[m]; bestDist = dist; }
    }
    var targetStart = bestIdx;
    var targetEnd = targetStart + query.length;
    var charPos = 0;
    var startNode = null, startOffset = 0, endNode = null, endOffset = 0;
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i];
      var segEnd = charPos + seg.text.length;
      if (!startNode && targetStart < segEnd) {
        startNode = seg.node;
        startOffset = targetStart - charPos;
      }
      if (targetEnd <= segEnd) {
        endNode = seg.node;
        endOffset = targetEnd - charPos;
        break;
      }
      charPos = segEnd;
    }
    if (!startNode || !endNode) return null;
    var range = document.createRange();
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
    if (window.__fushiCssHighlightsSupported) {
      CSS.highlights.set('fushi-search', new Highlight(range));
    }
    if (this.scrollToRange) {
      this.scrollToRange(range);
    } else if (this.scrollToTarget) {
      // TODO-1308 问题②（BUG-696 根因②）：旧兜底 range.surroundContents(span) 在
      // rb/rtc 形态书（JIS mono-ruby，如 <ruby><rb>貫</rb>…<rb>禄</rb>…）上，命中词
      // 跨相邻 <rb> 基字时 Range 部分包含元素节点 → 抛 InvalidStateError → 滚动被
      // 跳过；跨章搜索经 _applyPendingPreciseLocate（catch 后只记日志）确定性停在
      // 章节开头。scrollToTarget → getRect 用 getClientRects()[0]，Range 原生支持
      // → 直接滚 Range，不做 DOM 手术（旧 span 无高亮 class 只当滚动靶，且
      // surroundContents 还会切开文本节点、永久残留 span、作废 nodeStartOffsets）。
      this.scrollToTarget(range);
    }
    return this.calculateProgress();
  },
  clearSearchHighlight: function() {
    if (window.__fushiCssHighlightsSupported) {
      CSS.highlights.delete('fushi-search');
    }
  },
''';

  // ── Shared init logic (viewport + SVG + images) ────────────────────

  /// BUG-1140 第二阶段①：恢复锚的三选一从「Dart 注入期挑一条语句」搬到运行时。
  ///
  /// 优先级与旧的 Dart 三元式逐条相同：`initialFragment` 非空 → `jumpToFragment`；
  /// 否则 `initialCharOffset >= 0` → `restoreToCharOffset`；否则 `restoreProgress`。
  /// 分页 shell 只用单点句首锚（旧实现也只传一个参数）。
  static const String _paginatedInitialRestoreJs = '''
    if (C.initialFragment !== null && C.initialFragment !== undefined) {
      window.fushiReader.jumpToFragment(C.initialFragment);
    } else if (C.initialCharOffset >= 0) {
      window.fushiReader.restoreToCharOffset(C.initialCharOffset);
    } else {
      window.fushiReader.restoreProgress(C.initialProgress);
    }''';

  /// 连续 shell 版：多一条 BUG-461 的句尾区间对齐分支（`initialCharOffsetEnd >
  /// initialCharOffset` 时透传句尾偏移），其余与 [_paginatedInitialRestoreJs] 相同。
  static const String _continuousInitialRestoreJs = '''
    if (C.initialFragment !== null && C.initialFragment !== undefined) {
      window.fushiReader.jumpToFragment(C.initialFragment);
    } else if (C.initialCharOffset >= 0) {
      if (C.initialCharOffsetEnd > C.initialCharOffset) {
        window.fushiReader.restoreToCharOffset(C.initialCharOffset, C.initialCharOffsetEnd);
      } else {
        window.fushiReader.restoreToCharOffset(C.initialCharOffset);
      }
    } else {
      window.fushiReader.restoreProgress(C.initialProgress);
    }''';

  /// 有声书 cue 下发：旧实现「有 cue 才注入这一行」，现在「有 cue 才调用」。
  static const String _sharedSentenceAudioInitJs = '''
    if (C.sentenceAudioCues !== null && C.sentenceAudioCues !== undefined) {
      window.fushiReader.applySentenceAudioCues(C.sentenceAudioCues);
    }''';

  /// 三种 shell 共用的视口 meta 重写（BUG-1688 第二处：VN shell 原先没跑这段）。
  ///
  /// 缺了它，WKWebView 会按**默认的 980 CSS px** 布局再整体缩放到设备宽——iOS 上实测
  /// `innerWidth=980 / innerHeight=1743`，而 Dart 侧下发的 `dartPageWidth=375`、
  /// `chromeTopInset=44` 全是逻辑像素，两个坐标系差 ~2.6 倍：正文被缩到约四成大小，
  /// 所有按 px 下发的量（chrome 预留、页面盒、caret inset、滑动阈值）也全被按错的
  /// 单位解释。Android 的 WebView 默认就是 device-width、桌面窗口又普遍 ≥980，所以
  /// 这个缺口**只在 iOS 上显形**。VN 必须与分页/连续 shell 用同一份，故此常量公开。
  static const String sharedInitViewportJs = _sharedInitViewport;

  static const String _sharedInitViewport = '''
  var viewport = document.querySelector('meta[name="viewport"]');
  if (viewport) { viewport.remove(); }
  var newViewport = document.createElement('meta');
  newViewport.name = 'viewport';
  newViewport.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
  document.head.appendChild(newViewport);
''';

  /// TODO-861④（移植 Hoshi `f286108`）：[blurImages] 为 true 时给标记为 block-img 的
  /// 大图（含 svg 封面）加 `blurred` 类（CSS 盖 24px 模糊），并装一次性点击监听揭开。
  /// 揭开（移除 `blurred`）连同「吞掉本次放大」由 webview.part.dart 的点击派发处统一
  /// 处理（见 `_fushiRevealBlurredImage`），这里只负责加类 + 标记可揭开。
  /// TODO-1339 测试钩子：暴露共享图片初始化脚本，让 live-WebView 集成测试能证明
  /// 图片合并注入的前导插图（`.fushi-merged-image`）保持 eager（不被挂 lazy），
  /// 从而 firstContentEdge 计入全部前导图、章首锚不跳过第一张。
  @visibleForTesting
  static String initImagesScriptForTesting() => _sharedInitImages();

  static String _sharedInitImages() {
    // TODO-1289：图片防剧透遮罩「点击揭开后又恢复」根因——揭开只删 DOM `blurred`
    // class，章节 (重)载 / 布局设置切换（writing mode / 分栏 / view mode / spread /
    // blur 开关，均经 _reloadWithCurrentSettings→_loadChapterDirectly）会重跑
    // initialize→_sharedInitImages，无条件给所有 block-img 重加 `blurred` → 揭开丢失。
    // 修复：把「本次阅读会话已揭开」的稳定 key（<img> src / <svg><image> href 相对
    // baseURI 解析成绝对 URL）注入成 map，_fushiBlurImage 命中则跳过重新遮罩。揭开
    // 状态的真相源是 Dart 侧 _revealedImageKeys（内存会话集），经 onImageRevealed
    // 回传持久，重载时再嵌入这里。domStorageEnabled=false 故不用 localStorage。
    // BUG-1140 第二阶段①：整块从「blurImages 为假时**整段不注入**」改成「函数照常
    // 定义、副作用照常受 C.blurImages 门控」。行为等价：`window.__fushiMarkImageRevealed`
    // / `window.__fushiImageRevealKey` 两个全局仍**只在开了防剧透遮罩时**才挂上
    // （caret / 有声书桥接都用 `if (window.__fushiImageRevealKey && …)` 探测），
    // `_fushiBlurImage` 也仍只在开关为真时被调用。
    const String blurFn = '''
  var _fushiRevealedKeys = Object.create(null);
  if (C.blurImages) {
    var __fushiKeys = C.revealedKeys;
    if (__fushiKeys && __fushiKeys.length) {
      for (var i = 0; i < __fushiKeys.length; i++) { _fushiRevealedKeys[__fushiKeys[i]] = true; }
    }
  }
  // TODO-1367：暴露给有声书桥接（audiobook_bridge）——音频跟随读过某张图时把它的稳定
  // reveal key 登记进本活集，日后该图（含尚未 load 的懒图）真正 load 走 _fushiBlurImage
  // 时命中 key 跳过遮罩，与点击 / 手柄揭开同一套「已揭开不再遮罩」真相源（会话内存活集）。
  if (C.blurImages) {
    window.__fushiMarkImageRevealed = function(key) {
      if (key) _fushiRevealedKeys[key] = true;
    };
  }
  // BUG-898：稳定 reveal key 归一到「extractDir 相对、decode、正斜杠」路径（如
  // OEBPS/images/foo.jpg），与图片库磁盘 File 的相对路径、Dart ImageRevealKey.normalize
  // 完全一致 —— 三端（阅读器 WebView / 图片库 / Drift 持久表）共享同一 key，才能双向同步。
  // 用 new URL(raw, baseURI) 折叠 ../ 并解析相对 src → 剥 fushi.local 的 /epub/ 前缀 +
  // decodeURIComponent → 相对路径。host 非本资源域（不该发生）时回退原始串。
  function _fushiImageRevealKey(element) {
    if (!element) return '';
    var raw = '';
    if (element.tagName === 'IMG') {
      raw = element.getAttribute('src') || element.src || '';
    } else if (element.querySelector) {
      var im = element.querySelector('image');
      if (im) raw = im.getAttribute('xlink:href') || im.getAttribute('href') || '';
    }
    if (!raw) return '';
    try {
      var u = new URL(raw, document.baseURI);
      if (u.host !== 'fushi.local') return raw;
      var path = decodeURIComponent(u.pathname);
      var pfx = '/epub/';
      var i = path.indexOf(pfx);
      if (i < 0) return raw;
      return path.substring(i + pfx.length);
    } catch (e) { return raw; }
  }
  if (C.blurImages) {
    window.__fushiImageRevealKey = _fushiImageRevealKey;
  }
  function _fushiBlurImage(element) {
    var key = _fushiImageRevealKey(element);
    if (key && _fushiRevealedKeys[key]) return;
    element.classList.add('blurred');
  }''';
    const String blurSvgCall = 'if (C.blurImages) _fushiBlurImage(svg);';
    const String blurImgCall = 'if (C.blurImages) _fushiBlurImage(img);';
    return '''
$blurFn
  Array.from(document.querySelectorAll('svg')).forEach(function(svg) {
    var svgImage = svg.querySelector('image');
    if (!svgImage) return;
    if (svg.getAttribute('preserveAspectRatio') === 'none') {
      svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    }
    if (svg.classList.contains('gaiji') || svg.classList.contains('gaiji-line')) return;
    // Fixed-layout EPUB covers/illustrations ship as <svg><image> instead of
    // <img>. Give large ones the same block treatment as <img> below (centre
    // via .block-img-wrapper + tap-to-zoom) so they don't fall through as
    // inline content that drifts to the page edge in vertical-rl reflow.
    var iw = parseFloat(svgImage.getAttribute('width')) || 0;
    var ih = parseFloat(svgImage.getAttribute('height')) || 0;
    if (iw <= 256 && ih <= 256) {
      var vb = (svg.getAttribute('viewBox') || '').split(/[ ,]+/);
      iw = parseFloat(vb[2]) || iw;
      ih = parseFloat(vb[3]) || ih;
    }
    if ((iw > 256 || ih > 256) && !svg.closest('.block-img-wrapper')) {
      svg.classList.add('block-img');
      var swrap = document.createElement('div');
      swrap.className = 'block-img-wrapper';
      svg.parentNode.insertBefore(swrap, svg);
      swrap.appendChild(svg);
      $blurSvgCall
    }
  });
  // TODO-1074（根因 A）：首屏可见性/restore 不再被「所有 <img> 都 decode 完」整页阻塞。
  // 旧实现给每个未完成的 <img> 挂 img.onload 才 resolve，Promise.all 揭开 restore 前要等
  // 最大图读盘+全分辨率解码 → 图片章首屏/换章卡（文字章几乎无 <img> 故快）。
  // 现在：
  //   · 每个 <img> 加 loading="lazy"（视口外不预取解码，不再拖住 window.load）+
  //     decoding="async"（解码离主线程，不阻塞首帧）。gaiji 内联小图除外——它们参与文字
  //     排版几何，必须 eager 同步，lazy 会让占位撑不开破坏 metrics。
  //   · 已 decode 完（complete && naturalWidth>0）的图仍同步分类 block-img 并即刻 resolve。
  //   · 未完成的图**立即 resolve**（不再 gate restore），block-img 归类推迟到它真正 onload
  //     时补做（懒图滚进视口才 load，普通图 decode 完），补做后失效 paginationMetrics 强制
  //     下次 paginate 用纳入真实图尺寸的几何重建（与 TODO-627 首帧那次失效同源）。
  // 竖排 SVG 封面（<svg><image>）走上面 querySelectorAll('svg') 的同步分支（尺寸取
  // 属性/viewBox，无需 onload），本改动不触及 → BUG-025 行为不变。
  function _fushiClassifyBlockImg(img) {
    var isGaiji = img.classList.contains('gaiji') || img.classList.contains('gaiji-line');
    if (isGaiji) return false;
    if (img.naturalWidth > 256 || img.naturalHeight > 256) {
      if (img.closest('.block-img-wrapper')) return false;
      img.classList.add('block-img');
      var wrapper = document.createElement('div');
      wrapper.className = 'block-img-wrapper';
      img.parentNode.insertBefore(wrapper, img);
      wrapper.appendChild(img);
      $blurImgCall
      return true;
    }
    return false;
  }
  // TODO-1349：纯图片章（正文无任何可匹配文本、仅由整页封面/插图构成）的所有 <img> 都是
  // 结构性内容。若挂 loading="lazy"，离屏图（分页远列 / 连续模式下方）永不进视口懒加载
  // margin → 永不 load → 保持 0 尺寸 → 被 buildPaginationMetrics 的 first/lastContentEdge
  // 排除 → 章末落点 maxScroll(contentLastPageScroll) 塌缩到章首 → 往前翻到本章停在封面（第
  // 一张图）而非最后一张图（用户报「从目录往前翻会去到封面」在分页模式的根因；连续模式另由
  // scrollToChapterEnd 覆盖，两墙互补）。与 gaiji / 合并前导插图同理保持 eager：无条件 load、
  // 真实撑开尺寸，metrics 计入全部图。readerRegex 单字符匹配（无 /g，test 无状态）在首个可匹配
  // 字符即短路 → 文本章几乎零开销、只对纯图片章全扫（文本极少）。图文混排章仍 lazy（不回退
  // TODO-1074 懒加载优化）；非图片章（有文本）完全 no-op（向后兼容）。
  var __fushiImageOnlyChapter =
      !window.fushiReader.readerRegex.test(document.body.textContent || '');
  Array.from(document.querySelectorAll('img')).forEach(function(img) {
    var isGaiji = img.classList.contains('gaiji') || img.classList.contains('gaiji-line');
    // TODO-1339：图片合并（前导插图折进后随文本章）注入的插图（`.fushi-merged-image`
    // 内，webview.part.dart _injectMergedChapterImages）是章首**结构性**内容——章首落点
    // (restoreProgress/restoreToCharOffset <=0 走 minScroll) 依赖 buildPaginationMetrics
    // 的 firstContentEdge，而 firstContentEdge 只计入**有非零尺寸**的媒体（0 尺寸被跳过）。
    // 若给这些前导插图挂 loading="lazy"，离屏（离首个文本落点较远的**第一张**）永不进入
    // 懒加载视口 margin → 永不 load → 保持 0 尺寸 → 被 firstContentEdge 排除 → 章首锚落到
    // 最近的已加载图（**最后一张**）跳过第一张 =「两张连续图只有最后一张合并进章节」。
    // 故与 gaiji 同理保持 eager：无条件 load、真实撑开尺寸，firstContentEdge 计入全部前导图，
    // 章首锚落到第一张。仅影响合并书的少量前导插图，不回退 TODO-1074 普通图懒加载。
    var isMergedLeadImg = img.closest && img.closest('.fushi-merged-image');
    // gaiji 内联小图参与文字几何：保持 eager 同步解码，不加 lazy。
    // TODO-1349：纯图片章的图同理 eager（见上 __fushiImageOnlyChapter 长注释）。
    if (!isGaiji && !isMergedLeadImg && !__fushiImageOnlyChapter) {
      img.setAttribute('loading', 'lazy');
    }
    img.setAttribute('decoding', 'async');
    if (img.complete && img.naturalWidth > 0) {
      _fushiClassifyBlockImg(img);
    } else {
      // 未完成：restore 不等它。真正 load 后补做 block-img 归类并失效 metrics。
      img.addEventListener('load', function() {
        if (_fushiClassifyBlockImg(img)) {
          var r = window.fushiReader;
          if (r && r.paginationMetrics !== undefined) r.paginationMetrics = null;
          // TODO-1229 案B / BUG-1140 第二轮：懒加载 block 图 load 后整章几何后移，冻结的
          // restore scrollTop 错位（Chromium 只在 scrollTop=0 自愈）。按本次恢复登记的
          // **语义锚**（char / progress / fragment）重算一次落点，终态与「图片本来就在」
          // 等价。属程序化滚动，不污染 TODO-798 userDriven 因果门；有用户输入
          // （paginate 已 clearImageLateAnchor）则不动。三种锚的分派见 reapplyImageLateAnchor。
          if (r && typeof r.reapplyImageLateAnchor === 'function') {
            r.reapplyImageLateAnchor();
          }
        }
      });
    }
  });
  // TODO-1074：restore/buildNodeOffsets 只等已完成的图（几乎瞬时），未完成图不 gate。
  var imagePromises = [];
''';
  }

  // BUG-1017: `initialize()` runs synchronously inside the outer reader-setup
  // IIFE (webview.part.dart), whose tail removes the `#fushi-cloak`
  // `body{visibility:hidden}` FOUC guard. A synchronous throw in initialize()
  // (e.g. on a fixed-layout SVG vertical cover page with zero text nodes)
  // aborted the IIFE before its tail, stranding the cloak -> the whole book
  // stayed `visibility:hidden` (permanent blank). The VN shell already guards
  // its boot for exactly this reason (reader_visual_novel_scripts.dart) but the
  // paginated / continuous shells used a bare call. Contain the throw here so
  // the IIFE always reaches its cloak removal (and later caret / furigana /
  // gesture setup still installs), and surface the real error on the console so
  // the underlying init failure can still be diagnosed and fixed.
  static const String _sharedInitBoot = '''
function _fushiBootInitialize() {
  try {
    window.fushiReader.initialize();
  } catch (e) {
    try { if (window.console && console.error) console.error('[FushiReader] boot initialize failed', e); } catch (_ignored) {}
  }
}
window.addEventListener('load', function() {
  _fushiBootInitialize();
});
if (document.readyState === 'complete') {
  _fushiBootInitialize();
}
''';

  // ── Paginated mode ─────────────────────────────────────────────────

  /// 分页 shell 的静态源码（零 per-nav 插值，全部参数改由运行时 `C` 读取）。
  static String paginatedShellSource() {
    // BUG-162: 优先精确字符偏移恢复（restoreToCharOffset），无精确锚（旧存档）才
    // 回退粗粒度 restoreProgress；书签/fragment 跳转仍走 jumpToFragment。
    // BUG-1140 第二阶段①：三选一从「Dart 注入期挑一条语句」改成「运行时按同一优先级
    // 读 C 分派」。判据逐条对齐旧实现（fragment 非空 > charOffset >= 0 > progress）。
    const String initialRestoreScript = _paginatedInitialRestoreJs;
    const String sentenceAudioInit = _sharedSentenceAudioInitJs;

    const int bottomOverlapPx = ReaderLayoutDefaults.bottomOverlapPx;
    const double imageWidthRatio = ReaderLayoutDefaults.imageWidthViewportRatio;
    const String spacerHeight = ReaderLayoutDefaults.trailingSpacerHeightCss;
    const String spacerWidth = ReaderLayoutDefaults.trailingSpacerWidthCss;

    final String initImages = _sharedInitImages();

    return '''<script>
window.__fushiShells.paginated = function(C) {
window.__fushiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);
window.fushiReader = {
  // 跨章分段计时总开关（Dart [ReaderChapterPerfTrace.enabled] → C.perfTraceEnabled）。
  // false = 生产路径，perfMark / perfSnapshot 零开销。
  _perfOn: C.perfTraceEnabled === true,
  pageHeight: 0,
  pageWidth: 0,
  // TODO-734：纯视口高 V（不含 bottomOverlap=O）。竖排列高几何唯一用它（见
  // getScrollContext），与 CSS --reader-viewport-height 成对。必须先声明 0，否则
  // 首帧读到 undefined→NaN→pageStep 退化成 1。initialize/updatePageSize 会赋为 V。
  viewportHeight: 0,
  paginationMetrics: null,
$_sharedJs
  revealElement: function(element) {
    var range = document.createRange();
    range.selectNodeContents(element);
    return this.scrollToRange(range);
  },
  getScrollContext: function() {
    // TODO-729：单一量纲（对齐安卓 reader-paginated.js getScrollContext）。
    // 列周期 = column-width + column-gap。CSS column-width 已等于 content-box
    // （reader_content_styles.dart 按书写轴分支扣 turn 轴 padding），单列正好填满
    // content-box，故真实列周期 == content-box + gap == pageStep。pageStep 是唯一的
    // 「整页步进 / 对齐 / maxScroll 减项」量纲，废除旧的「步进量与可视区减项」双量。
    // maxScroll = totalSize - pageStep（安卓 totalSize - pageSize 同形）：减项与对齐量
    // 同源，末页 floor 边界与真实最后一列严格对齐，杜绝「翻一半跳章」（旧实现减项用
    // 含 padding 的可视区，与对齐量差 padding-gap → 末页错位 ±gap）。
    var vertical = this.isVertical();
    var scrollEl = document.body;
    var cs = getComputedStyle(scrollEl);
    var contentBox;
    // TODO-753/792（横排 + 竖排亚像素 pageStep 统一）：列周期 = used column-width +
    // column-gap。直接取 getComputedStyle(scrollEl).columnWidth —— 浏览器对 CSS
    // column-width（横排 `calc(page-width − <ml>vw − <mr>vw)`、竖排
    // `max(F, calc(V − margins − F − chrome))`，两轴都解析成亚像素 used 列宽/列高）的
    // 单次解析结果，与 column-gap 一起就是真实列周期。令 JS 翻页网格步距 pageStep ==
    // 浏览器真实列周期，paginate 的 N×pageStep 绝对网格与真实列严格对齐，残差恒 0：
    //   · 横排（TODO-753 真机取证）：消除整数化 scrollEl.clientWidth（CSSOM client* 被
    //     规范取整成 1265，真实列宽 1265.33）泄漏的 δ≈0.33px/页。
    //   · 竖排（TODO-792/773）：消除「injectedV − 双 parseFloat(padding) 重建」与浏览器
    //     「单次 calc 解析 column-width」之间的亚像素失配 —— body padding 的 used 值按设备
    //     像素网格独立 snap，重建路径与 column-width 解析的取整粒度不同 → 每页同号 δ 经
    //     N×pageStep 网格累积 → 竖排文字越翻越向下偏。读 used columnWidth 让 contentBox
    //     按定义恒等于浏览器列周期分量（CSS 端 columnWidth==contentBox 由
    //     reader_vertical_pitch_invariant_test 代数证明，这里读权威的那个，消重建残差）。
    // 只有 columnWidth 解析失败（'auto'/空 → NaN）才按轴回退旧路径，绝不引入双量纲。
    var resolvedColumnWidth = parseFloat(cs.columnWidth);
    if (resolvedColumnWidth > 0) {
      contentBox = resolvedColumnWidth;
    } else if (vertical) {
      // 竖排兜底：注入纯视口高 V − 上下 padding（TODO-734 与 --reader-viewport-height 成对）。
      var pt = parseFloat(cs.paddingTop) || 0;
      var pb = parseFloat(cs.paddingBottom) || 0;
      contentBox = (this.viewportHeight || scrollEl.clientHeight || window.innerHeight) - pt - pb;
    } else {
      // 横排兜底：整数 clientWidth − 左右 padding（仅 columnWidth 不可用时）。
      var pl = parseFloat(cs.paddingLeft) || 0;
      var pr = parseFloat(cs.paddingRight) || 0;
      contentBox = (scrollEl.clientWidth || this.pageWidth || window.innerWidth) - pl - pr;
    }
    // TODO-743（P0 坍塌地板）：CSS column-width 在 cT+cB+F≥V 坍塌区夹了
    // max(Fpx, calc(...)) 地板（reader_content_styles.dart 的 verticalColumnWidthCss），这里
    // 必须用同一个字号地板，否则坍塌区 contentBox 仍归 1 → pageStep 与浏览器真实列
    // 周期失配复活「翻一半跳章」。fontSize 用 getComputedStyle(scrollEl).fontSize ——
    // 即 CSS `body { font-size: <settings.fontSize>px }` 应用到正文的同一运行时值，
    // 保证 CSS 地板 == JS 地板（不靠注入常量、不会漂）。
    var fontFloor = parseFloat(cs.fontSize) || 1;
    contentBox = Math.max(fontFloor, contentBox);
    var gap = parseFloat(cs.columnGap) || 0;
    // TODO-1285（每页列数根因修复）：一页含 N 列（CSS column-count），页步 =
    // N × 真实列周期(used column-width + gap)。N 从 getComputedStyle(body).columnCount
    // 直接读——与上面读 column-width/column-gap 同一权威真值源（CSS 由
    // reader_content_styles 按 pageColumns 成对发 column-count:N + 子列宽 column-width），
    // 无需注入 state、绝不与 CSS 失步。pageColumns=0（自动/无 column-count）→ columnCount
    // = 'auto' → parseInt → NaN → columns=1 → pageStep = contentBox + gap，与旧单列字节
    // 等价（零行为变化）。子列宽 contentBox 由浏览器亚像素解析，N×(contentBox+gap) 恒等
    // 整页 content-box + gap，翻页网格仍落真实列边界，无 TODO-753/792 亚像素漂移。
    // TODO-1285 健壮化根因修复（「相邻页/上下页内容全露出来」复诉）：pageStep 曾直接乘
    // parseInt(cs.columnCount)，若回读到有效数字才对；但 column-count 与 column-width 并存时，
    // 个别 WebView 会把 getComputedStyle(body).columnCount 回读成 'auto'（parseInt→NaN）。
    // 旧兜底 `if(!(columns>0)) columns=1` 此时把 columns 塌成 1 → pageStep = contentBox+gap
    // = **单列步长**，而 CSS 仍渲染 N 列 → 每次翻页只前进一列、视口内 N−1 列与上一页重叠
    // 露出（正是复诉的「上一页和下一页内容全露出来」）。根因：pageStep 不该脆弱依赖单个
    // columnCount 回读。columnCount 读不到有效数字时**绝不塌成 1**，改从真实几何反推 N——
    // 一页恒等于整 content-box（turn 轴），故 N = round((整 content-box + gap)/(used 子列宽 +
    // gap))，代数上 == 名义列数且不依赖 columnCount。整 content-box 从 turn 轴亚像素读：横排
    // getBoundingClientRect().width−左右 padding（分数精度，避开 TODO-753 的整数 clientWidth），
    // 竖排 this.viewportHeight−上下 padding（与上面竖排 contentBox 兜底同源）。columnCount 正常
    // 回读为数字时仍走原快路径、字节不变（Chromium/WebView2 实测回读 == N，零回归）；pageColumns=0
    // 单列(columnCount='auto')反推得 N=1、pageStep 退回 contentBox+gap，与旧单列字节等价。不改
    // contentBox（仍是 used columnWidth），TODO-753/792 亚像素列周期原样保留。
    var columns = parseInt(cs.columnCount, 10);
    if (!(columns > 0)) {
      var fullTurnBox = vertical
        ? ((this.viewportHeight || scrollEl.clientHeight || window.innerHeight)
            - (parseFloat(cs.paddingTop) || 0) - (parseFloat(cs.paddingBottom) || 0))
        : ((scrollEl.getBoundingClientRect().width || scrollEl.clientWidth
              || this.pageWidth || window.innerWidth)
            - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0));
      columns = Math.max(1, Math.round((fullTurnBox + gap) / (contentBox + gap)));
    }
    var pageStep = columns * (contentBox + gap);
    // TODO-792（竖排「文字向下偏移」根因修复·已下沉到 CSS）：曾一度在这里给竖排 pageStep += O
    // 补偿「列被 V+O 容器拉伸」造成的 realPitch>pageStep，但那只治页间累积、治不了页内逐列斜置
    // （斜置同源于列拉伸）。根因修法是让多列容器 body 高 == 纯 V（reader_content_styles.dart 的
    // `body{height:var(--reader-viewport-height)}`）→ 列不再拉伸、used 列高回 793、realPitch 回
    // 815 == 名义 pageStep。故这里**不再补偿**：contentBox+gap 已等于真实列周期，加 O 反会过冲。
    var totalSize = vertical ? scrollEl.scrollHeight : scrollEl.scrollWidth;
    var maxScroll = Math.max(0, totalSize - pageStep);
    // maxScroll 是分页网格的逻辑尾界（仍以唯一 pageStep 为减项）；浏览器实际能赋给
    // scrollTop/scrollLeft 的终点则由 scroll extent - client extent 决定。chrome inset
    // 会让 pageStep 小于 client extent，两者因此可相差半页。物理尾界不是第二套步长，
    // 只用于最后一张无法整页对齐的 terminal clamp。
    var viewportExtent = vertical ? scrollEl.clientHeight : scrollEl.clientWidth;
    var physicalMaxScroll = Math.max(0, totalSize - viewportExtent);
    // BUG-1764（有声书下一页第一句不翻页）/ BUG-875（竖排行尾单字凭空前翻）的共同根因：
    // 分页网格的**相位**。滚动坐标原点是 body 的 padding box 起始边，而列内容从 content box
    // 起始边开始 —— 两者恰差一个 turn 轴起始 padding。故列 j 的起始滚动坐标恒为
    // contentStart + j*pageStep，而不是 j*pageStep。判「某个 anchor 属于第几列」必须先减掉
    // contentStart 再除 pageStep（见 alignToPage）。turn 轴由 vertical 决定：竖排（vertical-rl
    // 的 inline 轴竖直、列向下堆叠、滚 scrollTop）取 paddingTop，横排取 paddingLeft，与
    // getPagePosition / 各落页锚的起始边取轴严格同源。
    var contentStart = vertical
      ? (parseFloat(cs.paddingTop) || 0)
      : (parseFloat(cs.paddingLeft) || 0);
    return {
      vertical: vertical,
      scrollEl: scrollEl,
      pageSize: pageStep,
      maxScroll: maxScroll,
      physicalMaxScroll: physicalMaxScroll,
      viewportExtent: viewportExtent,
      contentStart: contentStart
    };
  },
  getPagePosition: function(context) {
    return context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
  },
  lockRootViewport: function() {
    var root = document.documentElement;
    var didScroll = false;
    if (root.scrollTop !== 0) {
      root.scrollTop = 0;
      didScroll = true;
    }
    if (root.scrollLeft !== 0) {
      root.scrollLeft = 0;
      didScroll = true;
    }
    if (window.scrollX !== 0 || window.scrollY !== 0) {
      window.scrollTo(0, 0);
      didScroll = true;
    }
    return didScroll;
  },
  assignPagePosition: function(context, position) {
    if (context.vertical) {
      context.scrollEl.scrollTop = position;
    } else {
      context.scrollEl.scrollLeft = position;
    }
    this.lockRootViewport();
  },
  setPagePosition: function(context, position) {
    var clamped = Math.min(Math.max(0, position), context.physicalMaxScroll);
    window.lastPageScroll = clamped;
    this.assignPagePosition(context, clamped);
    return clamped;
  },
  registerSnapScroll: function(initialScroll) {
    if (window.snapScrollRegistered) return;
    window.snapScrollRegistered = true;
    window.lastPageScroll = initialScroll;
    this.lockRootViewport();
    window.addEventListener('scroll', () => {
      if (this.lockRootViewport()) {
        requestAnimationFrame(() => this.lockRootViewport());
      }
    }, { passive: true });
    document.body.addEventListener('scroll', () => {
      this.lockRootViewport();
      var context = this.getScrollContext();
      if (context.pageSize <= 0) return;
      var currentScroll = this.getPagePosition(context);
      var snappedScroll = Math.round(currentScroll / context.pageSize) * context.pageSize;
      snappedScroll = Math.min(Math.max(0, snappedScroll), context.physicalMaxScroll);
      if (Math.abs(currentScroll - snappedScroll) > 1) {
        this.assignPagePosition(context, window.lastPageScroll || 0);
      } else {
        window.lastPageScroll = snappedScroll;
      }
    }, { passive: true });
  },
  alignToPage: function(context, offset) {
    // 相位修正（BUG-1764/BUG-875 同源根因）：列 j 的起始滚动坐标 = contentStart + j*pageSize
    // （见 getScrollContext 的 contentStart），所以列号 = floor((anchor − contentStart)/pageSize)。
    // 裸 floor(anchor/pageSize) 相当于把网格整体平移了 contentStart：
    //   · contentStart > gap 时，每列末尾 (contentStart − gap) 那段内容被判进下一列 → 落页前翻
    //     一页（BUG-875 竖排行尾单字凭空翻页的真正来源）；
    //   · 反过来下一列开头那段被判成仍属本列 → 该翻不翻（BUG-1764）。
    // 减相位后 alignToPage 就是精确的列号函数，两个方向的错判同时消失，不需要任何可见性特例。
    // 返回值仍落在 j*pageSize 的滚动网格上（页对齐后内容起始边露出 contentStart 的页边距，
    // 与 paginate / pageStepPosition / minScroll 的网格严格同源，网格本身零变化）。
    var phase = context.contentStart || 0;
    return Math.floor(Math.max(0, offset - phase) / context.pageSize) * context.pageSize;
  },
  alignContentStartToPage: function(context, offset) {
    // TODO-1179：章首落点只能向下偏置到「包含首行内容边」的那一页。firstContentEdge
    // 恰落在页边界下方 <1px（k*pageStep-ε，sub-pixel）时旧 Math.round 会向上取整到页 k，
    // 但首行内容边实际在页 k-1 → minScroll 抬到页 k、手动前进跳章 progress=0 落第二页、
    // 整页首行被跳。内容起始边恒属于它所在页(floor)，floor 对边界上/下方 sub-pixel 都落
    // 「含首行」那页，绝不跳过首行（宁可多显示半列 padding）。与 scrollToCharOffset /
    // scrollToProgressPaged 的 floor(alignToPage) 落页锚同量纲；此函数只被 minScroll
    // 一处调用，无其它场景受影响。
    return this.alignToPage(context, offset);
  },
  pageStepPosition: function(currentScroll, pitch) {
    if (pitch <= 0) return currentScroll;
    var nearestPage = Math.round(currentScroll / pitch) * pitch;
    return Math.abs(currentScroll - nearestPage) <= 1 ? nearestPage : currentScroll;
  },
  scrollToRange: function(range) {
    var context = this.getScrollContext();
    if (context.pageSize <= 0) return false;
    var rect = this.getRect(range);
    var currentScroll = this.getPagePosition(context);
    // TODO-881：落页锚取起始边（竖排 rect.top、横排 rect.left），与
    // restoreToCharOffset / jumpToFragment / scrollToCharOffset 统一。
    // 旧实现用首段 rect 的几何中点（top/bottom 或 left/right 取中），句首落列后
    // 半段时中点越界相邻列 → floor 前翻，下一句又翻回 = 有声书自动读翻页抖动。
    // 起始边锚恒落「句子起点所在页」，不越界。轴向语义已被起始边路径锁定，不自创轴向。
    var startEdge = context.vertical ? rect.top : rect.left;
    var anchor = startEdge + currentScroll;
    var targetScroll = this.alignToPage(context, anchor);
    // BUG-1764（有声书跟随读到下一页第一句时不翻页）：这里曾有一条
    // `if (startEdge >= 0 && startEdge < context.viewportExtent) return false;` 的
    // 「已可见即不翻」短路，是 BUG-875（竖排行尾单字凭空前翻）的旧修法。它用 client 视口
    // extent 当可见判据，而 client 视口比一页真正的内容（contentBox）宽出 turn 轴两侧 padding：
    // 只要**结束边** padding > column-gap（横排 W>1100px 的宽屏、竖排字号>22 或底栏占位 /
    // 移动端系统 inset），下一页开头那段就落在 [pageStep, viewportExtent) 带内被判成「本页可见」
    // → 该翻不翻，要等到再下一句才翻，表现为「下一页第一句不自动翻页」。
    // 而 BUG-875 的行尾单字与本 bug 的下一页首句在 startEdge / targetScroll 上取值完全相同，
    // 单一阈值结构上区分不了两者 —— 说明判据维度本身就错了。真正的根因是 alignToPage 缺列
    // 网格相位（见那里的注释）：补上相位后，`targetScroll === currentScroll` 已经精确表达
    // 「句首就在本页」，两个方向的错判同时消失，这条特例短路不再需要，删除。
    if (targetScroll === currentScroll) return false;
    this.setPagePosition(context, targetScroll);
    var self = this;
    requestAnimationFrame(function() {
      self.setPagePosition(context, targetScroll);
    });
    return true;
  },
  contentLastPageScroll: function(context) {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    return metrics.maxScroll;
  },
  contentFirstPageScroll: function(context) {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    return metrics.minScroll;
  },
  warmPaginationMetrics: function() {
    if (this.paginationMetrics) return;
    var run = () => {
      if (this.paginationMetrics) return;
      this.buildPaginationMetrics();
    };
    if (window.requestIdleCallback) {
      window.requestIdleCallback(run, { timeout: 1000 });
    } else {
      setTimeout(run, 200);
    }
  },
  buildPaginationMetrics: function() {
    var context = this.getScrollContext();
    var currentScroll = this.getPagePosition(context);
    // TODO-1179：context.maxScroll = totalSize − pageStep，单一量纲下应恰为末列页的
    // 整页倍数；但竖排 vh/chrome-inset sub-pixel 使 totalSize 比 numCols*pageStep 少
    // 零点几 px → 裸 floor 把 P*pageStep−ε 砍成 (P−1)*pageStep，末列整页(含末行)不可达
    // → 手动后退跳章 progress=0.99 落 maxScroll 停在倒数第二页、末行被跳。加 1px 容差吸收
    // sub-pixel 下溢（要真多一页需近乎一整列真实尾随空间，容差绝不越界；下方 maxScroll 仍
    // 被 lastContentScroll 上限夹住不越过末内容页，setPagePosition 再 clamp 到
    // context.physicalMaxScroll，绝不 overscroll）。与 pageStepPosition / alignContentStartToPage
    // 的 1px sub-pixel 归一同口径。
    var maxAlignedScroll = Math.floor((context.maxScroll + 1) / context.pageSize) * context.pageSize;
    if (context.pageSize <= 0) {
      var emptyMetrics = { minScroll: 0, maxScroll: 0, totalChars: 0, progressStops: [] };
      this.paginationMetrics = emptyMetrics;
      return emptyMetrics;
    }
    var lastContentEdge = 0;
    var firstContentEdge = null;
    var progressStops = [];
    var exploredChars = 0;
    var totalChars = 0;
    var walker = this.createWalker();
    var node;
    while (node = walker.nextNode()) {
      var nodeLen = this.countChars(node.textContent);
      totalChars += nodeLen;
      if (nodeLen <= 0) continue;
      var range = document.createRange();
      range.selectNodeContents(node);
      var rects = range.getClientRects();
      var progressRect = this.getRect(range);
      var nodeStartEdge = progressRect && progressRect.width > 0 && progressRect.height > 0
        ? (context.vertical ? progressRect.top : progressRect.left) + currentScroll
        : null;
      for (var i = 0; i < rects.length; i++) {
        var rect = rects[i];
        if (rect.width <= 0 || rect.height <= 0) continue;
        var startEdge = (context.vertical ? rect.top : rect.left) + currentScroll;
        var endEdge = (context.vertical ? rect.bottom : rect.right) + currentScroll;
        firstContentEdge = firstContentEdge === null ? startEdge : Math.min(firstContentEdge, startEdge);
        lastContentEdge = Math.max(lastContentEdge, endEdge);
      }
      if (nodeStartEdge !== null) {
        progressStops.push({ scroll: nodeStartEdge, exploredChars: exploredChars + nodeLen });
      }
      exploredChars += nodeLen;
    }
    var media = document.querySelectorAll('img, svg, image, video, canvas');
    for (var j = 0; j < media.length; j++) {
      var mediaRect = media[j].getBoundingClientRect();
      if (mediaRect.width <= 0 || mediaRect.height <= 0) continue;
      var mediaStart = (context.vertical ? mediaRect.top : mediaRect.left) + currentScroll;
      var mediaEnd = (context.vertical ? mediaRect.bottom : mediaRect.right) + currentScroll;
      firstContentEdge = firstContentEdge === null ? mediaStart : Math.min(firstContentEdge, mediaStart);
      lastContentEdge = Math.max(lastContentEdge, mediaEnd);
    }
    var startAlignedScroll = firstContentEdge === null ? 0 : this.alignContentStartToPage(context, firstContentEdge);
    var lastContentScroll = lastContentEdge <= 0 ? 0 : Math.floor(Math.max(0, lastContentEdge - 1) / context.pageSize) * context.pageSize;
    var maxScroll = Math.min(maxAlignedScroll, lastContentScroll);
    // A chrome inset can make the real browser scroll endpoint fall between
    // two absolute page-grid lines. If content continues beyond the last
    // reachable aligned line, expose exactly that physical endpoint as one
    // partial terminal page. This keeps every intermediate turn on N*pitch,
    // makes the final turn finite, and never creates a blank page after the
    // actual last-content grid line. A <=1px physical shortfall retains the
    // aligned value so existing sub-pixel boundary normalization still works.
    if (maxScroll > context.physicalMaxScroll + 1) {
      maxScroll = context.physicalMaxScroll;
    }
    if (lastContentScroll > maxScroll + 1 &&
        context.physicalMaxScroll > maxScroll + 1) {
      maxScroll = Math.min(lastContentScroll, context.physicalMaxScroll);
    }
    var minScroll = Math.min(maxScroll, startAlignedScroll);
    progressStops.sort(function(a, b) { return a.scroll - b.scroll; });
    var metrics = {
      minScroll: minScroll,
      maxScroll: maxScroll,
      totalChars: totalChars,
      progressStops: progressStops
    };
    this.paginationMetrics = metrics;
    return metrics;
  },
  // 可选 atScroll：按任意页位置求进度（默认当前页）。getLastVisibleCharOffset 的降级
  // 路径传 `getPagePosition + pageSize`（下一页页首）得「下一页页首之前的累计字数」——
  // 节点粒度、随 scroll 单调，无需临时 setPagePosition 探测（那会触发 snap 监听 /
  // scroll 回传递归 / 闪屏）。
  calculateProgress: function(atScroll) {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    if (metrics.totalChars <= 0) return 0;
    return this.exploredCharsBeforeScroll(metrics, atScroll) / metrics.totalChars;
  },
  // progressStops 二分：起始边 <= scroll 的最后一个文本节点的累计字数（含该节点全部）。
  // atScroll 缺省取当前页位置。
  exploredCharsBeforeScroll: function(metrics, atScroll) {
    var scroll = atScroll === undefined
      ? this.getPagePosition(this.getScrollContext())
      : atScroll;
    var stops = metrics.progressStops;
    var low = 0;
    var high = stops.length - 1;
    var exploredChars = 0;
    while (low <= high) {
      var mid = Math.floor((low + high) / 2);
      if (stops[mid].scroll <= scroll) {
        exploredChars = stops[mid].exploredChars;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return exploredChars;
  },
  // BUG-1241：最后一页的 progress 是「视口首字符 / 全章字符」，只要末页还能显示多行，
  // 它就天然停在 0.99 左右，不能拿来判断用户是否真的到达章末。末页判定必须读分页
  // 几何的 terminal clamp；fushiProgressDetails 会在此为 true 时把持久进度钳到 100%。
  isAtEnd: function() {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    var context = this.getScrollContext();
    return this.getPagePosition(context) >= metrics.maxScroll - 1;
  },
  // 分页 caret 探点 → 章内学习单位偏移（与 getFirstVisibleCharOffset 同口径：
  // nodeStartOffsets 基址 + 节点内 isUnitEnd 累加）。返回 { offset, node, index }
  // （offset = caret 位置之前的单位数，node/index = caret 落点，供调用方判该字是否在页内），
  // caret 失败 / 落点无文本节点 / 基址缺失返 null——调用方各自决定降级路径。
  //
  // getFirstVisibleCharOffset 未改走本函数：它的函数体被 TODO-773 守卫
  // （paged_first_visible_scan_fallback_guard_test）钉成「三个失败出口各自回退
  // firstVisibleCharOffsetByScanPaged」+ BUG-2058 口径守卫（study_char_caliber_guard_test）
  // 要求其函数体内直接出现 fushiStudyUnits；两条守卫都要求逐出口内联，抽公共函数即红。
  _charOffsetAtPoint: function(x, y) {
    var range = document.caretRangeFromPoint(x, y);
    if (!range || !range.startContainer) return null;
    var target = range.startContainer;
    if (target.nodeType !== Node.TEXT_NODE) {
      var walker = this.createWalker(target);
      target = walker.nextNode();
      if (!target) return null;
    }
    var baseOffset = this.nodeStartOffsets.get(target);
    if (baseOffset === undefined) {
      this.buildNodeOffsets();
      baseOffset = this.nodeStartOffsets.get(target);
      if (baseOffset === undefined) return null;
    }
    var localChars = 0;
    var text = target.textContent;
    var limit = Math.min(range.startOffset, text.length);
    for (var i = 0; i < limit; i++) {
      var cp = text.codePointAt(i);
      if (window.fushiStudyUnits.isUnitEnd(text, i)) localChars++;
      if (cp > 0xFFFF) i++;
    }
    return { offset: baseOffset + localChars, node: target, index: limit };
  },
  // caret 落点处的那个字是否覆盖探点（沿行轴：横排 x 落在字的 [left,right]、竖排 y 落在
  // [top,bottom]）。caretRangeFromPoint 在探点落于字左半时返「该字之前」、落于右半 / 行尾
  // 空白时返「该字之后」；末字偏移只有前者需要 +1，后者 caret 之前的单位数已是半开区间 end。
  _caretCharCoversPoint: function(caret, x, y, vertical) {
    var text = caret.node.textContent;
    if (caret.index >= text.length) return false;
    var cp = text.codePointAt(caret.index);
    var range = document.createRange();
    range.setStart(caret.node, caret.index);
    range.setEnd(caret.node, caret.index + (cp > 0xFFFF ? 2 : 1));
    var rect = this.getRect(range);
    if (!rect || rect.width <= 0 || rect.height <= 0) return false;
    return vertical
      ? (rect.top <= y && rect.bottom >= y)
      : (rect.left <= x && rect.right >= x);
  },
  // 当前页可见字符区间的终点（半开 [start, end) 的 end，章内学习单位偏移）。统计口径
  // 「翻走即计 + 覆盖并集」需要每次进度采样同时拿到可见区间两端；起点是
  // getFirstVisibleCharOffset（页首角 caret），这里探页尾角：竖排（列自上而下堆叠、行自右
  // 向左）末字在左下 (paddingLeft+2, clientHeight−paddingBottom−2)，横排末字在右下
  // (clientWidth−paddingRight−2, clientHeight−paddingBottom−2)。探边量纲与
  // getFirstVisibleCharOffset 同为 body-relative（分页 body 填满视口左上角）。
  // 降级：caret 失败或算出 end <= start 时走 exploredCharsBeforeScroll(下一页页首)
  // （节点粒度、单调，见 calculateProgress 注释）；isAtEnd 时 end = 章总字数。
  // 不用 countCharsBeforeViewportPaged：它比较的轴（竖排 rect.left）与分页滚动轴（竖排 y）
  // 不一致，算不出页尾；不用临时 setPagePosition 探测再滚回（snap 监听 / scroll 回传递归 /
  // 闪屏）。startOffset 可选：调用方已算好 getFirstVisibleCharOffset 时传入免二次 caret。
  getLastVisibleCharOffset: function(startOffset) {
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    if (metrics.totalChars <= 0) return -1;
    if (this.isAtEnd()) return metrics.totalChars;
    var context = this.getScrollContext();
    var start = (typeof startOffset === 'number' && startOffset >= 0)
      ? startOffset
      : this.getFirstVisibleCharOffset();
    var cs = getComputedStyle(document.body);
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var pb = parseFloat(cs.paddingBottom) || 0;
    var x = context.vertical ? (pl + 2) : (document.body.clientWidth - pr - 2);
    var y = document.body.clientHeight - pb - 2;
    var end = -1;
    var caret = this._charOffsetAtPoint(x, y);
    if (caret) {
      end = caret.offset
        + (this._caretCharCoversPoint(caret, x, y, context.vertical) ? 1 : 0);
    }
    if (end <= start) {
      end = this.exploredCharsBeforeScroll(
        metrics, this.getPagePosition(context) + context.pageSize);
    }
    if (end > metrics.totalChars) end = metrics.totalChars;
    return end > start ? end : -1;
  },
  pageInfo: function() {
    // Page numbers only make sense once layout has settled. During a
    // pending re-anchor rAF (page-size / chrome-inset transition) getPagePosition
    // can read a transiently reset scrollTop (see setChromeInsets / HBK-REG-004),
    // which would mis-report page 1 — so bail and let the caller show no page.
    if (this._reanchorPending === true) return null;
    var context = this.getScrollContext();
    if (context.pageSize <= 0) return null;
    // Intermediate pages remain on the absolute pitch grid. The final page may
    // be a physical terminal clamp between grid lines when chrome insets make
    // the next full line unreachable, so count it as one additional page.
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    var span = Math.max(0, metrics.maxScroll - metrics.minScroll);
    var alignedTurns = Math.floor((span + 1) / context.pageSize);
    var alignedEnd = metrics.minScroll + alignedTurns * context.pageSize;
    var hasPartialTerminal = metrics.maxScroll - alignedEnd > 1;
    var totalPages = alignedTurns + 1 + (hasPartialTerminal ? 1 : 0);
    var currentScroll = this.getPagePosition(context);
    var page = hasPartialTerminal && currentScroll >= metrics.maxScroll - 1
      ? totalPages
      : Math.round((currentScroll - metrics.minScroll) / context.pageSize) + 1;
    if (page < 1) page = 1;
    if (page > totalPages) page = totalPages;
    return { currentPage: page, totalPages: totalPages };
  },
  // 恢复/跳锚共用的落点 settle：等一帧让恢复滚动引发的 reflow 落定，重设落点 + 注册
  // snap 基线，然后立刻通知 Dart 恢复完成。
  //
  // TODO-perf（跨章）：旧实现是两层嵌套 setTimeout(16)——第一层重设落点（有实义），
  // **第二层什么都不做**，只为再拖 16ms 才通知 Dart。真机分段计时（[chapter-perf]
  // js.restore 35~44ms vs 跨章总耗时 ~96ms）显示这两层固定延迟占了跨章耗时的三分之一。
  // 落点在第一层回调里已被 setPagePosition 同步写死，Dart 收到通知后读到的就是这个
  // 位置；再空等一帧不改变任何落点，只是让「内容就绪」晚 16ms、遮罩多留一帧。故删掉
  // 第二层，保留第一层的「等一帧再重设」防 reflow 语义。
  _settleAndNotify: function(context, pos) {
    var self = this;
    setTimeout(function() {
      self.setPagePosition(context, pos);
      self.registerSnapScroll(pos);
      self.notifyRestoreComplete();
    }, 16);
  },
  restoreProgress: async function(progress) {
    await document.fonts.ready;
    var context = this.getScrollContext();
    // TODO-1349（续）：往前翻到章末(>=0.99)先强制 load 仍 lazy 的尾图（打破「尾图离屏永不
    // load → maxScroll 塌缩 → 停章首 → 尾图永不进视口」鸡生蛋，见 forceLoadPendingImages）；
    // 图 load 后 __imgReanchorProgress 回调按含真实尾图几何的 maxScroll 重锚。
    if (progress >= 0.99) this.forceLoadPendingImages();
    this.scrollToProgressPaged(context, progress);
    // BUG-1140 第二轮：登记本次 progress 落点供懒图 load 后语义重锚，**含中段**。
    // 旧实现只登记章首(0)/章末(>=0.99)，理由是「中段重锚到粗 progress 反更差」——那成立
    // 的前提是恢复时几何已终态（initialize 挂在 window.load，图片必已 decode），中段重锚
    // 只会把已经正确的位置白抖一下。把 loading="lazy" 写进 HTML 源码之后这个前提没了：
    // 恢复跑在图片 decode 之前，中段落点同样会被随后 load 的图顶走。progressStops 是字符域，
    // 按同一 progress 重算 = 落回同一批字符所在页，严格优于停在漂掉的 scroll 上。
    // 任一用户翻页(paginate)清资格。
    this.registerImageLateAnchor({progress: progress});
    var pos = this.getPagePosition(context);
    this._settleAndNotify(context, pos);
  },
  // BUG-162: 退出再进的精确恢复——按 section 内绝对字符偏移落到该字符真实所在页
  // （成熟 scrollToCharOffset 路径，是「存→取」不动点），替代粗粒度
  // restoreProgress/scrollToProgressPaged（alignToPage 取整落相邻页）。charOffset<0
  // （旧存档无精确锚）回退章首；调用方在 initialCharOffset<0 时改走 restoreProgress。
  restoreToCharOffset: async function(charOffset) {
    await document.fonts.ready;
    var context = this.getScrollContext();
    // BUG-492 (TODO-1053 Bug A) 越界兜底：旧脏收藏 charAnchor 属于相邻错章，恢复加载
    // 本章后可能超本章字符总数 → scrollToCharOffset 静默 no-op 停在页 1 附近。越界回退
    // 章首（scrollToProgressPaged 0），比静默停错位可诊断。范围内走精确定位，行为不变。
    // TODO-1229 (BUG-594)：charOffset 0 == 章节绝对起点（0 字已读）。若本章以插图页开篇，
    // 首个文本字符位于插图之后的下一页，而 scrollToCharOffset 只走文本节点（createWalker）
    // 会落到「首个文本页」跳过插图页。章首语义必须与 restoreProgress(0) 一致——scrollToProgressPaged(0)
    // 走 minScroll，buildPaginationMetrics 的 firstContentEdge 已含前导 block 图，落点即插图页。
    // 故 <=0 一律走 minScroll，绝不越过章首插图（跨章 renav / _syncPageSize 宽变重导以 charOffset 0
    // 重锚时不再跳页）。>0 的精确锚行为不变。
    if (charOffset <= 0 || !this.charOffsetInRange(charOffset)) {
      this.scrollToProgressPaged(context, 0);
      this.registerImageLateAnchor({progress: 0});
    } else {
      this.scrollToCharOffset(charOffset);
      // BUG-1140 第二轮：字符锚是**布局无关**的真相，迟到图片 load 后按同一个 charOffset
      // 重算即回到「图片本来就在」的落点。旧实现在这里什么都不登记 → 精确锚恢复（退出重进 /
      // 收藏跳转 / 有声书 seek 落中段）在图文混排章完全裸奔，位置漂了还会被落库。
      this.registerImageLateAnchor({charOffset: charOffset});
    }
    var pos = this.getPagePosition(context);
    this._settleAndNotify(context, pos);
  },
  // fragment 落点的纯几何对齐（jumpToFragment 与迟到图片重锚共用同一份换算，避免
  // 重锚复制一份会漂开的算法）。命中返 true 并已 setPagePosition，未命中返 false。
  alignToFragmentTarget: function(fragment) {
    var context = this.getScrollContext();
    var rawFragment = (fragment || '').trim();
    var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
    if (context.pageSize <= 0 || !target) return false;
    var rect = this.getRect(target);
    var currentScroll = this.getPagePosition(context);
    var anchor = (context.vertical ? rect.top : rect.left) + currentScroll;
    this.setPagePosition(context, this.alignToPage(context, anchor));
    return true;
  },
  jumpToFragment: async function(fragment) {
    await document.fonts.ready;
    var context = this.getScrollContext();
    if (!this.alignToFragmentTarget(fragment)) {
      this.clearImageLateAnchor();
      this.registerSnapScroll(this.getPagePosition(context));
      this.notifyRestoreComplete();
      return false;
    }
    // BUG-1140 第二轮：目录/内链跳转同样在图片 decode 之前落点，登记 fragment 锚让迟到
    // 图片 load 后按同一个目标元素重新对齐。
    this.registerImageLateAnchor({fragment: fragment});
    this._settleAndNotify(context, this.getPagePosition(context));
    return true;
  },
  paginate: function(direction) {
    // TODO-1229 案B：用户翻页即放弃图片 late-load 重锚资格——避免把用户已翻走的位置
    // 拽回恢复锚（重锚只在恢复落地后、用户尚未翻页的窗口内有效）。
    this.clearImageLateAnchor();
    var context = this.getScrollContext();
    if (context.pageSize <= 0) return "limit";
    var currentScroll = this.getPagePosition(context);
    var metrics = this.paginationMetrics || this.buildPaginationMetrics();
    var minAlignedScroll = metrics.minScroll;
    var maxAlignedScroll = metrics.maxScroll;
    var pitch = context.pageSize;
    var stepScroll = this.pageStepPosition(currentScroll, pitch);
    var pageCoordinate = stepScroll / pitch;
    var nearestPage = Math.round(pageCoordinate);
    if (Math.abs(pageCoordinate - nearestPage) * pitch <= 1) {
      pageCoordinate = nearestPage;
    }
    // BUG-169：从可能未对齐的 currentScroll 出发先算「严格相邻整页边界」再 clamp，
    // 是否真翻页由 clamp 后的 target 与当前位置比较得出（共用同一 target，首/末页
    // 判定与步长计算一致）。pageCoordinate 延续 1px 页边界契约先规范化近整数商；
    // forward 取 floor(pageCoordinate)+1、backward 取 ceil(pageCoordinate)-1：
    // 对齐时与「当前页 ±1」等价、错位时永远只走一页，
    // 不会像旧 round((cur±pitch)/pitch) 那样把当前页算成相邻页跳 2 页。1px 内的
    // WebView sub-pixel 漂移先经 pageStepPosition 归一化到最近整页，避免连续 backward
    // 把 17955.33 → 17955 误判成 limit。与 Dart 影子 resolvePaginateStepForTesting
    // 同算法。
    //
    // TODO-729：单一量纲（pageStep == 真实列周期 == maxScroll 减项）后，metrics 的
    // max/minScroll 与对齐量同源、永不被低估，安卓式「翻不动即 return "limit" 跨章」
    // 是结构性正确的——不再需要旧的二次 settle 复核（那是双量纲下 maxScroll 低估的
    // 补救，根因消除后即多余）。安卓 reader-paginated.js paginate(814-840) 即直接
    // return "limit"。
    if (direction === "forward") {
      var targetForward = (Math.floor(pageCoordinate) + 1) * pitch;
      if (targetForward > maxAlignedScroll) targetForward = maxAlignedScroll;
      if (targetForward < minAlignedScroll) targetForward = minAlignedScroll;
      if (targetForward <= stepScroll + 1) return "limit";
      this.setPagePosition(context, targetForward);
      return "scrolled";
    } else {
      var targetBack = (Math.ceil(pageCoordinate) - 1) * pitch;
      if (targetBack < minAlignedScroll) targetBack = minAlignedScroll;
      if (targetBack > maxAlignedScroll) targetBack = maxAlignedScroll;
      if (targetBack >= stepScroll - 1) return "limit";
      this.setPagePosition(context, targetBack);
      return "scrolled";
    }
  },
  getFirstVisibleCharOffset: function() {
    var context = this.getScrollContext();
    var cs = getComputedStyle(document.body);
    var pt = parseFloat(cs.paddingTop) || 0;
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var x = context.vertical ? (document.body.clientWidth - pr - 2) : (pl + 2);
    var y = pt + 2;
    var range = document.caretRangeFromPoint(x, y);
    // TODO-773 P0：竖排切字号/字体/主题后页顶落 ruby/图片/折叠盒 → caretRangeFromPoint 返
    // null → 旧实现裸 return -1 → beginStyleReanchor 返 -1 → Dart 跳过 commit → CSS 已换但
    // scrollTop 停残值不滚回 → 文字漂移。改走 firstVisibleCharOffsetByScanPaged 全文累加兜底
    // （body-relative 首边，与分页 caret 探边同量纲；不裸抄连续版 window 量纲的
    // firstVisibleCharOffsetByScan）。连续版三失败点早有同形兜底。
    if (!range || !range.startContainer) return this.firstVisibleCharOffsetByScanPaged();
    var target = range.startContainer;
    if (target.nodeType !== Node.TEXT_NODE) {
      var walker = this.createWalker(target);
      target = walker.nextNode();
      if (!target) return this.firstVisibleCharOffsetByScanPaged();
    }
    var baseOffset = this.nodeStartOffsets.get(target);
    if (baseOffset === undefined) {
      this.buildNodeOffsets();
      baseOffset = this.nodeStartOffsets.get(target);
      if (baseOffset === undefined) return this.firstVisibleCharOffsetByScanPaged();
    }
    var localChars = 0;
    var text = target.textContent;
    var limit = Math.min(range.startOffset, text.length);
    for (var i = 0; i < limit; i++) {
      var cp = text.codePointAt(i);
      if (window.fushiStudyUnits.isUnitEnd(text, i)) localChars++;
      if (cp > 0xFFFF) i++;
    }
    return baseOffset + localChars;
  },
  scrollToCharOffset: function(charOffset, hintScroll) {
    // TODO-1229 (BUG-594 第 6 次复诉)：charOffset<=0 == 章首区（fvco 归 0：可能是「用户在前导
    // 插图页」也可能是「用户在首文本页、char0 正在本页顶」——两者语义不同，唯有 hint 能判开）。
    // 本函数只走文本节点（createWalker=SHOW_TEXT），下方 >0 逻辑对 charOffset 0 会算出**首个文本
    // 字符所在页**（前导插图之后）→ 重锚越过插图。旧的 ±1 page-stable hint 只在「前导内容恰占 1
    // 页」时兜住（charPage 与 origPage 差 1）；前导跨 ≥2 页（如扉页图+标题页、多张图）时差 ≥2、
    // ±1 失效 → 越过整段前导跳到首文本（headless 证 2 张前导图 jumped=2）。根治：<=0 时**保住用户
    // 当前页**（有 hint 走 origPage；无 hint 落 minScroll=章首含前导图），绝不按字符页跳——重锚本就
    // 该保位，char0 的文本页不是用户所在页。>0 精确锚 + ±1 hint 逻辑不变。裸落章首会把「在首文本
    // 页」的用户弹回插图页，故必须走 origPage（headless midChapter 守卫）。连续版无 hint，见那里
    // 的 <=0→scrollToChapterStart 归一。
    if (charOffset <= 0) {
      var ctx0 = this.getScrollContext();
      if (ctx0.pageSize > 0 && hintScroll !== undefined) {
        this.setPagePosition(
          ctx0, Math.round(hintScroll / ctx0.pageSize) * ctx0.pageSize);
      } else {
        this.setPagePosition(ctx0, this.contentFirstPageScroll(ctx0));
      }
      return;
    }
    var walker = this.createWalker();
    var node;
    var runningOffset = 0;
    var targetNode = null;
    var remaining = 0;
    while (node = walker.nextNode()) {
      var nodeChars = this.countChars(node.textContent);
      if (runningOffset + nodeChars > charOffset) {
        targetNode = node;
        remaining = charOffset - runningOffset;
        break;
      }
      runningOffset += nodeChars;
    }
    if (!targetNode) return;
    var charIdx = 0;
    var textOffset = 0;
    var text = targetNode.textContent;
    for (var i = 0; i < text.length && charIdx < remaining; i++) {
      var cp = text.codePointAt(i);
      if (window.fushiStudyUnits.isUnitEnd(text, i)) charIdx++;
      if (cp > 0xFFFF) i++;
      textOffset = i + 1;
    }
    var range = document.createRange();
    range.setStart(targetNode, Math.min(textOffset, text.length));
    range.collapse(true);
    var rect = range.getBoundingClientRect();
    var context = this.getScrollContext();
    var scrollOffset = context.vertical
      ? (context.scrollEl.scrollTop + rect.top)
      : (context.scrollEl.scrollLeft + rect.left);
    var charPage = Math.floor(Math.max(0, scrollOffset) / context.pageSize);
    var aligned;
    if (hintScroll !== undefined) {
      // Page-stable hint: if the target char is within one page of where we
      // started, keep the original page so a ±1-column repagination doesn't
      // visibly shift the reader; otherwise jump to the char's actual page.
      var origPage = Math.round(hintScroll / context.pageSize);
      if (Math.abs(charPage - origPage) <= 1) {
        aligned = origPage * context.pageSize;
        // BUG-2205：±1 保原页只该兜「页边界舍入抖动」（同一布局下锚字恰在页首、collapsed
        // range 被算到上一列末）。缩字号 / 减边距 / 减行高 / 挤压态藏底栏这类**让每页
        // 装更多字**的重排会把锚字真的推到前一页：仍保原页 = 新页首字越过锚字 = 用户
        // 丢掉锚字到新页首这段正文（缩一步丢一页），且随后的进度刷新把这段当「新读到」
        // 计进统计（分页 progress 按节点粒度、水位只升不降 → 单向棘轮，反复缩放每次多计
        // 一页）。判据不用像素容差（横排末行 collapsed range 的 x 可落在整列任意处），
        // 而是落页后**实测页首字**：原页页首字 > 锚字即锚已丢，改落锚字所在页。
        // 放大字号（charPage > origPage）保原页只会让页首字 ≤ 锚字（多看到已读的几行），
        // 不丢正文、不推进度，维持原行为。
        if (charPage < origPage) {
          this.setPagePosition(context, aligned);
          var firstOnOrig = this.getFirstVisibleCharOffset();
          if (firstOnOrig > charOffset) aligned = charPage * context.pageSize;
        }
      } else {
        aligned = charPage * context.pageSize;
      }
    } else {
      aligned = charPage * context.pageSize;
    }
    this.setPagePosition(context, aligned);
  },
  setChromeInsets: function(topPx, bottomPx) {
    // Re-anchoring (after a chrome-inset OR a page-size change) is serialised
    // through one shared in-flight flag, _reanchorPending. A layout change
    // transiently resets scrollTop to 0; if a re-anchor rAF is already pending
    // (from this handler or updatePageSize), reading a fresh char offset now
    // would sample that reset as the chapter start and snap there. So when one
    // is in flight we only apply the new CSS and let the pending rAF restore
    // position once the layout settles. This serialises without masking via a
    // delay, and covers both rapid toggles and toggle/resize interleaving.
    // (HBK-REG-004)
    var inFlight = this._reanchorPending === true;
    var charOffset = inFlight ? -1 : this.getFirstVisibleCharOffset();
    var scrollBefore = inFlight ? 0 : this.getPagePosition(this.getScrollContext());
    document.documentElement.style.setProperty('--chrome-top-inset', topPx + 'px');
    document.documentElement.style.setProperty('--chrome-bottom-inset', bottomPx + 'px');
    // Chrome insets participate in the paginated column-width/pageStep CSS.
    // Cached min/max bounds were built against the previous pitch; retaining
    // them can stop pagination before the final columns after the bottom bar
    // changes. Invalidate even when a re-anchor is already in flight.
    this.paginationMetrics = null;
    if (inFlight || charOffset < 0) return;
    this._setReanchorPending(true);
    var self = this;
    requestAnimationFrame(function() {
      try {
        self.scrollToCharOffset(charOffset, scrollBefore);
      } finally {
        self._setReanchorPending(false);
      }
    });
  },
  // TODO-736 B-1 续（分页缺席根因修复，BUG-849）：样式变更两阶段重锚在分页 shell 曾整体
  // 缺席，导致 beginStyleReanchorInvocation 恒走 `:-1` 兜底、CSS 从不换 → 分页模式下改
  // 字号/边距/主题等纯 CSS 设置不实时生效、必须重开书。补齐与连续 shell 同语义的三方法，
  // 用分页原生 hint 原语：reflow 前记 getPagePosition(getScrollContext())（分页 ±1 列保持
  // 原页，与 setChromeInsets 的成熟重锚同源），配分页 2 参 scrollToCharOffset(off, hint)。
  // 连续 shell 的对应版本另用 _readContinuousScroll（内容轴 raw scroll），各自 this 解析。
  _resetImageMaxVars: function() {
    var box = this._imageMaxBox();
    document.documentElement.style.setProperty('--fushi-image-max-width', box.w + 'px');
    document.documentElement.style.setProperty('--fushi-image-max-height', box.h + 'px');
  },
  beginStyleReanchor: function(styleEl, css) {
    if (!this.didInitialize) { if (styleEl) styleEl.textContent = css; return -1; }
    if (this._reanchorPending === true) {
      if (styleEl) styleEl.textContent = css;
      this._resetImageMaxVars();
      return -1;
    }
    var charOffset = this.getFirstVisibleCharOffset();
    // reflow 前记页内位置作 hint：分页 ±1 列时 scrollToCharOffset 保持原页
    // （getPagePosition 是分页专属；连续 shell 版改用内容轴 scroll）。
    var hint = this.getPagePosition(this.getScrollContext());
    if (styleEl) styleEl.textContent = css;
    if (this.paginationMetrics !== undefined) this.paginationMetrics = null;
    this._resetImageMaxVars();
    if (charOffset < 0) return -1;
    this._setReanchorPending(true);
    this._styleReanchorOffset = charOffset;
    this._styleReanchorHint = hint;
    return charOffset;
  },
  commitStyleReanchor: function() {
    var off = this._styleReanchorOffset;
    if (off === undefined || off < 0) return false;
    var hint = this._styleReanchorHint;
    try {
      this.scrollToCharOffset(off, hint);
    } finally {
      this._styleReanchorOffset = undefined;
      this._styleReanchorHint = undefined;
      this._setReanchorPending(false);
    }
    return true;
  }
};
window.fushiReader.initialize = function() {
  if (window.fushiReader.didInitialize) return;
  window.fushiReader.didInitialize = true;
  this.perfMark('initStart');
  document.documentElement.style.setProperty('--chrome-top-inset', C.chromeTopInset + 'px');
  document.documentElement.style.setProperty('--chrome-bottom-inset', C.chromeBottomInset + 'px');
$_sharedInitViewport
  // TODO-736 B-1：存图片宽比值供 _resetImageMaxVars 读（_sharedJs 不插值，见那里注释）。
  this._imageWidthRatio = $imageWidthRatio;
  var dartW = C.dartPageWidth;
  var dartH = C.dartPageHeight;
  var pageWidth = dartW || window.innerWidth;
  // TODO-734：viewportHeight = 纯视口高 V（不加 bottomOverlap）。pageHeight = V + O
  // 仍供图片虚高/scrollHeight 用。竖排列高几何（CSS column-width + JS contentBox）
  // 成对只用 V，杜绝列底边漏出 (O−F) 进底栏。
  var viewportHeight = dartH || window.innerHeight;
  var pageHeight = viewportHeight + $bottomOverlapPx;
  window.__fushiApplyReaderMargins(pageWidth, viewportHeight);
  console.log('[FushiInit] dartW=' + dartW + ' dartH=' + dartH
    + ' innerW=' + window.innerWidth + ' innerH=' + window.innerHeight
    + ' usedW=' + pageWidth + ' usedH=' + pageHeight + ' viewportH=' + viewportHeight);
  document.documentElement.style.setProperty('--page-height', pageHeight + 'px');
  document.documentElement.style.setProperty('--reader-viewport-height', viewportHeight + 'px');
  document.documentElement.style.setProperty('--page-width', pageWidth + 'px');
  var __imgBox = this._imageMaxBox();
  document.documentElement.style.setProperty('--fushi-image-max-width', __imgBox.w + 'px');
  document.documentElement.style.setProperty('--fushi-image-max-height', __imgBox.h + 'px');
  window.fushiReader.pageHeight = pageHeight;
  window.fushiReader.viewportHeight = viewportHeight;
  window.fushiReader.pageWidth = pageWidth;
$initImages
  var spacer = document.createElement('div');
  spacer.style.height = '$spacerHeight';
  spacer.style.width = '$spacerWidth';
  spacer.style.display = 'block';
  spacer.style.breakInside = 'avoid';
  document.body.appendChild(spacer);
  this.perfMark('initSyncDone');
  Promise.all(imagePromises).then(function() {
    window.fushiReader.perfMark('imagesReady');
    window.fushiReader.buildNodeOffsets();
    window.fushiReader.perfMark('offsetsBuilt');
    // TODO-627：图片可能在初次分页 metrics 建好之后才 decode 完。此前
    // buildPaginationMetrics 枚举到的 <img> 还是 0x0（getBoundingClientRect 全 0），
    // metrics.maxScroll 漏掉图片所占的列 → 偏小 → paginate 在图片页前就误判到末页
    // → _handlePageTurnLimit 跳过插画页跨章。图片 decode 完成后必须失效缓存的
    // paginationMetrics，强制下次 paginate 用纳入图片真实尺寸的几何重建（与
    // updatePageSize / reanchorAfterStyleChange 的 metrics 失效一致）。
    if (window.fushiReader.paginationMetrics !== undefined) {
      window.fushiReader.paginationMetrics = null;
    }
    $sentenceAudioInit
    $initialRestoreScript
  });
};
window.fushiReader.updatePageSize = function(cssWidth, cssHeight) {
  // TODO-734：newViewportHeight = 纯 V（Math.round(cssHeight)），newHeight = V + O。
  var newViewportHeight = Math.round(cssHeight);
  var newHeight = newViewportHeight + $bottomOverlapPx;
  var newWidth = Math.round(cssWidth);
  if (newHeight === this.pageHeight && newWidth === this.pageWidth) return;
  // Shares the _reanchorPending flag with setChromeInsets (see there). If a
  // re-anchor rAF is already pending, reading calculateProgress now would read a
  // transiently reset scrollTop as progress 0 and snap to the chapter start, so
  // we only update the page metrics and let the pending rAF restore position.
  var inFlight = this._reanchorPending === true;
  var progress = inFlight ? 0 : this.calculateProgress();
  document.documentElement.style.setProperty('--page-height', newHeight + 'px');
  document.documentElement.style.setProperty('--reader-viewport-height', newViewportHeight + 'px');
  document.documentElement.style.setProperty('--page-width', newWidth + 'px');
  window.__fushiApplyReaderMargins(newWidth, newViewportHeight);
  var __imgBox = this._imageMaxBox();
  document.documentElement.style.setProperty('--fushi-image-max-width', __imgBox.w + 'px');
  document.documentElement.style.setProperty('--fushi-image-max-height', __imgBox.h + 'px');
  this.pageHeight = newHeight;
  this.viewportHeight = newViewportHeight;
  this.pageWidth = newWidth;
  this.paginationMetrics = null;
  if (inFlight) return;
  this._setReanchorPending(true);
  var self = this;
  requestAnimationFrame(function() {
    try {
      self.scrollToProgressPaged(self.getScrollContext(), progress);
    } finally {
      self._setReanchorPending(false);
    }
  });
};
$_sharedInitBoot
};
</script>''';
  }

  // ── Continuous mode ────────────────────────────────────────────────

  /// 连续 shell 的静态源码（零 per-nav 插值，全部参数改由运行时 `C` 读取）。
  static String continuousShellSource() {
    // BUG-162: 同分页——优先精确字符偏移恢复，旧存档回退分数。BUG-461：收藏句跳转带句尾
    // 偏移（initialCharOffsetEnd>句首）时透传给 restoreToCharOffset 做整句区间对齐。
    // BUG-1140 第二阶段①：判据整体搬到运行时，逐条对齐旧的 Dart 三元式。
    const String initialRestoreScript = _continuousInitialRestoreJs;
    const String sentenceAudioInit = _sharedSentenceAudioInitJs;

    const double imageWidthRatio = ReaderLayoutDefaults.imageWidthViewportRatio;

    final String initImages = _sharedInitImages();

    return '''<script>
window.__fushiShells.continuous = function(C) {
window.__fushiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);
window.fushiReader = {
  // 跨章分段计时总开关（Dart [ReaderChapterPerfTrace.enabled] → C.perfTraceEnabled）。
  // false = 生产路径，perfMark / perfSnapshot 零开销。
  _perfOn: C.perfTraceEnabled === true,
  // TODO-734：连续模式不用竖排分页几何（无 column），故 initialize/updatePageSize
  // 不注入 --reader-viewport-height、getScrollContext 也不引用它。但属性仍声明 0
  // （补点2 防 stale）：两个 fushiReader 实例属性表保持对齐，避免误读 undefined。
  viewportHeight: 0,
  // BUG-2013：竖排连续模式是**横向**滚动，桌面 WebView2 的水平滚动条是占位式的
  // （移动端是不占位的 overlay，所以这条只在桌面复现），它从视口底部吃掉约 15px。
  // window.innerHeight 与 Dart 传来的 MediaQuery 高度（dartPageHeight /
  // updatePageSize 的 cssHeight）都是**视口外框**高度、不扣这条；而 body 是
  // box-sizing: border-box + height: var(--fushi-continuous-height)
  // （见 reader_content_styles.dart 的 _continuousLayoutCss 竖排分支），于是 body
  // 最底部那 15px 落在滚动条之下，末行文字被裁掉大半——用户截图里每列底部的字
  // 只剩上半个，正是这个。documentElement.clientHeight 是唯一扣掉滚动条的
  // **可视内容**高度。
  //
  // 实测（Chromium 1200x800 + 竖排长文）：innerHeight=705 / clientHeight=690 /
  // 水平滚动条 15px。喂 705 → 文字底 705 > 可视 690（溢出）；改喂 690 → 文字底
  // 690（不溢出）；再量一轮仍 690（不震荡）；内容短到没有滚动条时 clientHeight
  // 回到 705（不误缩）。
  //
  // 不震荡的原因：竖排水平滚动条的有无只由内容宽度（列数）决定，与 body 高度无
  // 关；高度调小只让每列变短、列数变多，滚动条照样在，clientHeight 保持稳定。
  //
  // 刻意**不**改 __fushiApplyReaderMargins / _contH 的入参：那两个要的就是视口外
  // 框高度。本 bug 的根因正是「视口外框高度」和「可视内容高度」被当成同一个数，
  // 修法是把这两个概念分开，而不是把另一处也一起改掉。
  //
  // 夹在 fallback（视口外框高度）以内：可视内容高度按定义不可能超过外框高度。这
  // 不是「保险起见」的兜底，而是这个量的**定义域**——一旦超出就说明读到的不是本
  // 次布局的值：
  //   · iOS：连续 shell 的 initialize 里，共用的 viewport meta 重写（见
  //     sharedInitViewportJs）刚删掉并重建 meta[name=viewport]，隔 5 条语句就读
  //     clientHeight。BUG-1688 实测 WKWebView 在这次重写生效前按
  //     默认 980 CSS px 布局（innerHeight=1743，而 Dart 权威值 667）。若 WebKit 的
  //     重排不是同任务同步生效，这里会量到 1743 → 竖排 body 高度爆到 2.6 倍。而
  //     iOS 是**不占位**的 overlay 滚动条，本修复在 iOS 上收益为零——不能让一个
  //     零收益的平台替桌面的修复背回归。
  //   · quirks mode：章节文档是**书自己给的** XHTML，Fushi 只做净化并注入 style、
  //     全程不补 doctype（webview.part.dart:345 _buildSanitizedChapterHtmlBytes），
  //     而下发的 Content-Type 恒为 text/html（同文件:206-210）⇒ 走 HTML5 解析、
  //     由 doctype 定模式。书没写 doctype 就落 quirks，clientHeight 退化成 html
  //     自身 padding box 高度，不再是视口量。
  // 桌面竖排的正常值 690 <= 705，夹子不改变本 bug 的修复效果。
  _visibleViewportHeight: function(fallback) {
    var visible = document.documentElement.clientHeight;
    return (visible && visible > 0 && visible <= fallback) ? visible : fallback;
  },
  // `--fushi-continuous-height` 的**唯一**写入点（守卫钉死：全 shell 只此一处
  // setProperty 该变量）。调用方三个：initialize / updatePageSize / beginStyleReanchor。
  //
  // 为什么 beginStyleReanchor 也必须写：BUG-2013 之前这个变量只由**视口外框高度**
  // 决定，而外框高度只在 resize 时变，所以两处赋值就够。改取**可视高度**后它变成
  // 内容相关量——水平滚动条的有无由内容宽度（列数）决定，而改字号正是改列数。于是
  // 「首屏内容短 → 无滚动条 → 写 705」的书，用户放大字号后滚动条出现、变量仍是
  // 705，末行照旧被裁，要等下一次 resize 才自愈。写入点必须跟上这个**新出现的**
  // 失效源，否则修复恰好在最常见的「改字号」路径上漏掉。
  _applyContinuousHeight: function(fallback) {
    document.documentElement.style.setProperty(
        '--fushi-continuous-height', this._visibleViewportHeight(fallback) + 'px');
  },
$_sharedJs
  scrollToChapterStart: function() {
    var root = document.scrollingElement || document.documentElement;
    window.scrollTo(0, 0);
    root.scrollTop = 0;
    root.scrollLeft = 0;
    document.documentElement.scrollTop = 0;
    document.documentElement.scrollLeft = 0;
    document.body.scrollTop = 0;
    document.body.scrollLeft = 0;
  },
  // TODO-1349：连续模式「章末」落点——把正文最后一个可见内容元素对齐到滚动轴末端。
  // 往前翻上一章走 restoreProgress(0.99)（章尾语义，与分页 contentLastPageScroll=maxScroll
  // 对称）。但 scrollToProgressContinuous 只走文本节点（findNodeAtProgress）：纯图片/封面章
  // 无文本节点 → 返 null → 不滚动 → 停在章首（=封面图），而非封面章节的最后部分（用户报
  // 「从目录往前翻会去到封面」的根因）。这里用最后一个可见内容元素 scrollIntoView(block:'end')：
  // block/inline 轴由 writing-mode 自动映射（横排 block=竖直落到内容底；竖排 vertical-rl
  // block=横向 RTL 落到最左列 = 章末），故横排/竖排统一，且天然含尾部插图。无可见内容元素时
  // 兜底滚到滚动轴物理末端（横排底、竖排 rl 最左）。
  scrollToChapterEnd: function() {
    var body = document.body;
    var last = body.lastElementChild;
    while (last) {
      var tag = last.tagName;
      var rect = last.getBoundingClientRect();
      var visible = rect.width > 0 || rect.height > 0;
      if (tag !== 'SCRIPT' && tag !== 'STYLE' && tag !== 'TEMPLATE' && visible) {
        break;
      }
      last = last.previousElementSibling;
    }
    if (last) {
      last.scrollIntoView({block: 'end', inline: 'nearest', behavior: 'instant'});
    } else {
      this._writeContinuousScroll(this.isVertical() ? -1e9 : 1e9);
    }
  },
  // TODO-1229 (BUG-594 第 6 次复诉·续)：连续模式重锚保位读/写。连续无分页的
  // getScrollContext/getPagePosition（那是分页专属），滚动位就是内容轴 raw scroll：横排
  // 走 scrollTop、竖排走 window.scrollX（与 paginate 的轴判据同源）。重锚在 charOffset<=0
  // （章首区，fvco 二义）时用它保住用户当前滚动位，不弹回章顶前导。
  _readContinuousScroll: function() {
    var root = document.scrollingElement || document.documentElement;
    return this.isVertical() ? window.scrollX : root.scrollTop;
  },
  _writeContinuousScroll: function(pos) {
    if (this.isVertical()) {
      window.scrollTo(pos, 0);
    } else {
      var root = document.scrollingElement || document.documentElement;
      root.scrollTop = pos;
      document.documentElement.scrollTop = pos;
      document.body.scrollTop = pos;
    }
  },
  // TODO-825：连续模式有声书逐句高亮跟随滚动用 behavior:'smooth' 平滑动画（用户要求恢复
  // 动画，禁止砍成 instant——见已撤的 TODO-803）。「滚动结束闪一下屏幕」的根因不是 smooth
  // 动画本身，而是这条**程序化跟随滚动没武装 settle 保护窗**：cue reveal 经 Dart
  // AudiobookBridge.highlight(reveal:true) 触发本函数，但当年只有 恢复/缩放/换样式 三条
  // reanchor commit 武装了 B-3 250ms settle 窗（eaa151581）→ smooth 动画落定那帧 scroll 回弹
  // 回 Dart 触发 _refreshProgress setState 重绘 + 可能命中 TODO-798 非自愿归零判据被反手二次
  // 滚动 = 闪屏。TODO-825 的根因修是在 Dart 跟随滚动调用点（audiobook.part.dart _onCueChanged
  // reveal 分支）武装 _reanchorClearedAt 让 B-3 窗覆盖这条平滑滚动的落定尾沿，从源头消除二次
  // 反弹——动画保留，闪烁靠 settle 窗治住。分页模式 reveal（scrollToRange）走另一路不受影响。
  scrollToTarget: function(target) {
    var rect = this.getRect(target);
    var margin = 0.15;
    var wm = window.getComputedStyle(document.body).writingMode;
    // 墨水屏模式（--fushi-reader-eink-mode: 1，由 ReaderContentStyles 的 eink 覆盖块
    // 注入）：跟随滚动退化为瞬时跳——慢刷新屏上 smooth 补间是一整段残影。普通模式
    // 保持 TODO-825 的 smooth（用户点名要动画，settle 窗治闪屏），零行为变化。
    var behavior = (window.getComputedStyle(document.documentElement)
      .getPropertyValue('--fushi-reader-eink-mode').trim() === '1') ? 'auto' : 'smooth';
    if (wm.startsWith('vertical')) {
      var vw = window.innerWidth;
      var safe = vw * margin;
      if (rect.left >= safe && rect.right <= vw - safe) return false;
      if (wm === 'vertical-rl') {
        window.scrollBy({left: rect.right - (vw - safe), behavior: behavior});
      } else {
        window.scrollBy({left: rect.left - safe, behavior: behavior});
      }
    } else {
      var vh = window.innerHeight;
      var safe = vh * margin;
      if (rect.top >= safe && rect.bottom <= vh - safe) return false;
      window.scrollBy({top: rect.top - safe, behavior: behavior});
    }
    return true;
  },
  revealElement: function(element) {
    return this.scrollToTarget(element);
  },
  calculateProgress: function() {
    // TODO-736 A-1：字符级进度（对齐安卓 reader-continuous.js calculateProgress:529-541）。
    // 分子改用 countCharsBeforeViewport 逐节点累加「已滚出视口首边的可匹配字符数」，
    // 替代旧的「整节点 in/out」段落级粗粒度——后者把跨视口的长节点整块算未读，长节点滚
    // 动期进度按整节点跳变、滚一大段都不动（滚动模式「进度像没保存」的根因之一）。分母
    // 仍是 countChars 总可匹配字符；createWalker 排除 rt/rp，分子分母同套。
    var vertical = this.isVertical();
    var walker = this.createWalker();
    var totalChars = 0;
    var exploredChars = 0;
    var node;
    while (node = walker.nextNode()) {
      var nodeLen = this.countChars(node.textContent);
      totalChars += nodeLen;
      if (nodeLen > 0) {
        exploredChars += this.countCharsBeforeViewport(node, vertical);
      }
    }
    return totalChars > 0 ? exploredChars / totalChars : 0;
  },
  // BUG-1241：连续模式同样以视口首字符算 progress，物理滚到底时分数仍可能小于 1。
  // 横排读 scrollTop；竖排 WebView 在 vertical-rl 下 scrollX 为负，因此用绝对位移
  // 与物理最大滚动量比较。
  isAtEnd: function() {
    var root = document.scrollingElement || document.documentElement;
    if (this.isVertical()) {
      var maxX = Math.max(0, root.scrollWidth - root.clientWidth);
      return Math.abs(window.scrollX || root.scrollLeft || 0) >= maxX - 1;
    }
    var maxY = Math.max(0, root.scrollHeight - root.clientHeight);
    return root.scrollTop >= maxY - 1;
  },
  // 连续模式当前视口可见字符区间的终点（半开 end，章内学习单位偏移；口径与
  // calculateProgress 分子同源）。一次 walk 用 countCharsBeforeViewport 传视口**末边**
  // （横排 window.innerHeight / 竖排 0）累加「末边之前的字数」；物理到底（isAtEnd）时
  // end = 章总字数。calculateProgress 行为不变。
  getLastVisibleCharOffset: function() {
    var vertical = this.isVertical();
    var edge = vertical ? 0 : window.innerHeight;
    var walker = this.createWalker();
    var totalChars = 0;
    var exploredChars = 0;
    var node;
    while (node = walker.nextNode()) {
      var nodeLen = this.countChars(node.textContent);
      totalChars += nodeLen;
      if (nodeLen > 0) {
        exploredChars += this.countCharsBeforeViewport(node, vertical, edge);
      }
    }
    if (totalChars <= 0) return -1;
    return this.isAtEnd() ? totalChars : exploredChars;
  },
  // 连续模式恢复落点 settle：等一帧让恢复滚动落定后通知 Dart。
  //
  // TODO-perf（跨章）：旧实现是两层嵌套 setTimeout(16)，而且**两层里都不做任何事**，
  // 纯粹空等 32ms 再通知（分页版第一层至少还重设落点）。这里收敛成单层 16ms，与同
  // shell 的章首/章末分支（`单层 16ms + 重发滚动后立即通知`）时序一致。
  _settleAndNotify: function() {
    var self = this;
    setTimeout(function() { self.notifyRestoreComplete(); }, 16);
  },
  restoreProgress: async function(progress) {
    await document.fonts.ready;
    var self = this;
    if (progress <= 0) {
      // BUG-1140 第二轮：章首也登记。内容向下增长不移动 scroll 0，重锚
      // scrollToChapterStart 幂等；但章首之前若有前导插图（合并注入 / 封面），图 load
      // 后正文整体下移，不重锚就会停在图与正文之间的错位。
      this.registerImageLateAnchor({progress: 0});
      this.scrollToChapterStart();
      setTimeout(function() {
        self.scrollToChapterStart();
        self.notifyRestoreComplete();
      }, 16);
      return;
    }
    // TODO-1349：progress>=0.99 = 章末（往前翻到上一章的落点），与分页版
    // scrollToProgressPaged 的 `progress>=0.99 → contentLastPageScroll` 对称。走
    // scrollToChapterEnd 落到正文末端（含纯图片/封面章、尾部插图），不再因
    // scrollToProgressContinuous 只走文本节点而在图片章停回章首（封面）。双发一次
    // 再确认对齐（防恢复后自发 reflow 把落点冲回，与 scrollToChapterStart 同构）。
    if (progress >= 0.99) {
      // TODO-1349（续）：登记章末重锚资格 + 强制 load 尾部懒图（打破鸡生蛋，见
      // forceLoadPendingImages）。16ms 双发太快等不到图 load，故尾图 load 后由
      // _sharedInitImages 的 load 回调重锚 scrollToChapterEnd（连续分支）落到含尾图的真实章末。
      this.registerImageLateAnchor({progress: progress});
      this.forceLoadPendingImages();
      this.scrollToChapterEnd();
      setTimeout(function() {
        self.scrollToChapterEnd();
        self.notifyRestoreComplete();
      }, 16);
      return;
    }
    // BUG-1140 第二轮：中段 progress 同样登记（理由见分页版 restoreProgress 长注释）。
    this.registerImageLateAnchor({progress: progress});
    this.scrollToProgressContinuous(progress);
    this._settleAndNotify();
  },
  // fragment 落点的纯几何对齐（jumpToFragment 与迟到图片重锚共用），见分页版同名方法。
  alignToFragmentTarget: function(fragment) {
    var rawFragment = (fragment || '').trim();
    var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
    if (!target) return false;
    target.scrollIntoView();
    return true;
  },
  jumpToFragment: async function(fragment) {
    await document.fonts.ready;
    if (!this.alignToFragmentTarget(fragment)) {
      this.clearImageLateAnchor();
      this.notifyRestoreComplete();
      return false;
    }
    this.registerImageLateAnchor({fragment: fragment});
    this._settleAndNotify();
    return true;
  },
  paginate: function(direction) {
    // TODO-1349（续）：用户翻页即放弃 late-load 重锚资格（镜像分页 paginate），
    // 避免图 load 回调把用户已翻走的位置拽回恢复锚。
    this.clearImageLateAnchor();
    var vertical = this.isVertical();
    var root = document.scrollingElement || document.documentElement;
    var before = vertical ? window.scrollX : root.scrollTop;
    var wm = window.getComputedStyle(document.body).writingMode;
    var amount = vertical
      ? Math.max(1, Math.floor(window.innerWidth * 0.9))
      : Math.max(1, Math.floor(window.innerHeight * 0.9));
    var forwardSign = vertical && wm === 'vertical-rl' ? -1 : 1;
    var step = amount * (direction === "forward" ? forwardSign : -forwardSign);
    if (vertical) {
      window.scrollBy({left: step, top: 0, behavior: 'auto'});
    } else {
      window.scrollBy({left: 0, top: step, behavior: 'auto'});
    }
    var after = vertical ? window.scrollX : root.scrollTop;
    var moved = Math.abs(after - before) > 1;
    return moved ? "scrolled" : "limit";
  },
  getFirstVisibleCharOffset: function() {
    var vertical = this.isVertical();
    var cs = getComputedStyle(document.body);
    var pt = parseFloat(cs.paddingTop) || 0;
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    var x = vertical ? (window.innerWidth - pr - 2) : (pl + 2);
    var y = pt + 2;
    var range = document.caretRangeFromPoint(x, y);
    // TODO-736 A-2：caretRangeFromPoint 在竖排 / ruby / 图片页 / 折叠盒落点返 null →
    // 旧实现返 -1，落库丢精确字符锚、退化成章节粒度分数（退出再进/重锚回章首附近）。
    // 改走 firstVisibleCharOffsetByScan 全文累加兜底（无 caret 几何依赖，同字符坐标系）。
    if (!range || !range.startContainer) return this.firstVisibleCharOffsetByScan();
    var target = range.startContainer;
    if (target.nodeType !== Node.TEXT_NODE) {
      var walker = this.createWalker(target);
      target = walker.nextNode();
      if (!target) return this.firstVisibleCharOffsetByScan();
    }
    var baseOffset = this.nodeStartOffsets.get(target);
    if (baseOffset === undefined) {
      this.buildNodeOffsets();
      baseOffset = this.nodeStartOffsets.get(target);
      if (baseOffset === undefined) return this.firstVisibleCharOffsetByScan();
    }
    var localChars = 0;
    var text = target.textContent;
    var limit = Math.min(range.startOffset, text.length);
    for (var i = 0; i < limit; i++) {
      var cp = text.codePointAt(i);
      if (window.fushiStudyUnits.isUnitEnd(text, i)) localChars++;
      if (cp > 0xFFFF) i++;
    }
    return baseOffset + localChars;
  },
  // BUG-162: 连续模式按 section 内绝对字符偏移定位（连续滚动语义：把目标字符滚到
  // 视口首边）。抽自原 setChromeInsets 内联体，供 setChromeInsets 重锚与退出再进
  // 恢复共用（DRY）。
  // BUG-461：把章内绝对可匹配字符索引解析成一个塌缩到该字符起始边的 collapsed range。
  // 抽自 scrollToCharOffset 内联体，供「句首锚」与「句尾锚」共用（DRY），返回 null 表示
  // 该偏移落在正文之外（解析失败）。
  collapsedRangeAtCharOffset: function(charOffset) {
    if (charOffset < 0) return null;
    var walker = this.createWalker();
    var node;
    var runningOffset = 0;
    var targetNode = null;
    while (node = walker.nextNode()) {
      var nodeChars = this.countChars(node.textContent);
      if (runningOffset + nodeChars > charOffset) { targetNode = node; break; }
      runningOffset += nodeChars;
    }
    if (!targetNode) return null;
    var remaining = charOffset - runningOffset;
    var charIdx = 0;
    var textOffset = 0;
    var text = targetNode.textContent;
    for (var i = 0; i < text.length && charIdx < remaining; i++) {
      var cp = text.codePointAt(i);
      if (window.fushiStudyUnits.isUnitEnd(text, i)) charIdx++;
      if (cp > 0xFFFF) i++;
      textOffset = i + 1;
    }
    var range = document.createRange();
    range.setStart(targetNode, Math.min(textOffset, text.length));
    range.collapse(true);
    return range;
  },
  // BUG-461：连续模式按章内绝对字符偏移定位（连续滚动语义：把目标字符滚到视口首边）。
  // [endCharOffset]（可选）= 收藏句句尾的绝对字符偏移：传入时把跳转目标当作字符区间
  // [charOffset, endCharOffset]，先把句首贴内容顶，若句尾溢出可见区底沿且整句放得下，
  // 多滚把句尾拉进可见区底沿（continuousFavoriteJumpScrollForTesting 的 JS 实现，整句完整
  // 可见、不被阅读底栏切尾）。不传 endCharOffset（setChromeInsets / 缩放 / 换样式重锚）
  // 时行为与旧版完全一致（句首贴顶，单点锚）。
  scrollToCharOffset: function(charOffset, endCharOffset, hintScroll) {
    // TODO-1229 (BUG-594 第 6 次复诉)：charOffset<=0 == 章节绝对起点区（fvco 归 0）。本函数只走
    // 文本节点（collapsedRangeAtCharOffset→createWalker=SHOW_TEXT），charOffset 0 的 range 落
    // 在**首个文本字符**——若本章以扉页插图开篇，该字符在插图之后，滚到它会跳过前导插图。
    // setChromeInsets / 缩放(commitUiScaleReanchor) / 换样式(commitStyleReanchor) 三条重锚都以
    // getFirstVisibleCharOffset()==0 裸调本函数（restoreToCharOffset 的 <=0 守卫只拦 restore 入口、
    // 拦不到这些 reanchor）→ 初始 restore 落插图页后被它们二次跳到首文本（残留第二跳）。
    //
    // 续修：fvco==0 二义——「用户在章顶前导插图」与「用户在首文本页（char0 正在视口首边）」都
    // 报 0，唯有重锚前采到的滚动位 hintScroll 能判开。裸 scrollToChapterStart 修好了「章顶被弹到
    // 首文本」却把「停在首文本页」的用户弹回章顶前导（headless continuous firstTextPage 守卫）。
    // 故 <=0 时：有正 hint（用户已滚离章顶）→ 保住当前滚动位（重锚只该保位、不移动用户，与分页
    // 版「<=0 保住当前页」同构）；hint 缺席/<=0（章顶前导页 or Dart 直接 scrollToCharOffset(0) 求
    // 章首）→ scrollToChapterStart 滚到顶（含前导图，与 restoreProgress(0) 语义一致）。charOffset>0
    // 精确锚（含收藏句区间 endCharOffset）不变。
    if (charOffset <= 0) {
      // TODO-1308 问题②（BUG-696 根因③）：连续滚动位横排是 scrollTop（>=0），竖排是
      // window.scrollX（vertical-rl 滚离章顶后为**负**，见 _readContinuousScroll /
      // scrollToChapterEnd 的 -1e9）。旧判据 hintScroll > 0 在竖排永假 → TODO-1229 的
      // 「保住当前滚动位」分支在竖排是死代码：任何重锚（setChromeInsets / 缩放 /
      // 换样式）一旦把 fvco 采成 0 就 scrollToChapterStart 把用户钉回章首。轴向归一：
      // 非零即「已滚离章顶」（两轴章顶都是 0），_writeContinuousScroll 原样写回带号位。
      if (typeof hintScroll === 'number' && Math.abs(hintScroll) > 0) {
        this._writeContinuousScroll(hintScroll);
      } else {
        this.scrollToChapterStart();
      }
      return;
    }
    var startRange = this.collapsedRangeAtCharOffset(charOffset);
    if (!startRange) return;
    var rect = startRange.getBoundingClientRect();
    var vertical = this.isVertical();
    var root = document.scrollingElement || document.documentElement;
    var cs = getComputedStyle(document.body);
    if (vertical) {
      var pr = parseFloat(cs.paddingRight) || 0;
      var targetX = window.innerWidth - pr;
      var startScrollV = root.scrollLeft + (rect.left - targetX);
      // 竖排可见区在内容宽度轴（chrome-* inset 仍是顶/底 padding 与本轴正交），无「句尾被
      // 底栏切」语义 → 句首贴右沿即可（与旧版一致）。
      root.scrollLeft = startScrollV;
      return;
    }
    var pt = parseFloat(cs.paddingTop) || 0;
    // 句尾区间锚（BUG-461）：仅横排、且调用方给了句尾偏移时启用。
    if (typeof endCharOffset === 'number' && endCharOffset > charOffset) {
      var endRange = this.collapsedRangeAtCharOffset(endCharOffset);
      if (endRange) {
        var endRect = endRange.getBoundingClientRect();
        var lineH = parseFloat(cs.lineHeight);
        if (!(lineH > 0)) lineH = (parseFloat(cs.fontSize) || 16) * 1.5;
        // 句尾远边 = 句尾字符底边（含其所在行高），相对句首起始边的尺寸。
        var sentenceExtent = (endRect.top + lineH) - rect.top;
        var rootStyle = getComputedStyle(document.documentElement);
        var topInset = parseFloat(
          rootStyle.getPropertyValue('--chrome-top-inset')) || 0;
        var bottomInset = parseFloat(
          rootStyle.getPropertyValue('--chrome-bottom-inset')) || 0;
        var vh = window.innerHeight;
        var bandTop = topInset;
        var bandBottom = vh - bottomInset;
        var band = bandBottom - bandTop;
        var startAligned = root.scrollTop + (rect.top - pt);
        if (sentenceExtent > 0 && band > 0 && sentenceExtent <= band) {
          var sentenceBottomInViewport = pt + sentenceExtent;
          var overflow = sentenceBottomInViewport - bandBottom;
          if (overflow < 0) overflow = 0;
          var target = startAligned + overflow;
          root.scrollTop = target < 0 ? 0 : target;
          return;
        }
        root.scrollTop = startAligned < 0 ? 0 : startAligned;
        return;
      }
    }
    root.scrollTop += rect.top - pt;
  },
  // BUG-162: 退出再进的精确恢复（连续）。charOffset<0（旧存档）回退章首；调用方在
  // initialCharOffset<0 时改走 restoreProgress（分数）。BUG-461：endCharOffset（可选）=
  // 收藏句句尾偏移，透传给 scrollToCharOffset 做整句区间对齐（不传则单点句首锚）。
  restoreToCharOffset: async function(charOffset, endCharOffset) {
    await document.fonts.ready;
    // TODO-1229 (BUG-594)：charOffset 0 == 章首（0 字已读）。连续模式章首插图同理不得越过，
    // scrollToChapterStart 滚到顶（含前导图），与 restoreProgress 章首语义一致。>0 走精确锚不变。
    if (charOffset <= 0) {
      this.scrollToChapterStart();
      this.registerImageLateAnchor({progress: 0});
    } else {
      // BUG-492 (TODO-1053 Bug A) 越界兜底：护住旧脏收藏记录。写入端曾把某句错记成
      // 相邻章 sectionIndex（_currentChapter 漂移），恢复端忠实加载该错章 DOM 后，本 charOffset
      // 是「另一章」的绝对偏移，在当前（错）章内可能超出本章可匹配字符总数 →
      // collapsedRangeAtCharOffset 返 null → scrollToCharOffset 静默 return，视口停在恢复瞬态
      // 位置（章首附近的 reflow 落点）→ 用户看不到收藏句、且无任何提示。改为越界即回退章首
      // （确定性落点），比静默停错位可诊断。锚在范围内（含新写入 / 已修数据）走精确对齐，行为不变。
      if (!this.charOffsetInRange(charOffset)) {
        this.scrollToChapterStart();
        this.registerImageLateAnchor({progress: 0});
      } else {
        this.scrollToCharOffset(charOffset, endCharOffset);
        // BUG-1140 第二轮：精确字符锚登记重锚资格（理由见分页版 restoreToCharOffset）。
        this.registerImageLateAnchor(
            {charOffset: charOffset, endCharOffset: endCharOffset});
      }
    }
    this._settleAndNotify();
  },
  setChromeInsets: function(topPx, bottomPx) {
    // See the paginated setChromeInsets: re-anchoring is serialised through the
    // shared _reanchorPending flag so a transiently reset scrollTop (from a
    // previous inset/size change's relayout) is never sampled as the chapter
    // start. The rAF clears the flag in a finally{} so an early return from a
    // failed node lookup can never leave the flag stuck. (HBK-REG-004)
    var inFlight = this._reanchorPending === true;
    var charOffset = inFlight ? -1 : this.getFirstVisibleCharOffset();
    // TODO-1229：采样重锚前滚动位（<=0 章首区二义时保住当前位，不弹回章顶前导）。
    var scrollBefore = inFlight ? 0 : this._readContinuousScroll();
    document.documentElement.style.setProperty('--chrome-top-inset', topPx + 'px');
    document.documentElement.style.setProperty('--chrome-bottom-inset', bottomPx + 'px');
    if (inFlight || charOffset < 0) return;
    this._setReanchorPending(true);
    var self = this;
    requestAnimationFrame(function() {
      try {
        self.scrollToCharOffset(charOffset, undefined, scrollBefore);
      } finally {
        self._setReanchorPending(false);
      }
    });
  },
  // TODO-693: appUiScale（整体界面缩放）变化时，连续模式的阅读位置只是裸 window.scrollY，
  // 没有分页模式的 registerSnapScroll/lockRootViewport 保护。FushiAppUiScale 用新 s 重建
  // 两层 FittedBox/SizedBox → WebView 平台视图 box.size 过渡帧抖动 → 击穿 SetSizeDedup →
  // native put_Bounds → WebView2 reflow 把 document scrollY 瞬时归 0，归零后无任何机制拉回，
  // 于是被章内 scroll 回传通道当作真实滚动落库 progress≈0 → 弹回章节开头。
  //
  // 修复镜像 setChromeInsets 的 _reanchorPending 串行契约，但拆成 Dart 编排的两阶段：缩放是
  // FittedBox 逐帧过渡，box.size 要等过渡帧 settle 才稳定，单个 rAF 不保证捕捉到稳定帧，故由
  // Dart 在缩放重建那一帧同步采样锚 + 置旗（挡住 reflow 自发的归零 scroll 经 onReaderScroll
  // 污染落库），再在 postFrame settle 后提交滚动。两阶段共用同一个 _reanchorPending（与
  // setChromeInsets/updatePageSize/reanchorAfterStyleChange 同一串行旗，HBK-REG-004）。
  beginUiScaleReanchor: function() {
    // 已有重锚在飞（setChromeInsets/updatePageSize 等）→ 让既有序列接管，本次不重复采样，
    // 返回 -1 让 Dart 跳过提交（_uiScaleReanchorOffset 不被本次覆盖）。
    if (this._reanchorPending === true) return -1;
    var charOffset = this.getFirstVisibleCharOffset();
    if (charOffset < 0) return -1;
    this._setReanchorPending(true);
    this._uiScaleReanchorOffset = charOffset;
    // TODO-1229：暂存重锚前滚动位，commit 时用作 <=0 章首区保位 hint。
    this._uiScaleReanchorScroll = this._readContinuousScroll();
    return charOffset;
  },
  commitUiScaleReanchor: function() {
    // beginUiScaleReanchor 必须先成功置旗 + 暂存锚；否则（旗未由本入口置/锚无效）整体 no-op，
    // 绝不误清别处的 _reanchorPending（finally 只在本入口确实拥有旗时执行）。
    var off = this._uiScaleReanchorOffset;
    if (off === undefined || off < 0) return false;
    try {
      this.scrollToCharOffset(off, undefined, this._uiScaleReanchorScroll);
    } finally {
      this._uiScaleReanchorOffset = undefined;
      this._uiScaleReanchorScroll = undefined;
      this._setReanchorPending(false);
    }
    return true;
  },
  // TODO-736 B-1：图片 max 变量重置共享 helper。换样式后图片 max-width/height 须按当前
  // content-box 重算（否则改字号 reflow 后图片尺寸约束陈旧）。$imageWidthRatio 只能在
  // 各 shell 的 '''
        ' 模板里插值（_sharedJs 是 r'
        ''' 原始串不插值），故每个 shell 的
  // initialize 把比值存到 this._imageWidthRatio，本 helper 读它，begin/reanchor 共用。
  _resetImageMaxVars: function() {
    var box = this._imageMaxBox();
    document.documentElement.style.setProperty('--fushi-image-max-width', box.w + 'px');
    document.documentElement.style.setProperty('--fushi-image-max-height', box.h + 'px');
  },
  // TODO-736 B-1（必补点2）：样式变更专用两阶段重锚的**第一阶段**，由 Dart 在换样式那一
  // 刻调用。与 beginUiScaleReanchor 区别：那对只采锚滚回**不换 CSS**（缩放重建用），改字号
  // 必须在同一入口换 CSS 才能让重排后的 scrollToCharOffset 锚到新排版的真实位置——故新建
  // 这对专入口（不复用 appUiScale 那对）。流程：采锚（getFirstVisibleCharOffset，mode 解析
  // 到分页/连续各自版本，连续含 A-2 兜底）→ 换 CSS + 失效 metrics + 重置 image-max → 置旗
  // _reanchorPending + 暂存 _styleReanchorOffset/_styleReanchorHint。清旗推迟到 commit（由
  // Dart postFrame settle 驱动），挡住 reflow 未落定期的归零 scroll 经 onReaderScroll 污染
  // 落库（翻页多次改字号跳章首的时序根因）。返回采到的偏移；-1 = 无锚/已有重锚在飞 →
  // Dart 跳过 commit。styleEl 由调用方传入（Dart 已 getElementById/createElement 建好）。
  beginStyleReanchor: function(styleEl, css) {
    if (!this.didInitialize) { if (styleEl) styleEl.textContent = css; return -1; }
    // 已有重锚在飞（setChromeInsets/updatePageSize 等）→ 让既有序列接管，只换 CSS 不重采样。
    if (this._reanchorPending === true) {
      if (styleEl) styleEl.textContent = css;
      // BUG-2013：换样式/改字号会改列数 → 改水平滚动条的有无 → 改可视高度。
      // 这里不重写，放大字号后滚动条新出现的书末行照旧被裁，要等 resize 才自愈。
      this._applyContinuousHeight(
          this._contH || C.dartPageHeight || window.innerHeight);
      this._resetImageMaxVars();
      return -1;
    }
    var charOffset = this.getFirstVisibleCharOffset();
    // TODO-1229：连续模式采样 raw scroll 作 <=0 章首区保位 hint（getPagePosition 是分页专属，
    // 连续用内容轴 scroll）。charOffset>0 精确锚不用 hint，故仅 <=0 二义时消歧、不影响正段落。
    var hint = this._readContinuousScroll();
    if (styleEl) styleEl.textContent = css;
    if (this.paginationMetrics !== undefined) this.paginationMetrics = null;
    // BUG-2013：换样式/改字号会改列数 → 改水平滚动条的有无 → 改可视高度。
    // 这里不重写，放大字号后滚动条新出现的书末行照旧被裁，要等 resize 才自愈。
    this._applyContinuousHeight(
          this._contH || C.dartPageHeight || window.innerHeight);
    this._resetImageMaxVars();
    if (charOffset < 0) return -1;
    this._setReanchorPending(true);
    this._styleReanchorOffset = charOffset;
    this._styleReanchorHint = hint;
    return charOffset;
  },
  // TODO-736 B-1：第二阶段——过渡帧 settle 后把暂存锚滚回视口首边并清 _reanchorPending。
  // 仅当 beginStyleReanchor 成功暂存了有效锚时才生效，否则整体 no-op（绝不误清别处的旗，
  // finally 只在本入口确实拥有旗时执行）。TODO-1229：连续 hint=raw scroll，作 3 参 hintScroll
  // 传入（仅 <=0 章首区保位用；off>0 精确锚忽略，endCharOffset 传 undefined 保单点锚语义）。
  commitStyleReanchor: function() {
    var off = this._styleReanchorOffset;
    if (off === undefined || off < 0) return false;
    var hint = this._styleReanchorHint;
    try {
      this.scrollToCharOffset(off, undefined, hint);
    } finally {
      this._styleReanchorOffset = undefined;
      this._styleReanchorHint = undefined;
      this._setReanchorPending(false);
    }
    return true;
  }
};
window.fushiReader.initialize = function() {
  if (window.fushiReader.didInitialize) return;
  window.fushiReader.didInitialize = true;
  this.perfMark('initStart');
  document.documentElement.style.setProperty('--chrome-top-inset', C.chromeTopInset + 'px');
  document.documentElement.style.setProperty('--chrome-bottom-inset', C.chromeBottomInset + 'px');
$_sharedInitViewport
  // TODO-736 B-1：存图片宽比值供 _resetImageMaxVars 读（_sharedJs 不插值，见那里注释）。
  this._imageWidthRatio = $imageWidthRatio;
  var dartH = C.dartPageHeight;
  var contHeight = dartH || window.innerHeight;
  window.__fushiApplyReaderMargins(C.dartPageWidth || window.innerWidth, contHeight);
  // BUG-2013：写进 CSS 的必须是扣掉水平滚动条的可视高度，不是视口外框高度。
  this._applyContinuousHeight(contHeight);
  var __imgBox = this._imageMaxBox();
  document.documentElement.style.setProperty('--fushi-image-max-width', __imgBox.w + 'px');
  document.documentElement.style.setProperty('--fushi-image-max-height', __imgBox.h + 'px');
$initImages
  this.perfMark('initSyncDone');
  Promise.all(imagePromises).then(function() {
    window.fushiReader.perfMark('imagesReady');
    window.fushiReader.buildNodeOffsets();
    window.fushiReader.perfMark('offsetsBuilt');
    // TODO-627：图片可能在初次分页 metrics 建好之后才 decode 完。此前
    // buildPaginationMetrics 枚举到的 <img> 还是 0x0（getBoundingClientRect 全 0），
    // metrics.maxScroll 漏掉图片所占的列 → 偏小 → paginate 在图片页前就误判到末页
    // → _handlePageTurnLimit 跳过插画页跨章。图片 decode 完成后必须失效缓存的
    // paginationMetrics，强制下次 paginate 用纳入图片真实尺寸的几何重建（与
    // updatePageSize / reanchorAfterStyleChange 的 metrics 失效一致）。
    if (window.fushiReader.paginationMetrics !== undefined) {
      window.fushiReader.paginationMetrics = null;
    }
    $sentenceAudioInit
    $initialRestoreScript
  });
};
window.fushiReader.updatePageSize = function(cssWidth, cssHeight) {
  var newHeight = Math.round(cssHeight);
  var newWidth = Math.round(cssWidth);
  var changed = (newHeight !== this._contH || newWidth !== this._contW);
  this._contH = newHeight;
  this._contW = newWidth;
  // Shares _reanchorPending with setChromeInsets (see there): while a re-anchor
  // rAF is in flight, only update the layout and let it restore position.
  var inFlight = this._reanchorPending === true;
  var progress = (changed && !inFlight) ? this.calculateProgress() : 0;
  // BUG-2013：同 initialize——CSS 变量要可视高度，_contH / applyReaderMargins 要外框高度。
  this._applyContinuousHeight(newHeight);
  window.__fushiApplyReaderMargins(newWidth, newHeight);
  var __imgBox = this._imageMaxBox();
  document.documentElement.style.setProperty('--fushi-image-max-width', __imgBox.w + 'px');
  document.documentElement.style.setProperty('--fushi-image-max-height', __imgBox.h + 'px');
  if (inFlight || progress <= 0) return;
  this._setReanchorPending(true);
  var self = this;
  requestAnimationFrame(function() {
    try {
      self.scrollToProgressContinuous(progress);
    } finally {
      self._setReanchorPending(false);
    }
  });
};
(function() {
  var TAP_SLOP = 12;
  var SWIPE_THRESHOLD = 20;
  var downX = 0, downY = 0, downSPos = 0, downSMax = 1, hasDown = false;
  function _bStart(x, y) {
    hasDown = true; downX = x; downY = y;
    // TODO-656：记手势起点(touchstart)沿内容轴的滚动量 + 最大可滚量，跨章只看
    // 起点是否已在边界（见 _bEnd / 纯函数 touchBoundaryCrossDir）。
    var root = document.scrollingElement || document.documentElement;
    var vertical = window.fushiReader && window.fushiReader.isVertical();
    if (vertical) {
      downSPos = Math.abs(root.scrollLeft);
      downSMax = Math.max(1, root.scrollWidth - window.innerWidth);
    } else {
      downSPos = root.scrollTop;
      downSMax = Math.max(1, root.scrollHeight - window.innerHeight);
    }
  }
  function _bEnd(x, y, src) {
    if (!hasDown) return;
    hasDown = false;
    // TODO-1317: a mobile long-press drag-select owns this touch; never cross
    // chapters from a selection gesture.
    if (window.__fushiTextSelectDragActive) return;
    var dx = x - downX;
    var dy = y - downY;
    if (Math.abs(dx) < TAP_SLOP && Math.abs(dy) < TAP_SLOP) return;
    var vertical = window.fushiReader && window.fushiReader.isVertical();
    var gestureDir = null;
    if (vertical) {
      if (Math.abs(dx) < SWIPE_THRESHOLD || Math.abs(dx) < Math.abs(dy)) return;
      gestureDir = dx > 0 ? 'forward' : 'backward';
    } else {
      if (Math.abs(dy) < SWIPE_THRESHOLD || Math.abs(dy) < Math.abs(dx)) return;
      gestureDir = dy < 0 ? 'forward' : 'backward';
    }
    // TODO-656 根治：跨章只看手势起点(touchstart 记的 downSPos)是否已停在边界，不再用
    // touchend 瞬时 scrollTop<=2。从章中滚到边界的那一下起点不在边界 → 不跨章；到边界后
    // 再发同向手势才跨（与纯函数 touchBoundaryCrossDir 同形）。消除「没到章首就跨章」。
    var downAtStart = downSPos <= 2;
    var downAtEnd = downSPos >= downSMax - 2;
    var dir = null;
    if (gestureDir === 'backward' && downAtStart) dir = 'backward';
    else if (gestureDir === 'forward' && downAtEnd) dir = 'forward';
    console.log('[xchapter] bEnd src=' + src + ' vertical=' + (vertical ? 1 : 0)
      + ' gestureDir=' + gestureDir + ' downSPos=' + Math.round(downSPos)
      + ' downSMax=' + Math.round(downSMax)
      + ' downAtStart=' + (downAtStart ? 1 : 0) + ' downAtEnd=' + (downAtEnd ? 1 : 0)
      + ' dir=' + dir);
    if (dir && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('onBoundarySwipe', dir);
    }
  }
  document.addEventListener('touchstart', function(e) {
    if (!e.touches.length) return;
    _bStart(e.touches[0].clientX, e.touches[0].clientY);
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    if (!e.changedTouches.length) return;
    _bEnd(e.changedTouches[0].clientX, e.changedTouches[0].clientY, 'touch');
  }, {passive: true});
  // 砍掉 PC 鼠标/触控笔(pointer)的边界手势跨章：连续模式鼠标左键已回归原生选字/划词
  // （见 _fushiReaderMouseDragStartAllowed 连续模式返 false），PC 桌面跨章只走滚轮；
  // 边界手势只保留触摸(touchstart/touchend)给手机。鼠标拖动选词到边界不再误跨章。
})();
$_sharedInitBoot
};
</script>''';
  }

  // BUG-1140 第二阶段①：VN 侧那份手写转义的 `_jsStringLiteral` 已随「shell 不再插值」
  // 一并删除（VN shell 不再从 Dart 造 JS 字符串字面量）。本实现仍供
  // highlightSasayakiCue / scrollToSearchMatch 这类**调用式**注入使用，
  // 输出字节形式由 test/reader/reader_pagination_scripts_test.dart 钉死。
  static String _jsStringLiteral(String value) {
    return jsonEncode(value);
  }
}
