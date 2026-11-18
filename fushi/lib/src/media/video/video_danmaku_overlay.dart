import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import 'package:fushi/src/media/video/video_danmaku_layout.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_danmaku_text_metrics.dart';

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

  /// 锚点真值（毫秒）：最近一次对齐播放器时钟时的 [positionMs] 值。null = 尚未锚定。
  int? _anchorRawMs;

  /// 锚点帧时间（毫秒）：锚定当刻的 [SchedulerBinding.currentFrameTimeStamp]。
  /// 该时钟在生产环境按 vsync 逐帧推进、在 widget 测试里按 `pump(duration)` 推进，
  /// 故插值在测试中确定、不依赖真实墙钟。
  int _anchorFrameMs = 0;

  /// 上一帧返回的平滑位置（毫秒），用于**只进不退**单调钳制，消除退出边缘的来回跳动。
  int _lastSmoothMs = 0;

  /// 布局器**按播放会话长期持有**：行号分配记在它内部并跨帧延续，一条弹幕退场时
  /// 其余弹幕才不会跟着换行。每帧新建实例就丢掉这份记忆，重排立刻回来。
  final VideoDanmakuLayout _layout = VideoDanmakuLayout();

  /// 在场弹幕的文本子树（按 [VideoDanmakuLayoutEntry.index]），见 [_buildEntries]。
  /// 下标只在同一份 [VideoDanmakuOverlay.items] 内有意义，换列表或字号即整体作废。
  final Map<int, Widget> _texts = <int, Widget>{};
  List<VideoDanmakuItem>? _textsItems;
  double? _textsFontScale;

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
      _anchorRawMs = null;
      _texts.clear();
    }
  }

  /// 按帧插值出的**单调**平滑播放位置（毫秒），消除 media_kit `state.position`
  /// ~200ms 才更新一次导致的弹幕跳格，且**播放中只进不退**——避免退出边缘（progress
  /// 逼近 1）来回穿越活动/淡出阈值造成的「来回跳动 + 忽隐忽现」。
  ///
  /// 锚点法：以最近的真值为地面真相，从锚点按 帧时间 × 速率外推；真值每前进一格就
  /// 重锚（当前时刻真相），故外推不会越跑越远。外推结果对上一帧做单调钳制（不得后退）；
  /// 真值大跳（seek）时才允许一次性对齐（含后退）；暂停时冻结当前平滑值。
  int _smoothPositionMs() {
    final int raw = widget.positionMs();
    final int frameMs =
        SchedulerBinding.instance.currentFrameTimeStamp.inMilliseconds;
    final bool playing = widget.isPlaying?.call() ?? true;
    final double speed = widget.speed?.call() ?? 1.0;

    // 首帧 / seek（真值大跳，前进或后退）：以真值重锚并直接对齐（允许后退，仅此一次）。
    if (_anchorRawMs == null || (raw - _anchorRawMs!).abs() > 1000) {
      _anchorRawMs = raw;
      _anchorFrameMs = frameMs;
      _lastSmoothMs = raw;
      return raw;
    }

    // 暂停：冻结在上一帧平滑值（不外推），锚点挪到当下使恢复播放时无跳变。
    if (!playing) {
      _anchorRawMs = raw;
      _anchorFrameMs = frameMs;
      return _lastSmoothMs;
    }

    // 真值前进了一格（media_kit ~200ms 一次）→ 用最新真值重锚（当前时刻的地面真相）。
    if (raw != _anchorRawMs) {
      _anchorRawMs = raw;
      _anchorFrameMs = frameMs;
    }

    // 从锚点按 帧时间 × 速率外推，再做只进不退单调钳制。
    int next = _anchorRawMs! + ((frameMs - _anchorFrameMs) * speed).round();
    if (next < _lastSmoothMs) next = _lastSmoothMs;
    _lastSmoothMs = next;
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
      // 整层自成重绘边界：弹幕每帧都在动，不能连带同一画面上的控制条、遮布、字幕等
      // 兄弟节点每帧一起重录（BUG-4852）。
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _ticker,
          builder: (BuildContext context, _) {
            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final VideoDanmakuLayoutSnapshot snapshot = _layout.layout(
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
                if (snapshot.entries.isEmpty) {
                  _texts.clear();
                  return const SizedBox.expand();
                }
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: _buildEntries(snapshot.entries, style),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// 每条弹幕：位置与透明度每帧变，留在边界**外**；文本自成重绘边界，录好的 picture
  /// 从出生到退场原样复用，每帧只换图层偏移。（`RenderOpacity` 在可见时本身也是重绘
  /// 边界，这里显式包一层，让这条性质不依赖透明度取值。）
  ///
  /// 文本 picture 重录的代价不只是 Dart 侧 paint：引擎每次 paint 段落都新建
  /// TextFrame，Impeller 的模糊文字（阴影）缓存以 TextFrame 为键，重录就意味着这条
  /// 弹幕的两层模糊阴影要重做离屏模糊。
  ///
  /// key 用弹幕在列表里的下标（[VideoDanmakuLayoutEntry.index]）。修前按位置对位：
  /// 队首一出列，后面每个 element 都被错配成下一条的文本、重新排版重画——同屏七十多条、
  /// 每秒出列近十条时，几乎每帧都在整屏重做阴影，raster 一帧数百毫秒（BUG-4852）。
  List<Widget> _buildEntries(
    List<VideoDanmakuLayoutEntry> entries,
    VideoDanmakuStyle style,
  ) {
    if (!identical(_textsItems, widget.items) ||
        _textsFontScale != style.fontScale) {
      _texts.clear();
      _textsItems = widget.items;
      _textsFontScale = style.fontScale;
    }
    final Set<int> live = <int>{};
    final List<Widget> children = <Widget>[];
    for (final VideoDanmakuLayoutEntry entry in entries) {
      live.add(entry.index);
      children.add(
        Positioned(
          key: ValueKey<int>(entry.index),
          left: entry.position.dx,
          top: entry.position.dy,
          child: Opacity(
            opacity: (entry.opacity * style.opacity).clamp(0.0, 1.0).toDouble(),
            // 同一条弹幕复用同一个 widget 实例：element 见到同一实例直接跳过整棵
            // 文本子树的重建与比较。
            child: _texts.putIfAbsent(
              entry.index,
              () => RepaintBoundary(
                child: _DanmakuText(
                  item: entry.item,
                  fontScale: style.fontScale,
                ),
              ),
            ),
          ),
        ),
      );
    }
    _texts.removeWhere((int index, Widget _) => !live.contains(index));
    return children;
  }
}

class _DanmakuText extends StatelessWidget {
  const _DanmakuText({required this.item, required this.fontScale});

  final VideoDanmakuItem item;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    final bool fixed = item.mode != VideoDanmakuMode.scroll;
    return FractionalTranslation(
      translation: fixed ? const Offset(-0.5, 0) : Offset.zero,
      child: Text(
        item.text,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
        // 与 VideoDanmakuTextMetrics 的测量条件保持逐项一致：字号由弹幕自己的
        // fontScale 偏好决定，不再叠加系统字体缩放——否则实际渲染比测量宽，
        // 弹幕会在还没滑出视口时被判过期而突然消失。
        textScaler: TextScaler.noScaling,
        style: videoDanmakuTextStyle(
          color: Color(item.colorArgb),
          fontScale: fontScale,
        ),
      ),
    );
  }
}
