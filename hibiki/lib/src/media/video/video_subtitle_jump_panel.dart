import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
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

/// 视频字幕跳转列表面板（asbplayer / YouTube transcript 式）。
///
/// 右侧竖直滚动列表，逐句显示「时间戳 + 字幕文本」；点某句 → 调 [onTapCue]，由上层
/// `controller.skipToCue(cue)` 把画面 seek 到该句起点。监听 [controller]（每 125ms
/// tick 经 `notifyListeners` 更新 `currentCueIndex`）以高亮当前播放句并自动滚到可见。
///
/// 设计约束：
/// - **只读** [VideoPlayerController.cues] / [VideoPlayerController.currentCueIndex]，
///   不触碰字幕 overlay 渲染逻辑，也不直接调播放器（seek 由 [onTapCue] 上层统一发，
///   便于单测注入）。
/// - 窗口/全屏共用（被挂在 media_kit controls builder 的 Stack 内）；颜色/字号由上层
///   传入，跟随视频 chrome 主题与 appUiScale。
class VideoSubtitleJumpPanel extends StatefulWidget {
  const VideoSubtitleJumpPanel({
    super.key,
    required this.controller,
    required this.onTapCue,
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

  /// 关闭面板的回调（点标题栏关闭按钮触发）。
  final VoidCallback onClose;

  /// 面板配色（跟随视频 chrome 主题，深/浅一致）。
  final ColorScheme colorScheme;

  /// 标题栏文案。
  final String title;

  /// 无字幕时的空态文案。
  final String emptyHint;

  /// 列表文本字号（跟随 appUiScale，由上层换算）。
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

  /// 单行项的估算高度（[ListView.builder] 用，自动滚动定位也按它算偏移）。
  static const double _itemExtent = 56;

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

  /// 当前播放句变化时把它滚到可视区中段；同一句只滚一次。
  void _scrollToCurrentCueIfNeeded() {
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
                          _buildRow(cs, cues[i], i == currentIndex),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 8, bottom: 8),
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
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonLabel,
            icon: Icon(Icons.close, size: widget.fontSize + 6),
            color: cs.onSurfaceVariant,
            onPressed: widget.onClose,
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
            fontSize: widget.fontSize,
          ),
        ),
      ),
    );
  }

  Widget _buildRow(ColorScheme cs, AudioCue cue, bool selected) {
    final Color bg = selected ? cs.primaryContainer : Colors.transparent;
    final Color tsColor =
        selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    final Color textColor = selected ? cs.onPrimaryContainer : cs.onSurface;
    return InkWell(
      onTap: () => widget.onTapCue(cue),
      child: Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 52,
              child: Text(
                formatCueTimestamp(cue.startMs),
                style: TextStyle(
                  color: tsColor,
                  fontSize: widget.fontSize - 1,
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
                  fontSize: widget.fontSize,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
