import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 把 cue 起始毫秒格式化成跳转列表里显示的时间戳。
///
/// 1 小时内输出 `m:ss`（如 `3:07`），1 小时及以上输出 `h:mm:ss`（如 `1:02:09`）。
/// 负数 clamp 到 0（理论上 cue 起点不为负，防御性处理）。纯函数，是列表渲染与单测的
/// 共享真相源。
String formatCueTimestamp(int startMs) {
  final int total = startMs < 0 ? 0 : startMs ~/ 1000;
  final int hours = total ~/ 3600;
  final int minutes = (total % 3600) ~/ 60;
  final int seconds = total % 60;
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final String mm = minutes.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '$minutes:$ss';
}

/// 列表本地字号在基准字号上的步进档位（asbplayer 头部 A-/A+，瞬态、不落盘）。
/// 三档：紧凑 / 默认 / 宽松。
const List<double> _kFontScaleSteps = <double>[0.85, 1.0, 1.15, 1.3];

/// 视频字幕跳转列表面板（asbplayer / YouTube transcript 式）。
///
/// 右侧竖直滚动列表，逐句显示「时间戳 + 字幕文本」；点某句 → 调 [onTapCue]，由上层
/// `controller.skipToCue(cue)` 把画面 seek 到该句起点。监听 [controller]（每 125ms
/// tick 经 `notifyListeners` 更新 `currentCueIndex`）以高亮当前播放句并自动滚到可见。
///
/// 交互精致度（TODO-152 子A，参考 asbplayer transcript 面板）：
/// - **头部工具栏**：字号 A-/A+ 步进（本地瞬态，调列表可读性）+ 自动滚动开关
///   （关闭后当前句变化不再强制滚动，便于用户手动回看历史句）。
/// - **行内操作**：hover（桌面）/ 选中（当前句）行显示「跳转 / 复制 / 收藏」三枚小按钮；
///   复制把该句文本写剪贴板，收藏 toggle 该句到收藏夹。其余行 hover 时整行浅色高亮。
/// - 不做「副字幕 / 双语行」：[AudioCue] 数据结构只有单条 `text`，无第二字幕轨数据源，
///   强行加列只会显示空行（诚实地不提供该开关）。
/// - 不在行内放「制卡」：视频制卡需最近一次词典查词的词条字段（term/reading/glossary），
///   列表里任意句没有词条上下文，制卡语义混乱（与 asbplayer 一致：列表只 copy/定位，
///   制卡走查词浮层 + 跨字幕录制）。
///
/// 设计约束：
/// - **只读** [VideoPlayerController.cues] / [VideoPlayerController.currentCueIndex]，
///   不触碰字幕 overlay 渲染逻辑，也不直接调播放器（seek / 复制 / 收藏都由回调上层统一
///   发，便于单测注入）。
/// - 窗口/全屏共用（被挂在 media_kit controls builder 的 Stack 内）；颜色/字号由上层
///   传入，跟随视频 chrome 主题与 appUiScale。
class VideoSubtitleJumpPanel extends StatefulWidget {
  const VideoSubtitleJumpPanel({
    super.key,
    required this.controller,
    required this.onTapCue,
    required this.onCopyCue,
    required this.onFavoriteCue,
    required this.isCueFavorited,
    required this.onClose,
    required this.colorScheme,
    required this.title,
    required this.emptyHint,
    this.fontSize = 14,
    this.width = 320,
  });

  final VideoPlayerController controller;

  /// 点某句 cue 的回调（上层据此 `skipToCue` + 唤醒控制条）。
  final void Function(AudioCue cue) onTapCue;

  /// 复制某句文本的回调（上层写剪贴板 + toast）。
  final void Function(AudioCue cue) onCopyCue;

  /// 收藏 / 取消收藏某句的回调（上层 toggle 收藏夹 + setState）。异步：上层完成后
  /// 自身经 controller `notifyListeners` 或 setState 触发本面板重建以刷新星标。
  final Future<void> Function(AudioCue cue) onFavoriteCue;

  /// 查询某句是否已收藏（决定星标实心 / 空心）。纯查询，每次重建调用。
  final bool Function(AudioCue cue) isCueFavorited;

  /// 关闭面板的回调（点标题栏关闭按钮触发）。
  final VoidCallback onClose;

  /// 面板配色（跟随视频 chrome 主题，深/浅一致）。
  final ColorScheme colorScheme;

  /// 标题栏文案。
  final String title;

  /// 无字幕时的空态文案。
  final String emptyHint;

  /// 列表文本基准字号（跟随 appUiScale，由上层换算）。头部 A-/A+ 在此基准上再乘本地
  /// 步进系数 [_kFontScaleSteps]。
  final double fontSize;

  /// 面板宽度（横屏视频右侧占比，由上层按界面宽换算）。
  final double width;

  @override
  State<VideoSubtitleJumpPanel> createState() => _VideoSubtitleJumpPanelState();
}

class _VideoSubtitleJumpPanelState extends State<VideoSubtitleJumpPanel> {
  final ScrollController _scrollController = ScrollController();

  /// 上次自动滚动对齐到的当前句下标；避免每帧重复滚动。
  int _lastScrolledIndex = -1;

  /// 当前 hover 的行下标（桌面鼠标悬浮），-1 = 无。决定行高亮 + 行内按钮显隐。
  int _hoveredIndex = -1;

  /// 自动滚动开关（asbplayer 式）：开=当前句变化时滚到可视中段；关=不动，便于回看。
  bool _autoScroll = true;

  /// 本地字号步进档位下标（[_kFontScaleSteps]），默认 1.0 那档。
  int _fontScaleIndex = 1;

  /// 单行项的估算高度（[ListView.builder] 用，自动滚动定位也按它算偏移）。
  /// 随本地字号档位线性放大，保证自动滚动偏移与实际行高一致。
  double get _itemExtent => 56 * _fontScaleSteps;

  double get _fontScaleSteps => _kFontScaleSteps[_fontScaleIndex];

  /// 当前生效行字号（基准 × 本地步进）。
  double get _effectiveFontSize => widget.fontSize * _fontScaleSteps;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(_scrollToCurrentCueIfNeeded);
  }

  /// 当前播放句变化时把它滚到可视区中段；同一句只滚一次。自动滚动关闭时不滚（用户
  /// 在手动回看历史句，强行滚回当前句会打断浏览）。
  void _scrollToCurrentCueIfNeeded() {
    if (!_autoScroll) return;
    final int index = widget.controller.currentCueIndex;
    if (index < 0 || index == _lastScrolledIndex) return;
    if (!_scrollController.hasClients) return;
    _lastScrolledIndex = index;
    final double viewport = _scrollController.position.viewportDimension;
    final double target = (index * _itemExtent) - (viewport / 2) + _itemExtent;
    final double clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  /// 重新打开自动滚动时立即把当前句滚回可视区（给「跟回去」的即时反馈）。
  void _toggleAutoScroll() {
    setState(() {
      _autoScroll = !_autoScroll;
      if (_autoScroll) _lastScrolledIndex = -1; // 强制下次 tick 重新对齐
    });
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_scrollToCurrentCueIfNeeded);
      });
    }
  }

  void _stepFont(int delta) {
    final int next =
        (_fontScaleIndex + delta).clamp(0, _kFontScaleSteps.length - 1);
    if (next == _fontScaleIndex) return;
    setState(() {
      _fontScaleIndex = next;
      _lastScrolledIndex = -1; // 行高变了，重算自动滚动偏移
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final List<AudioCue> cues = widget.controller.cues;
    final int currentIndex = widget.controller.currentCueIndex;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: widget.width,
        color: cs.surface.withValues(alpha: 0.92),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(cs),
            const Divider(height: 1),
            Expanded(
              child: cues.isEmpty
                  ? _buildEmpty(cs)
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: cues.length,
                      itemExtent: _itemExtent,
                      itemBuilder: (BuildContext _, int i) =>
                          _buildRow(cs, cues[i], i, i == currentIndex),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final double iconSize = widget.fontSize + 4;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: widget.fontSize + 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // 字号 A- / A+（本地瞬态调列表可读性）。
          IconButton(
            tooltip: t.video_subtitle_list_font_smaller,
            icon: Icon(Icons.text_decrease, size: iconSize),
            color: _fontScaleIndex > 0 ? cs.onSurfaceVariant : cs.outline,
            onPressed: _fontScaleIndex > 0 ? () => _stepFont(-1) : null,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: t.video_subtitle_list_font_larger,
            icon: Icon(Icons.text_increase, size: iconSize),
            color: _fontScaleIndex < _kFontScaleSteps.length - 1
                ? cs.onSurfaceVariant
                : cs.outline,
            onPressed: _fontScaleIndex < _kFontScaleSteps.length - 1
                ? () => _stepFont(1)
                : null,
            visualDensity: VisualDensity.compact,
          ),
          // 自动滚动开关：实心=开（跟随当前句）/ 空心=关（停留手动浏览）。
          IconButton(
            tooltip: t.video_subtitle_list_auto_scroll,
            icon: Icon(
              _autoScroll
                  ? Icons.vertical_align_center
                  : Icons.pause_circle_outline,
              size: iconSize,
            ),
            color: _autoScroll ? cs.primary : cs.onSurfaceVariant,
            onPressed: _toggleAutoScroll,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonLabel,
            icon: Icon(Icons.close, size: iconSize + 2),
            color: cs.onSurfaceVariant,
            onPressed: widget.onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          widget.emptyHint,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: _effectiveFontSize,
          ),
        ),
      ),
    );
  }

  Widget _buildRow(ColorScheme cs, AudioCue cue, int index, bool selected) {
    final bool hovered = index == _hoveredIndex;
    // 行底色：选中 > hover > 透明（hover 用 surfaceVariant 浅高亮，与选中 primaryContainer 区分）。
    final Color bg = selected
        ? cs.primaryContainer
        : (hovered ? cs.onSurface.withValues(alpha: 0.06) : Colors.transparent);
    final Color tsColor =
        selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    final Color textColor = selected ? cs.onPrimaryContainer : cs.onSurface;
    // 行内操作按钮仅在 hover（桌面）或选中（当前句）时显示，避免每行常驻挤占文本。
    final bool showActions = hovered || selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) {
        if (_hoveredIndex == index) setState(() => _hoveredIndex = -1);
      },
      child: InkWell(
        onTap: () => widget.onTapCue(cue),
        child: Container(
          color: bg,
          padding: const EdgeInsets.only(left: 16, right: 4, top: 8, bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 52,
                child: Text(
                  formatCueTimestamp(cue.startMs),
                  style: TextStyle(
                    color: tsColor,
                    fontSize: _effectiveFontSize - 1,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cue.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: _effectiveFontSize,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    height: 1.25,
                  ),
                ),
              ),
              if (showActions) _buildRowActions(cs, cue, selected),
            ],
          ),
        ),
      ),
    );
  }

  /// 行内操作按钮（跳转 / 复制 / 收藏）。仅 hover / 选中行渲染。
  Widget _buildRowActions(ColorScheme cs, AudioCue cue, bool selected) {
    final Color iconColor =
        selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    final bool favorited = widget.isCueFavorited(cue);
    final double iconSize = _effectiveFontSize + 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RowActionButton(
          icon: Icons.play_arrow,
          tooltip: t.video_subtitle_list_jump,
          color: iconColor,
          size: iconSize,
          onPressed: () => widget.onTapCue(cue),
        ),
        _RowActionButton(
          icon: Icons.content_copy_outlined,
          tooltip: t.copy,
          color: iconColor,
          size: iconSize,
          onPressed: () => widget.onCopyCue(cue),
        ),
        _RowActionButton(
          icon: favorited ? Icons.star : Icons.star_border,
          tooltip: t.collection_sentence,
          color: favorited ? cs.primary : iconColor,
          size: iconSize,
          onPressed: () => widget.onFavoriteCue(cue),
        ),
      ],
    );
  }
}

/// 行内紧凑操作按钮（比 [IconButton] 更小的命中区，适配窄列）。
class _RowActionButton extends StatelessWidget {
  const _RowActionButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: size,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
