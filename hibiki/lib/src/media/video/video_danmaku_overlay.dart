import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:hibiki/src/media/video/video_danmaku_layout.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';

class VideoDanmakuOverlay extends StatefulWidget {
  const VideoDanmakuOverlay({
    required this.items,
    required this.enabled,
    required this.maxActive,
    required this.positionMs,
    this.isPlaying,
    this.speed,
    this.maxLanes = kDefaultVideoDanmakuMaxLanes,
    this.style = VideoDanmakuStyle.defaults,
    super.key,
  });

  final List<VideoDanmakuItem> items;
  final bool enabled;
  final int maxActive;
  final int maxLanes;

  /// 播放器时钟（毫秒）。真值来自 media_kit `state.position`，**约每 200ms 才更新
  /// 一次**；overlay 每帧读取会读到同一陈旧值，故内部按帧插值（见 [_smoothPositionMs]）
  /// 平滑弹幕运动，避免「刷新率太低」的跳格观感。
  final int Function() positionMs;

  /// 是否正在播放（可选）。为空视为一直播放。暂停时插值冻结在 [positionMs] 真值，
  /// 不再外推，避免暂停后弹幕继续漂移。
  final bool Function()? isPlaying;

  /// 播放速率（可选，默认 1.0）。长按倍速等场景下按帧外推需按此缩放，保持同步。
  final double Function()? speed;

  /// TODO-1376：字号/不透明度/速度/显示区域样式（即改即生效，源自全局偏好）。
  final VideoDanmakuStyle style;

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

  /// 平滑播放时钟（毫秒）。null = 尚未锚定（下一帧用真值锚定）。
  int? _smoothMs;

  /// 上一帧的 [SchedulerBinding.currentFrameTimeStamp]（毫秒），用于求帧间隔。
  /// 该时钟在生产环境按 vsync 逐帧推进、在 widget 测试里按 `pump(duration)` 推进，
  /// 故插值在测试中确定、不依赖真实墙钟。
  int _lastFrameMs = 0;

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
    } else {
      if (_ticker.isAnimating) _ticker.stop(canceled: false);
      // 不在动画时丢弃锚点：下次开启（换视频/重新开弹幕）从真值重新锚定，
      // 不把上个视频的陈旧平滑时钟带过来。
      _smoothMs = null;
    }
  }

  /// 按帧插值出的平滑播放位置（毫秒），消除 media_kit `state.position` ~200ms 才更新
  /// 一次导致的弹幕跳格。
  ///
  /// 每帧按真实帧间隔 × 速率推进内部时钟；对播放器真值做**软校正**（小漂移每帧拉近
  /// 15%，避免可见回跳），漂移过大（seek / 大失步）直接吸附真值；暂停时冻结在真值。
  int _smoothPositionMs() {
    final int raw = widget.positionMs();
    final int frameMs =
        SchedulerBinding.instance.currentFrameTimeStamp.inMilliseconds;
    final bool playing = widget.isPlaying?.call() ?? true;
    final double speed = widget.speed?.call() ?? 1.0;

    if (_smoothMs == null) {
      _smoothMs = raw;
      _lastFrameMs = frameMs;
      return raw;
    }
    final int dtMs = frameMs - _lastFrameMs;
    _lastFrameMs = frameMs;

    if (!playing || dtMs <= 0) {
      // 暂停 / 无时间推进：钉在真值，避免外推。
      _smoothMs = raw;
      return raw;
    }

    int next = _smoothMs! + (dtMs * speed).round();
    final int drift = raw - next;
    if (drift.abs() > 400) {
      next = raw; // seek 或大失步（后台丢帧）→ 直接对齐真值。
    } else {
      next += (drift * 0.15).round(); // 小漂移软校正，肉眼无回跳。
    }
    if (next < 0) next = 0;
    _smoothMs = next;
    return next;
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
    final VideoDanmakuStyle style = widget.style;
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
                positionMs: _smoothPositionMs(),
                viewportSize: constraints.biggest,
                maxActive: widget.maxActive,
                maxLanes: widget.maxLanes,
                scrollDuration: style.scrollDuration,
                fixedDuration: style.fixedDuration,
                fontScale: style.fontScale,
                areaFraction: style.areaFraction,
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
                        opacity: (entry.opacity * style.opacity)
                            .clamp(0.0, 1.0)
                            .toDouble(),
                        child: _DanmakuText(
                          entry: entry,
                          fontScale: style.fontScale,
                        ),
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
  const _DanmakuText({required this.entry, required this.fontScale});

  final VideoDanmakuLayoutEntry entry;
  final double fontScale;

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
          fontSize: 20 * fontScale,
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
