import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 横向剧集轨道的一条展示数据。
///
/// 页面层负责把本地 / 互联数据解析成统一的 [ImageProvider]；轨道只负责展示，
/// 不知道文件路径、URL 或缓存细节。
class VideoEpisodeEntry {
  const VideoEpisodeEntry({
    required this.title,
    this.cover,
    this.completed = false,
    this.started = false,
  });

  final String title;
  final ImageProvider? cover;
  final bool completed;
  final bool started;
}

/// Jellyfin 式横向剧集轨道：16:9 画面卡、集号、标题与当前集状态共用一条视觉轴。
///
/// 播放器和合集详情页共用本组件，避免两处再次分叉成不同的封面、选中态和缺图逻辑。
class VideoEpisodeRail extends StatefulWidget {
  const VideoEpisodeRail({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onTapEpisode,
    required this.colorScheme,
    this.fontSize = 14,
    this.cardWidth = 184,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  final List<VideoEpisodeEntry> episodes;
  final int currentIndex;
  final ValueChanged<int> onTapEpisode;
  final ColorScheme colorScheme;
  final double fontSize;
  final double cardWidth;
  final EdgeInsetsGeometry padding;

  @override
  State<VideoEpisodeRail> createState() => _VideoEpisodeRailState();
}

class _VideoEpisodeRailState extends State<VideoEpisodeRail> {
  static const double _gap = 12;
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void didUpdateWidget(covariant VideoEpisodeRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex ||
        oldWidget.episodes.length != widget.episodes.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _revealCurrent() {
    if (!mounted ||
        !_controller.hasClients ||
        widget.currentIndex < 0 ||
        widget.currentIndex >= widget.episodes.length) {
      return;
    }
    final ScrollPosition position = _controller.position;
    final double itemExtent = widget.cardWidth + _gap;
    final double target =
        (widget.currentIndex * itemExtent - position.viewportDimension * 0.18)
            .clamp(0.0, position.maxScrollExtent);
    if ((position.pixels - target).abs() < 1) return;
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final double cardHeight = widget.cardWidth * 9 / 16;
    return SizedBox(
      height: cardHeight,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        itemCount: widget.episodes.length,
        separatorBuilder: (_, __) => const SizedBox(width: _gap),
        itemBuilder: (BuildContext context, int index) => _EpisodeRailCard(
          key: ValueKey<String>('video-episode-card-$index'),
          entry: widget.episodes[index],
          index: index,
          selected: index == widget.currentIndex,
          width: widget.cardWidth,
          fontSize: widget.fontSize,
          colorScheme: widget.colorScheme,
          onTap: () => widget.onTapEpisode(index),
        ),
      ),
    );
  }
}

class _EpisodeRailCard extends StatelessWidget {
  const _EpisodeRailCard({
    super.key,
    required this.entry,
    required this.index,
    required this.selected,
    required this.width,
    required this.fontSize,
    required this.colorScheme,
    required this.onTap,
  });

  final VideoEpisodeEntry entry;
  final int index;
  final bool selected;
  final double width;
  final double fontSize;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const BorderRadius radius = HibikiBorderRadius.card;
    final Color borderColor =
        selected ? colorScheme.primary : Colors.white.withValues(alpha: 0.14);
    return Semantics(
      button: true,
      selected: selected,
      label: '${index + 1}. ${entry.title}',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: width,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: borderColor,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? <BoxShadow>[
                  BoxShadow(
                    color: colorScheme.primary.withValues(alpha: 0.24),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: colorScheme.surfaceContainerHighest,
          child: InkWell(
            canRequestFocus: true,
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _EpisodeCover(entry: entry, colorScheme: colorScheme),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: <double>[0.35, 1],
                      colors: <Color>[Colors.transparent, Color(0xE6000000)],
                    ),
                  ),
                ),
                PositionedDirectional(
                  start: 10,
                  end: 10,
                  bottom: 9,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      if (selected)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: fontSize + 5,
                            color: Colors.white,
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 7),
                          child: Text(
                            '${index + 1}'.padLeft(2, '0'),
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.88),
                              fontSize: fontSize,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: fontSize,
                            height: 1.15,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (entry.completed || entry.started)
                  PositionedDirectional(
                    top: 8,
                    end: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xB8000000),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Icon(
                        entry.completed
                            ? Icons.check_rounded
                            : Icons.play_arrow_rounded,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeCover extends StatelessWidget {
  const _EpisodeCover({required this.entry, required this.colorScheme});

  final VideoEpisodeEntry entry;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? cover = entry.cover;
    if (cover == null) return _placeholder();
    return Image(
      image: cover,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() => ColoredBox(
        color: colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.movie_outlined,
            size: 30,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
