import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudySessionTotals;

import 'package:fushi/src/reader/reader_chrome_floating.dart'
    show kTopProgressFontSize;

/// 各平台共用的阅读器底部状态行。
///
/// 一条极简、常驻、**挤压式**（占预留高、正文永不压到它下面）的状态行。两段读数都
/// 贴**右下角**，顺序与播放条唤出时的 [ReaderStatusInline] 一致：
///  * 阅读追踪——计时器图标 + `<字/时> / h <本次时长>`（如 `0 / h 0:00`）；
///  * 字数进度——`<已读> / <总字数>  <百分比>%`。
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

/// 状态行是否启用：各平台的非歌词模式。保留 desktop 参数兼容调用方。
///
/// 歌词模式是独立 HTML 文档，进度与阅读追踪都不适用（顶部进度 pill 在歌词模式同样
/// 不画），且它的底部留白走 `independentDocumentInsets` 的 Flutter 侧 Padding，
/// 不经 `setChromeInsets`；状态行在歌词模式下既不画也不占预留。
bool readerStatusFooterEnabled({
  required bool desktop,
  required bool lyricsMode,
}) =>
    !lyricsMode;

/// 状态行的底部预留高：启用时占 [footerHeight]，否则 0。
double readerStatusFooterReserve({
  required bool enabled,
  required double footerHeight,
}) =>
    enabled ? footerHeight : 0;

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

/// 阅读追踪文案：`<字/时> / h <本次时长>`。
String readerTrackerLabel(StudySessionTotals totals) {
  final int cph = readingCharsPerHour(
    chars: totals.chars,
    durationMs: totals.durationMs,
  );
  return '$cph / h  ${formatReadingSessionClock(totals.durationMs)}';
}

/// 进度文案：`<已读> / <总字数>  <百分比>%`，与顶部进度 pill 同一格式；
/// 本章字数已知时再接一段括号 `(<本章已读> / <本章总字数> <本章百分比>%)`。
/// 总字数未知 / 为 0 时返回 null（不画这一段）。
String? readerProgressLabel({
  required int? current,
  required int? total,
  int? chapterCurrent,
  int? chapterTotal,
}) {
  if (current == null || total == null || total <= 0) return null;
  final double ratio = (current / total).clamp(0.0, 1.0);
  final String book = '$current / $total  ${(ratio * 100).toStringAsFixed(2)}%';
  if (chapterCurrent == null || chapterTotal == null || chapterTotal <= 0) {
    return book;
  }
  final int c = chapterCurrent.clamp(0, chapterTotal);
  final double chapterRatio = (c / chapterTotal).clamp(0.0, 1.0);
  return '$book  ($c / $chapterTotal ${(chapterRatio * 100).toStringAsFixed(2)}%)';
}

class ReaderStatusFooter extends StatefulWidget {
  const ReaderStatusFooter({
    super.key,
    required this.sessionTotals,
    required this.currentChars,
    required this.totalChars,
    required this.showProgress,
    this.chapterCurrentChars,
    this.chapterTotalChars,
    required this.textColor,
    required this.backgroundColor,
    this.height = kReaderStatusFooterHeight,
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

  /// 本章已读 / 本章总字数（进度后的括号段；任一未知则不画括号）。
  final int? chapterCurrentChars;
  final int? chapterTotalChars;

  /// 右侧进度是否显示（「阅读进度指示」开关落到这里）。
  final bool showProgress;

  final Color textColor;
  final Color backgroundColor;
  final double height;

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
    final String? progress = widget.showProgress
        ? readerProgressLabel(
            current: widget.currentChars,
            total: widget.totalChars,
            chapterCurrent: widget.chapterCurrentChars,
            chapterTotal: widget.chapterTotalChars,
          )
        : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: ColoredBox(
        color: widget.backgroundColor,
        child: SizedBox(
          height: widget.height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // 两段读数并排贴右：Row 主轴 end 对齐把它们一起推到右缘，追踪块不再被
            // Expanded 的进度段挤到左角。窄屏保护不变——追踪块仍最多占 40% 宽、
            // 两段都 ellipsis，谁放不下谁先省略，行永远不溢出。
            child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
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
                        padding: const EdgeInsets.only(left: 8),
                        child: _hitTarget(
                          onTap: widget.onTapProgress,
                          child: Text(
                            progress,
                            key:
                                const ValueKey<String>('fushi_status_progress'),
                            style: style,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
    required this.showProgress,
    required this.textColor,
    this.chapterCurrentChars,
    this.chapterTotalChars,
    this.tick = const Duration(seconds: 1),
  });

  final StudySessionTotals Function() sessionTotals;
  final int? currentChars;
  final int? totalChars;
  final int? chapterCurrentChars;
  final int? chapterTotalChars;
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
    final String? progress = widget.showProgress
        ? readerProgressLabel(
            current: widget.currentChars,
            total: widget.totalChars,
            chapterCurrent: widget.chapterCurrentChars,
            chapterTotal: widget.chapterTotalChars,
          )
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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
        if (progress != null) ...<Widget>[
          const SizedBox(width: 16),
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
