import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/video_chrome_colors.dart';
import 'package:fushi/src/media/video/video_episode_rail.dart';

export 'package:fushi/src/media/video/video_episode_rail.dart'
    show VideoEpisodeEntry, VideoEpisodeRail;

/// 视频播放列表的底部剧集轨道。
///
/// 不使用 modal sheet，也不再把画面挤成窄栏；面板在视频底部渐显，画面本身就是
/// Jellyfin 式背景。字幕跳转列表仍保持 push-aside，二者由页面层互斥。
///
/// 横向卡片的封面、缺图、选中态由共享 [VideoEpisodeRail] 渲染，合集详情页复用同一
/// 组件，保证播放器内外视觉和交互一致。
class VideoEpisodePanel extends StatefulWidget {
  const VideoEpisodePanel({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onTapEpisode,
    required this.onClose,
    required this.colorScheme,
    required this.title,
    required this.emptyHint,
    this.fontSize = 14,
    this.width = double.infinity,
    this.height = 220,
  });

  /// 播放列表各集（有序，标题 + 可选封面）。空列表（单视频）时显示 [emptyHint]
  /// （剧集入口仅在播放列表出现，故正常不会空；空态作防御兜底）。与内部集表示解耦：
  /// 页面层把本地行 / 互联远端行都解析成 [VideoEpisodeEntry] 再传进来。
  final List<VideoEpisodeEntry> episodes;

  /// 当前播放集下标（[episodes] 内）；负 / 越界视为「无当前集」。
  final int currentIndex;

  /// 点某集 → 切到该集（页面层 `_switchEpisode(index, ...)`）。回调入参为集下标。
  final void Function(int index) onTapEpisode;

  /// 头部 × 关闭按钮（页面层 `_closeEpisodeList`，与 Esc / 控制条剧集按钮三路等价）。
  final VoidCallback onClose;

  final ColorScheme colorScheme;
  final String title;

  /// 列表为空时的占位提示。
  final String emptyHint;
  final double fontSize;
  final double width;
  final double height;

  @override
  State<VideoEpisodePanel> createState() => _VideoEpisodePanelState();
}

class _VideoEpisodePanelState extends State<VideoEpisodePanel> {
  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final double minimumHeight = 150 + widget.fontSize * 3;
    final double panelHeight =
        widget.height < minimumHeight ? minimumHeight : widget.height;
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: widget.width,
        height: panelHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                cs.surface.withValues(alpha: 0),
                cs.surface.withValues(alpha: kVideoOverlaySolidAlpha),
              ],
              stops: const <double>[0, 0.38],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildHeader(cs),
              Expanded(
                child:
                    widget.episodes.isEmpty ? _buildEmpty(cs) : _buildRail(cs),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final double iconSize = widget.fontSize + 4;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: 20,
        end: 8,
        top: 12,
        bottom: 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: widget.fontSize + 2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (widget.currentIndex >= 0 &&
                    widget.currentIndex < widget.episodes.length)
                  Text(
                    widget.episodes[widget.currentIndex].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: widget.fontSize - 1,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: Icon(Icons.close, size: iconSize),
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
            fontSize: widget.fontSize,
          ),
        ),
      ),
    );
  }

  Widget _buildRail(ColorScheme cs) {
    final double scale = (widget.fontSize / 14).clamp(0.9, 1.35);
    final double cardWidth = (184 * scale).clamp(160, 232);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: VideoEpisodeRail(
        episodes: widget.episodes,
        currentIndex: widget.currentIndex,
        onTapEpisode: widget.onTapEpisode,
        colorScheme: cs,
        fontSize: widget.fontSize,
        cardWidth: cardWidth,
        padding: const EdgeInsets.symmetric(horizontal: 20),
      ),
    );
  }
}
