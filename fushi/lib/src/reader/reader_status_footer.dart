import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudySessionTotals;

import 'package:fushi/src/reader/reader_chrome_floating.dart'
    show kTopProgressFontSize;

/// 各平台共用的阅读器底部状态行。
///
/// 一条极简的状态行。挤压态常驻、占预留高（正文永不压到它下面）；悬浮态
/// （`tap_empty_hide_chrome`）不占预留、随控制栏一起唤出 / 收起，收起期间屏底只剩
/// 一条 [ReaderProgressEdgeLine] 细进度线。两段读数都贴**右下角**，顺序与播放条唤出
/// 时的 [ReaderStatusInline] 一致：
///  * 阅读追踪——计时器图标 + `<本次时长>`（如 `0:00`）；
///  * 字数进度——一段短进度条 + `<百分比>%`。
///
/// 2026-09-13 精简：此前是 `<字/时> / h <时长>  <已读> / <总字数>  <百分比>%
/// (<本章已读> / <本章总字数> <本章百分比>%)` 六个数一串，用户要「简洁 + 进度条」。
/// 字/时、字数、本章进度全部进统计侧栏（`ReaderStatisticsSheet`）。
///
/// 追踪块此前独自钉在**左**下角：底部信息被劈成左右两个角，视线要在两角之间跳；而
/// 有声书播放条一唤出（[ReaderStatusInline]），同一串数字又整体飞到右端，两条底部形态
/// 互换时读数横跨整屏跳位。两段并排贴右后，底部读数只有一处落点。
///
/// 它取代顶部进度 pill：进度数字统一放在右下角；窄屏文案省略，完整统计仍可点击查看。
///
/// 高度只有一个真相源 [kReaderStatusFooterHeight]：页面用它算底部预留
/// （`_readerBottomReserve`）喂 WebView，组件用它画自身——视觉高度 == 预留高度
/// 是 chrome 的铁律（见 reader_chrome_floating.dart 文件头）。
const double kReaderStatusFooterHeight = 28;

/// 状态行文字字号，与顶部进度 pill 同源（12）。
const double kReaderStatusFooterFontSize = kTopProgressFontSize;

/// 状态行是否启用：非歌词模式，且两段读数里至少还剩一段要画。保留 desktop 参数
/// 兼容调用方。
///
/// 歌词模式是独立 HTML 文档，进度与阅读追踪都不适用（顶部进度 pill 在歌词模式同样
/// 不画），且它的底部留白走 `independentDocumentInsets` 的 Flutter 侧 Padding，
/// 不经 `setChromeInsets`；状态行在歌词模式下既不画也不占预留。
///
/// 「显示阅读计时器」「阅读进度指示」两个开关**都**关掉时整条行不画也不占预留——
/// 空行照占 28px 是白吃正文高度。判据只此一处（[readerStatusFooterReserve] 的
/// `enabled` 就是它），绘制与预留不会各判各的。
bool readerStatusFooterEnabled({
  required bool desktop,
  required bool lyricsMode,
  required bool showTimer,
  required bool showProgress,
}) =>
    !lyricsMode && (showTimer || showProgress);

/// 状态行是否已被底栏**吸收**：挤压态底栏占位（[bottomChromeReserve] > 0）且宽屏把
/// 同一串读数并进了底栏右端（[inlineStatus]，[ReaderStatusInline]）。
///
/// 那时状态行既不画也不占预留——底部只有一条。此前挤压态下状态行坐在底栏之上、底栏
/// 右端又画一份同样的数字：同一串「计时 / 已读 / 百分比」上下叠两行，多占一条
/// [kReaderStatusFooterHeight] 的正文高度（BUG-2467）。悬浮态底栏不占位
/// （[bottomChromeReserve] == 0），状态行照常在场，底栏唤出时盖在其上、收起后露出。
/// 窄屏（读数不并进底栏）状态行仍独立成行，坐在底栏之上，不吸收。
///
/// 悬浮态底栏不占位（[bottomChromeReserve] == 0），改看 [floatingBarPainted]——
/// 有声书播放条此刻画着且读数并进了它右端，状态行同样让位；播放条收起后状态行
/// 与顶栏一起收起（[readerStatusFooterVisible]），屏底只剩细进度线。
bool readerStatusFooterAbsorbedByBar({
  required bool inlineStatus,
  required double bottomChromeReserve,
  bool floatingBarPainted = false,
}) =>
    inlineStatus && (bottomChromeReserve > 0 || floatingBarPainted);

/// 状态行的底部预留高：启用、未被底栏吸收（[absorbedByBar]，见
/// [readerStatusFooterAbsorbedByBar]）且**非悬浮**时占 [footerHeight]，否则 0。
///
/// 悬浮态（[floating]）状态行与顶栏 / 底栏同一台显隐状态机：收起时正文满屏、唤出时
/// 盖在正文上——与 `readerDesktopHeaderReserve` / `bottomChromeReserve` 的悬浮语义
/// 一致（用户 2026-09-13 拍板「隐藏满屏、唤出覆盖」）。
double readerStatusFooterReserve({
  required bool enabled,
  required double footerHeight,
  bool absorbedByBar = false,
  bool floating = false,
}) =>
    enabled && !absorbedByBar && !floating ? footerHeight : 0;

/// 状态行是否此刻绘制：启用、首屏已就绪、未被底栏吸收；悬浮态额外随
/// [transientVisible]（与 `bottomBarVisible` 同一唤出 / 收起真值）。
bool readerStatusFooterVisible({
  required bool enabled,
  required bool hasEverLoaded,
  required bool absorbedByBar,
  required bool floating,
  required bool transientVisible,
}) {
  if (!enabled || !hasEverLoaded || absorbedByBar) return false;
  if (floating) return transientVisible;
  return true;
}

/// 屏底细进度线是否绘制：只在悬浮态、状态行收起、进度开关开着且总字数已知时——
/// 它是状态行收起后唯一留在屏上的进度指示（2px，不占预留、不参与命中）。
bool readerProgressEdgeLineVisible({
  required bool floating,
  required bool footerVisible,
  required bool showProgress,
  required bool hasTotal,
}) =>
    floating && !footerVisible && showProgress && hasTotal;

/// 屏底细进度线高度（逻辑 px）。
const double kReaderProgressEdgeLineHeight = 2;

/// 状态行里进度条的宽 / 高（逻辑 px）。
const double kReaderStatusProgressTrackWidth = 72;
const double kReaderStatusProgressTrackHeight = 3;

/// 全书进度比例（0–1）；总字数未知 / 为 0 时 null。
double? readerProgressRatio({required int? current, required int? total}) {
  if (current == null || total == null || total <= 0) return null;
  return (current / total).clamp(0.0, 1.0);
}

/// 状态行**底部带**的高度：状态行坐进系统底部安全区（iPhone home indicator 34pt /
/// Android 手势条）里，带高 = max(状态行预留 [footerReserve], 系统底 inset
/// [bottomInset])；状态行不在场（预留 0：歌词模式 / 被底栏吸收）时只剩系统 inset。
///
/// 此前预留是 `状态行高 + 系统 inset` 两段相加、状态行画在安全区**之上**：iPhone 上
/// 底部一共扣掉 28 + 34 = 62pt，其中 34pt 是一条谁也不用的纯背景空带（BUG-2470）。
/// home indicator 是叠在内容上的一条 5pt 细线（8pt 离底），不是不可用区域——参照
/// Hoshi Reader iOS 把进度读数直接放进去；桌面 / Android 沉浸模式 inset 为 0，带高就是
/// 状态行高，零变化。
double readerStatusFooterBandHeight({
  required double footerReserve,
  required double bottomInset,
}) =>
    math.max(footerReserve, bottomInset);

/// 每小时字数（四舍五入到整数）。时长或字数为 0 时返回 0，不做「不足 1 分钟无值」的
/// 统计口径门槛（那是统计页 `computeCph` 的事）：状态行开局就要显示 `0 / h`。
int readingCharsPerHour({required int chars, required int durationMs}) {
  if (chars <= 0 || durationMs <= 0) return 0;
  return (chars * 3600000 / durationMs).round();
}

/// 本次阅读时长的秒表格式：不足 1 小时 `m:ss`（开局 `0:00`），≥ 1 小时 `h:mm:ss`。
String formatReadingSessionClock(int durationMs) {
  final int totalSeconds = durationMs <= 0 ? 0 : durationMs ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  }
  return '$minutes:$ss';
}

/// 阅读追踪文案：`<本次时长>`（`m:ss` / `h:mm:ss`）。字/时不再挤在状态行里
/// （进统计侧栏）；[readingCharsPerHour] 仍是它的口径。
String readerTrackerLabel(StudySessionTotals totals) =>
    formatReadingSessionClock(totals.durationMs);

/// 进度文案：`<百分比>%`（一位小数）。总字数未知 / 为 0 时返回 null（不画这一段）。
/// 已读 / 总字数与本章进度在统计侧栏里看。
String? readerProgressLabel({required int? current, required int? total}) {
  final double? ratio = readerProgressRatio(current: current, total: total);
  if (ratio == null) return null;
  return '${(ratio * 100).toStringAsFixed(1)}%';
}

/// 状态行 / 播放条里的短进度条：一段圆角轨道 + 已读比例填充。
class ReaderStatusProgressTrack extends StatelessWidget {
  const ReaderStatusProgressTrack({
    super.key,
    required this.ratio,
    required this.color,
    this.width = kReaderStatusProgressTrackWidth,
    this.height = kReaderStatusProgressTrackHeight,
  });

  final double ratio;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(height),
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(height),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮态状态行收起后留在屏底的细进度线（[kReaderProgressEdgeLineHeight]）：
/// 不占预留、不吃指针（[IgnorePointer]），只是一条随全书进度增长的色带。
class ReaderProgressEdgeLine extends StatelessWidget {
  const ReaderProgressEdgeLine({
    super.key,
    required this.ratio,
    required this.color,
  });

  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: kReaderProgressEdgeLineHeight,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: ColoredBox(color: color.withValues(alpha: 0.55)),
          ),
        ),
      ),
    );
  }
}

class ReaderStatusFooter extends StatefulWidget {
  const ReaderStatusFooter({
    super.key,
    required this.sessionTotals,
    required this.currentChars,
    required this.totalChars,
    required this.showTimer,
    required this.showProgress,
    required this.textColor,
    required this.backgroundColor,
    this.height = kReaderStatusFooterHeight,
    this.bottomInset = 0,
    this.tick = const Duration(seconds: 1),
    this.onTap,
    this.onTapTracker,
    this.onTapProgress,
  });

  /// 会话累计的**读口**（每个 [tick] 采样一次）。账本在 `StudyClock`，页面不持有
  /// 任何会话累计副本（v92 统计纪律），所以这里拿的是函数而不是快照。
  final StudySessionTotals Function() sessionTotals;

  final int? currentChars;
  final int? totalChars;

  /// 阅读追踪（计时器图标 + 本次时长）是否显示（「显示阅读计时器」开关落到
  /// 这里）。关掉只是不画这一段——[StudyClock] 照常计时、照常落库，隐藏读数不等于
  /// 停表（停表是点这一段本身的手动暂停）。
  final bool showTimer;

  /// 进度读数是否显示（「阅读进度指示」开关落到这里）。
  final bool showProgress;

  final Color textColor;
  final Color backgroundColor;

  /// 读数行本身的高度（[kReaderStatusFooterHeight]）。
  final double height;

  /// 系统底部安全区高（iPhone home indicator）。整条状态行占
  /// `max(height, bottomInset)` 的带（[readerStatusFooterBandHeight]），读数行贴带顶、
  /// 多出的部分在读数行**之下**——读数落在 home indicator 细线之上，不与它重叠。
  final double bottomInset;

  /// 秒表刷新周期（测试可缩短）。
  final Duration tick;

  /// 点状态行空白处：与顶部进度 pill 同语义——唤出 / 收起控制栏。
  final VoidCallback? onTap;

  /// 点计时块「计时器 + 字/时 + 时长」：切换手动暂停计时。这是手动停 / 续表的**唯一**
  /// 入口——统计浮层里曾有一个同功能按钮，但开浮层本身就停表，层内开关改不动运行态。
  final VoidCallback? onTapTracker;

  /// 点进度数字：直接打开阅读统计浮层。
  final VoidCallback? onTapProgress;

  @override
  State<ReaderStatusFooter> createState() => _ReaderStatusFooterState();
}

class _ReaderStatusFooterState extends State<ReaderStatusFooter> {
  Timer? _ticker;
  String? _lastTracker;

  @override
  void initState() {
    super.initState();
    // 秒表 tick 只在文案真的变了才重建：计时暂停 / 失焦期间读数不动，不白重建。
    _ticker = Timer.periodic(widget.tick, (_) {
      if (!mounted) return;
      // 计时器读数隐藏时这一层没有随秒变化的内容，秒表 tick 不必重建。
      if (!widget.showTimer) return;
      final String tracker = readerTrackerLabel(widget.sessionTotals());
      if (tracker == _lastTracker) return;
      setState(() => _lastTracker = tracker);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 状态行里可点的一段（计时块 / 进度数字）。命中区**撑满整条行高**：裸文字 + 14px
  /// 图标的行盒只有十几 px 高，指针（尤其手指）要精确戳中那一行才有反应；撑满后整条
  /// 28px 高的那一段都可点。只扩竖向、不加横向内边距——右端 16 的边距是与顶部 pill /
  /// inline 形态共用的视觉基线，补一层横向 padding 会把进度数字从右缘往里推。行高不
  /// 能为命中区加高（视觉高度 == 预留高度是 chrome 铁律，加高就是挤正文），所以这一段
  /// 的命中区上限就是行高 28px，达不到 48dp 的触摸下限。统计浮层里那颗 48dp 的整宽开关
  /// 已经撤了（开浮层本身就停表，层内开关改不动运行态），别再把它当后备入口写进注释。
  Widget _hitTarget({required Widget child, VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: widget.height,
        child: Center(widthFactor: 1, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final StudySessionTotals totals = widget.sessionTotals();
    final Color muted = widget.textColor.withValues(alpha: 0.55);
    final TextStyle style = TextStyle(
      fontSize: kReaderStatusFooterFontSize,
      color: muted,
      height: 1.0,
    );
    final double? ratio = widget.showProgress
        ? readerProgressRatio(
            current: widget.currentChars,
            total: widget.totalChars,
          )
        : null;
    final String? progress = ratio == null
        ? null
        : readerProgressLabel(
            current: widget.currentChars,
            total: widget.totalChars,
          );
    final double bandHeight = readerStatusFooterBandHeight(
      footerReserve: widget.height,
      bottomInset: widget.bottomInset,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: ColoredBox(
        color: widget.backgroundColor,
        child: SizedBox(
          height: bandHeight,
          child: Padding(
            // 读数行贴带顶，多出的安全区在读数之下（BUG-2470）。
            padding: EdgeInsets.fromLTRB(16, 0, 16, bandHeight - widget.height),
            // 两段读数并排贴右：Row 主轴 end 对齐把它们一起推到右缘，追踪块不再被
            // Expanded 的进度段挤到左角。窄屏保护不变——追踪块仍最多占 40% 宽、
            // 两段都 ellipsis，谁放不下谁先省略，行永远不溢出。
            child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (widget.showTimer)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth:
                            constraints.maxWidth * (progress == null ? 1 : .4),
                      ),
                      child: _hitTarget(
                        onTap: widget.onTapTracker,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              totals.active
                                  ? Icons.timer_outlined
                                  : Icons.timer_off_outlined,
                              key: ValueKey<bool>(totals.active),
                              size: kReaderStatusFooterFontSize + 2,
                              color: muted,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                readerTrackerLabel(totals),
                                key: const ValueKey<String>(
                                    'fushi_status_tracker'),
                                style: style,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (progress != null)
                    Flexible(
                      child: Padding(
                        padding: EdgeInsets.only(
                            left: widget.showTimer ? 8 : 0),
                        child: _hitTarget(
                          onTap: widget.onTapProgress,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              ReaderStatusProgressTrack(
                                key: const ValueKey<String>(
                                    'fushi_status_progress_track'),
                                ratio: ratio!,
                                color: muted,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  progress,
                                  key: const ValueKey<String>(
                                      'fushi_status_progress'),
                                  style: style,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// 状态行文案的单行内联版：桌面端有声书播放条唤出时，把「阅读追踪 + 进度」并进播放条
/// 右端（底部只留一条）。同一读口、同一格式函数，只是排版成一行两段。
class ReaderStatusInline extends StatefulWidget {
  const ReaderStatusInline({
    super.key,
    required this.sessionTotals,
    required this.currentChars,
    required this.totalChars,
    required this.showTimer,
    required this.showProgress,
    required this.textColor,
    this.tick = const Duration(seconds: 1),
  });

  final StudySessionTotals Function() sessionTotals;
  final int? currentChars;
  final int? totalChars;
  final bool showTimer;
  final bool showProgress;
  final Color textColor;
  final Duration tick;

  @override
  State<ReaderStatusInline> createState() => _ReaderStatusInlineState();
}

class _ReaderStatusInlineState extends State<ReaderStatusInline> {
  Timer? _ticker;
  String? _lastTracker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(widget.tick, (_) {
      if (!mounted) return;
      // 计时器读数隐藏时这一层没有随秒变化的内容，秒表 tick 不必重建。
      if (!widget.showTimer) return;
      final String tracker = readerTrackerLabel(widget.sessionTotals());
      if (tracker == _lastTracker) return;
      setState(() => _lastTracker = tracker);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StudySessionTotals totals = widget.sessionTotals();
    final Color muted = widget.textColor.withValues(alpha: 0.55);
    final TextStyle style = TextStyle(
      fontSize: kReaderStatusFooterFontSize,
      color: muted,
      height: 1.0,
    );
    final double? ratio = widget.showProgress
        ? readerProgressRatio(
            current: widget.currentChars,
            total: widget.totalChars,
          )
        : null;
    final String? progress = ratio == null
        ? null
        : readerProgressLabel(
            current: widget.currentChars,
            total: widget.totalChars,
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.showTimer) ...<Widget>[
          Icon(
            totals.active ? Icons.timer_outlined : Icons.timer_off_outlined,
            size: kReaderStatusFooterFontSize + 2,
            color: muted,
          ),
          const SizedBox(width: 6),
          Text(
            readerTrackerLabel(totals),
            key: const ValueKey<String>('fushi_bar_status_tracker'),
            style: style,
            maxLines: 1,
          ),
        ],
        if (progress != null) ...<Widget>[
          if (widget.showTimer) const SizedBox(width: 16),
          ReaderStatusProgressTrack(
            key: const ValueKey<String>('fushi_bar_status_progress_track'),
            ratio: ratio!,
            color: muted,
          ),
          const SizedBox(width: 8),
          Text(
            progress,
            key: const ValueKey<String>('fushi_bar_status_progress'),
            style: style,
            maxLines: 1,
          ),
        ],
      ],
    );
  }
}
