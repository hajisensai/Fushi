import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiChromeReveal;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiModalSheetFrame;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';

/// 查词回调：第 [lineIndex] 行、第 [charOffset] 个字（grapheme 下标，与
/// `subtitleTranscriptLookupSpan(text, charOffset)` 同口径）+ 查词弹框的全局锚点
/// 矩形 [anchor]（被点字位→句末的字形盒并集，见 `subtitleListLookupAnchorRect`；
/// 键盘查词没有几何时为 [Rect.zero]）。
typedef VideoRemoteLookupCallback =
    void Function(int lineIndex, int charOffset, Rect anchor);

/// 当前句停在可视带的这个高度比例（与歌词模式 anchorY 同口径）。
const double kVideoRemoteTranscriptAnchor = 0.42;

/// 当前句相对普通行的放大倍数（歌词模式 `--cue-scale`）。
const double kVideoRemoteCurrentScale = 1.15;

/// 与当前句相隔 1 / 2 / 3 / ≥4 行的透明度（歌词模式 contextOpacities）。
const List<double> kVideoRemoteContextOpacities = <double>[
  0.62,
  0.48,
  0.38,
  0.3,
];

/// 已读行在距离透明度上再乘的系数（读过的退到背景）。
const double kVideoRemotePastOpacityFactor = 0.7;

/// 手动浏览（跟随关闭）时非当前行的统一透明度：浏览时要看得清。
const double kVideoRemoteBrowsingOpacity = 0.7;

/// 上下边缘渐隐占列表高度的比例。
const double kVideoRemoteEdgeFade = 0.06;

/// 第 [index] 行在当前句为 [activeIndex] 时的透明度（纯函数，测试用）。
/// [activeIndex] < 0 = 播放头落在两句之间：一律按相邻行处理。
double videoRemoteLineOpacity({
  required int index,
  required int activeIndex,
  required bool following,
}) {
  if (index == activeIndex) return 1;
  if (!following) return kVideoRemoteBrowsingOpacity;
  if (activeIndex < 0) return kVideoRemoteContextOpacities.first;
  final int distance = (index - activeIndex).abs();
  final double base =
      kVideoRemoteContextOpacities[math.min(
        distance - 1,
        kVideoRemoteContextOpacities.length - 1,
      )];
  return index < activeIndex ? base * kVideoRemotePastOpacityFactor : base;
}

/// 字幕行列表：视觉照歌词模式正文——当前句主色放大、按距离降透明度、已读
/// 减淡、当前句停在可视带约 42% 高处、上下边缘渐隐、弹簧自动跟随；手动滚动
/// 后关闭跟随并在底部浮出「回到当前句」。行高不定（长句换行、主题字号）。
///
/// 每个字可点（[onLookup]）；点行内空白处 [onLineTap]（通常是跳到这句）；
/// 长按行弹出 M3E 操作面板（重播 / 收藏 / 制卡）。
///
/// 状态：滚动位置在本组件的 State 里；跟随状态在 [controller] 里（调用方持有，
/// 控制卡上的「回到当前句」按钮也用它）。旋转时调用方用同一个 GlobalKey 挂
/// 本组件即可保住滚动位置（[VideoRemoteScaffold] 就是这么做的）。
class VideoRemoteTranscriptView extends StatefulWidget {
  const VideoRemoteTranscriptView({
    super.key,
    required this.lines,
    required this.activeIndex,
    required this.controller,
    required this.onLookup,
    this.onLineTap,
    this.onReplayLine,
    this.onToggleFavoriteLine,
    this.onMineLine,
    this.textStyle,
    this.padding = EdgeInsets.zero,
    this.entranceReplayKey,
    this.keyboardLookup = false,
    this.lookupHighlight,
  });

  /// 主轨字幕行（副轨挂在各行的 secondaryText 上）。
  final List<VideoRemoteTranscriptLine> lines;

  /// 当前句下标；-1 = 播放头在两句之间 / 未知。
  final int activeIndex;

  final VideoRemoteTranscriptController controller;

  /// 点某个字：查词。
  final VideoRemoteLookupCallback onLookup;

  /// 点行内文字以外的地方。
  final ValueChanged<int>? onLineTap;

  /// 长按面板里的「重播本句」；null = 不显示。
  final ValueChanged<int>? onReplayLine;

  /// 长按面板里的「收藏 / 取消收藏」；null = 不显示。
  final ValueChanged<int>? onToggleFavoriteLine;

  /// 长按面板里的「制卡」；null = 不显示。
  final ValueChanged<int>? onMineLine;

  /// 正文基准样式；null = 主题 titleLarge（跟随用户字号缩放）。
  final TextStyle? textStyle;

  /// 被浮动栏遮住的上下边距：当前句锚点与列表留白都按去掉它之后的可视带算。
  final EdgeInsets padding;

  /// 变化时重开错峰进场窗口（换视频 / 换字幕版本）。
  final Object? entranceReplayKey;

  /// 键盘逐字查词（外接键盘 / 桌面）。
  final bool keyboardLookup;

  /// 正在查的词（只画在它所属的那一行）；null = 不高亮。
  final VideoRemoteLookupHighlight? lookupHighlight;

  @override
  State<VideoRemoteTranscriptView> createState() =>
      _VideoRemoteTranscriptViewState();
}

class _VideoRemoteTranscriptViewState extends State<VideoRemoteTranscriptView> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};
  int _seenRecenterRequests = 0;
  bool _recenterScheduled = false;

  /// 最近一次布局的锚点（列表局部坐标 y）与上下留白。
  double _anchorY = 0;
  double _leadPadding = 0;

  @override
  void initState() {
    super.initState();
    _seenRecenterRequests = widget.controller.recenterRequests;
    widget.controller.addListener(_onControllerChanged);
    _scheduleRecenter(animate: false);
  }

  @override
  void didUpdateWidget(covariant VideoRemoteTranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _seenRecenterRequests = widget.controller.recenterRequests;
    }
    if (!identical(oldWidget.lines, widget.lines)) _rowKeys.clear();
    final bool jumped = !identical(oldWidget.lines, widget.lines);
    if ((oldWidget.activeIndex != widget.activeIndex || jumped) &&
        widget.controller.following) {
      _scheduleRecenter(animate: !jumped);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final int requests = widget.controller.recenterRequests;
    if (requests != _seenRecenterRequests) {
      _seenRecenterRequests = requests;
      _scheduleRecenter(animate: true);
    }
    if (mounted) setState(() {});
  }

  void _scheduleRecenter({required bool animate, int attempt = 0}) {
    if (_recenterScheduled) return;
    _recenterScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _recenterScheduled = false;
      _recenter(animate: animate, attempt: attempt);
    });
    // 空闲相位登记的帧后回调要有一帧才会跑。
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _recenter({required bool animate, int attempt = 0}) {
    if (!mounted || !_scroll.hasClients) return;
    final int index = widget.activeIndex;
    if (index < 0 || index >= widget.lines.length) return;
    final ScrollPosition position = _scroll.position;
    final RenderObject? render = _rowKeys[index]?.currentContext
        ?.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      // 目标行还没建出来（离得远）：按已布局行的平均高度先跳过去，下一帧再精对。
      if (attempt >= 3 || widget.lines.isEmpty) return;
      final double content =
          position.maxScrollExtent +
          position.viewportDimension -
          2 * _leadPadding;
      final double average = math.max(24, content / widget.lines.length);
      position.jumpTo(
        (_leadPadding + index * average - _anchorY).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      _scheduleRecenter(animate: false, attempt: attempt + 1);
      return;
    }
    final double rowTop = RenderAbstractViewport.of(
      render,
    ).getOffsetToReveal(render, 0).offset;
    final double target = (rowTop - (_anchorY - render.size.height / 2)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((position.pixels - target).abs() < 0.5) return;
    final Duration duration = animate
        ? fushiMotionDuration(context, FushiMotion.long)
        : Duration.zero;
    if (duration == Duration.zero ||
        (position.pixels - target).abs() > position.viewportDimension * 2) {
      position.jumpTo(target);
      return;
    }
    unawaited(
      _scroll.animateTo(
        target,
        duration: duration,
        curve: FushiSpringCurve.spatial,
      ),
    );
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // 只认手指拖动（programmatic animateTo 没有 dragDetails）。
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      widget.controller.stopFollowing();
    }
    return false;
  }

  Future<void> _showLineActions(int index) async {
    final VideoRemoteTranscriptLine line = widget.lines[index];
    final ValueChanged<int>? replay = widget.onReplayLine;
    final ValueChanged<int>? favorite = widget.onToggleFavoriteLine;
    final ValueChanged<int>? mine = widget.onMineLine;
    if (replay == null && favorite == null && mine == null) return;
    unawaited(HapticFeedback.mediumImpact());
    await adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        void run(ValueChanged<int> action) {
          Navigator.of(sheetContext).pop();
          action(index);
        }

        return _LineActionsSheet(
          line: line,
          onReplay: replay == null ? null : () => run(replay),
          onToggleFavorite: favorite == null ? null : () => run(favorite),
          onMine: mine == null ? null : () => run(mine),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return Padding(
        padding: widget.padding,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.subtitles,
            message: t.video_remote_transcript_empty,
          ),
        ),
      );
    }
    final ThemeData theme = Theme.of(context);
    final TextStyle base = (widget.textStyle ?? theme.textTheme.titleLarge!)
        .copyWith(height: 1.5);
    final bool following = widget.controller.following;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double height = constraints.maxHeight;
        final double bandTop = widget.padding.top;
        final double bandBottom = math.max(
          bandTop + 1,
          height - widget.padding.bottom,
        );
        _anchorY =
            bandTop + (bandBottom - bandTop) * kVideoRemoteTranscriptAnchor;
        // 首 / 末行也能停到锚点：上留白到锚点、下留白到底。一行约半个行高的
        // 偏差在弹簧里看不出来。
        final double lineHalf = (base.fontSize ?? 22) * 1.5 * 0.6;
        _leadPadding = math.max(0, _anchorY - lineHalf);
        final double trailPadding = math.max(0, height - _anchorY - lineHalf);
        final Widget list = NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: Listener(
            // 鼠标滚轮 / 触控板也算手动浏览。
            onPointerSignal: (PointerSignalEvent event) {
              if (event is PointerScrollEvent) {
                widget.controller.stopFollowing();
              }
            },
            child: FushiEntranceScope(
              replayKey: widget.entranceReplayKey,
              child: ListView.builder(
                key: const ValueKey<String>('video-remote-transcript-list'),
                controller: _scroll,
                padding: EdgeInsets.only(
                  top: _leadPadding,
                  bottom: trailPadding,
                  left: widget.padding.left,
                  right: widget.padding.right,
                ),
                itemCount: widget.lines.length,
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext context,
                  int index,
                ) {
                  final GlobalKey rowKey = _rowKeys.putIfAbsent(
                    index,
                    () => GlobalKey(debugLabel: 'video-remote-line-$index'),
                  );
                  return KeyedSubtree(
                    key: rowKey,
                    child: _TranscriptRow(
                      key: ValueKey<String>('video-remote-line-$index'),
                      index: index,
                      line: widget.lines[index],
                      current: index == widget.activeIndex,
                      opacity: videoRemoteLineOpacity(
                        index: index,
                        activeIndex: widget.activeIndex,
                        following: following,
                      ),
                      baseStyle: base,
                      keyboardLookup: widget.keyboardLookup,
                      lookupHighlight: widget.lookupHighlight?.rangeForLine(
                        widget.lines[index],
                      ),
                      onLookup: (int charOffset, Rect anchor) =>
                          widget.onLookup(index, charOffset, anchor),
                      onTap: widget.onLineTap == null
                          ? null
                          : () => widget.onLineTap!(index),
                      onLongPress: () => unawaited(_showLineActions(index)),
                    ),
                  );
                }),
              ),
            ),
          ),
        );
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (Rect bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: const <Color>[
                    Color(0x00000000),
                    Color(0xFF000000),
                    Color(0xFF000000),
                    Color(0x00000000),
                  ],
                  stops: <double>[
                    bandTop / math.max(1, height),
                    (bandTop / math.max(1, height)) + kVideoRemoteEdgeFade,
                    (bandBottom / math.max(1, height)) - kVideoRemoteEdgeFade,
                    bandBottom / math.max(1, height),
                  ],
                ).createShader(bounds),
                child: list,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.padding.bottom + 16,
              child: Center(
                child: FushiChromeReveal(
                  visible: !following && widget.activeIndex >= 0,
                  from: AxisDirection.down,
                  child: FushiPressScale(
                    child: FushiFilledButton.tonalIcon(
                      key: const ValueKey<String>(
                        'video-remote-return-current',
                      ),
                      onPressed: widget.controller.returnToCurrent,
                      icon: const FushiIcon(FushiIcons.myLocation),
                      label: Text(t.video_remote_current),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 一行字幕：主轨逐字可点 + 副轨小字 + 收藏星标。当前句主色、放大，非当前按
/// 距离降透明度；两态之间走 spatial 弹簧（动效关闭时瞬切）。
class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({
    super.key,
    required this.index,
    required this.line,
    required this.current,
    required this.opacity,
    required this.baseStyle,
    required this.keyboardLookup,
    required this.lookupHighlight,
    required this.onLookup,
    required this.onTap,
    required this.onLongPress,
  });

  final int index;
  final VideoRemoteTranscriptLine line;
  final bool current;
  final double opacity;
  final TextStyle baseStyle;
  final bool keyboardLookup;
  final SubtitleTranscriptHighlightRange? lookupHighlight;
  final void Function(int charOffset, Rect anchor) onLookup;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final double baseSize = baseStyle.fontSize ?? 22;
    final String? secondary = (line.secondaryText ?? '').trim().isEmpty
        ? null
        : line.secondaryText!.trim();
    return Semantics(
      selected: current,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedOpacity(
          opacity: opacity,
          duration: motion.effectsDefault.duration,
          curve: motion.effectsDefault.curve,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: current ? 1 : 0),
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            builder: (BuildContext context, double emphasis, Widget? _) {
              final double e = emphasis.clamp(0.0, 1.2);
              final TextStyle style = baseStyle.copyWith(
                fontSize: baseSize * (1 + (kVideoRemoteCurrentScale - 1) * e),
                fontWeight: e > 0.5 ? FontWeight.w600 : FontWeight.w500,
                color: Color.lerp(cs.onSurface, cs.primary, e.clamp(0, 1)),
              );
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SubtitleTranscriptText(
                            text: line.text,
                            style: style,
                            textKey: ValueKey<String>(
                              'video-remote-line-text-$index',
                            ),
                            keyboardLookup: keyboardLookup,
                            lookupHighlight: lookupHighlight,
                            onLookup: onLookup,
                            onBackgroundTap: onTap,
                          ),
                          if (secondary != null) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              secondary,
                              key: ValueKey<String>(
                                'video-remote-line-secondary-$index',
                              ),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Color.lerp(
                                  cs.onSurfaceVariant,
                                  cs.primary,
                                  e.clamp(0, 1) * 0.6,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (line.favorited)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 8,
                          top: 6,
                        ),
                        child: FushiIcon(
                          FushiIcons.filled(FushiIcons.star),
                          key: ValueKey<String>(
                            'video-remote-line-favorite-$index',
                          ),
                          size: 18,
                          color: cs.tertiary,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 长按行的 M3E 操作面板：句子预览 + 一排大号 tonal 按钮（标准按钮组，按下
/// 变宽）。
class _LineActionsSheet extends StatelessWidget {
  const _LineActionsSheet({
    required this.line,
    required this.onReplay,
    required this.onToggleFavorite,
    required this.onMine,
  });

  final VideoRemoteTranscriptLine line;
  final VoidCallback? onReplay;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onMine;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final String? secondary = line.secondaryText;
    Widget action(IconData icon, String label, VoidCallback onPressed) =>
        FushiFilledButton.tonalIcon(
          onPressed: onPressed,
          icon: FushiIcon(icon),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    return FushiModalSheetFrame(
      title: t.video_remote_line_actions,
      leadingIcon: FushiIcons.subtitles,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: FushiDesignTokens.of(context).surfaces.search,
              borderRadius: FushiM3eShape.cardRadius,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(line.text, style: theme.textTheme.titleMedium),
                  if (secondary != null && secondary.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        secondary,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FushiButtonGroup(
            expanded: true,
            children: <Widget>[
              if (onReplay != null)
                action(
                  FushiIcons.replay,
                  t.video_remote_control_replay,
                  onReplay!,
                ),
              if (onToggleFavorite != null)
                action(
                  line.favorited
                      ? FushiIcons.filled(FushiIcons.star)
                      : FushiIcons.star,
                  line.favorited
                      ? t.video_remote_control_unfavorite
                      : t.video_remote_control_favorite,
                  onToggleFavorite!,
                ),
              if (onMine != null)
                action(
                  FushiIcons.ankiCard,
                  t.video_remote_control_mine,
                  onMine!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
