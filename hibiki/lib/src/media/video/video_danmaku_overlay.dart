import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_danmaku_layout.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';

class VideoDanmakuOverlay extends StatefulWidget {
  const VideoDanmakuOverlay({
    required this.items,
    required this.enabled,
    required this.maxActive,
    required this.positionMs,
    this.maxLanes = kDefaultVideoDanmakuMaxLanes,
    super.key,
  });

  final List<VideoDanmakuItem> items;
  final bool enabled;
  final int maxActive;
  final int maxLanes;
  final int Function() positionMs;

  @override
  State<VideoDanmakuOverlay> createState() => _VideoDanmakuOverlayState();
}

class _VideoDanmakuOverlayState extends State<VideoDanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(days: 1),
  );

  bool get _shouldTick => widget.enabled && widget.items.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(VideoDanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _syncTicker() {
    if (_shouldTick) {
      if (!_ticker.isAnimating) _ticker.repeat();
    } else if (_ticker.isAnimating) {
      _ticker.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldTick) {
      return const IgnorePointer(
        key: Key('video-danmaku-ignore-pointer'),
        ignoring: true,
        child: SizedBox.expand(),
      );
    }
    return IgnorePointer(
      key: const Key('video-danmaku-ignore-pointer'),
      ignoring: true,
      child: AnimatedBuilder(
        animation: _ticker,
        builder: (BuildContext context, _) {
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final VideoDanmakuLayoutSnapshot snapshot =
                  VideoDanmakuLayout.layout(
                items: widget.items,
                positionMs: widget.positionMs(),
                viewportSize: constraints.biggest,
                maxActive: widget.maxActive,
                maxLanes: widget.maxLanes,
              );
              if (snapshot.entries.isEmpty) return const SizedBox.expand();
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: <Widget>[
                  for (final VideoDanmakuLayoutEntry entry in snapshot.entries)
                    Positioned(
                      left: entry.position.dx,
                      top: entry.position.dy,
                      child: Opacity(
                        opacity: entry.opacity,
                        child: _DanmakuText(entry: entry),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _DanmakuText extends StatelessWidget {
  const _DanmakuText({required this.entry});

  final VideoDanmakuLayoutEntry entry;

  @override
  Widget build(BuildContext context) {
    final bool fixed = entry.item.mode != VideoDanmakuMode.scroll;
    return FractionalTranslation(
      translation: fixed ? const Offset(-0.5, 0) : Offset.zero,
      child: Text(
        entry.item.text,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
        style: TextStyle(
          color: Color(entry.item.colorArgb),
          fontSize: 20,
          fontWeight: FontWeight.w700,
          shadows: const <Shadow>[
            Shadow(
              color: Colors.black,
              blurRadius: 3,
              offset: Offset(1, 1),
            ),
            Shadow(
              color: Colors.black,
              blurRadius: 3,
              offset: Offset(-1, -1),
            ),
          ],
        ),
      ),
    );
  }
}
