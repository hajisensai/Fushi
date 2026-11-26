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

  /// 锚点真值（毫秒）：播放器时钟最近一次**变化**时读到的 [positionMs]。null = 尚未锚定。
  /// 只用来估计「此刻真值大约是多少」（[_smoothPositionMs] 的目标），不直接决定画面位置。
  int? _anchorRawMs;

  /// 锚点帧时间（微秒）：锚定当刻的 [SchedulerBinding.currentFrameTimeStamp]。
  /// 该时钟在生产环境按 vsync 逐帧推进、在 widget 测试里按 `pump(duration)` 推进，
  /// 故插值在测试中确定、不依赖真实墙钟。
  int _anchorFrameUs = 0;

  /// 上一帧的帧时间（微秒），平滑时钟按两帧间隔自由推进。
  int _lastFrameUs = 0;

  /// 平滑时钟（毫秒，带小数）：画面实际用的位置。播放中只进不退。
  double _smoothMs = 0;

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

  /// 真值多久没变就认为播放器其实停了（缓冲 / 卡顿但 isPlaying 仍为真）：目标估计
  /// 最多从锚点外推这么远，平滑时钟随之减速停下，不会在画面冻住时自顾往前跑。
  static const double _maxExtrapolateMs = 600;

  /// 平滑时钟向目标收敛的时间常数（毫秒）。远大于真值采样间隔（~200ms），单次采样的
  /// 抖动被摊平成肉眼不可见的微小变速，而持续漂移仍能在一两秒内追平。
  static const double _convergeTauMs = 800;

  /// 小误差时单帧修正量上限占「本帧应走距离」的比例：速度最多 ±12% 微调，不会顿住。
  static const double _maxSlewRatio = 0.12;

  /// 误差在这个范围内只做限幅微调；超出（中途卡顿 / 恢复）才放开按时间常数快速收敛。
  static const double _slewOnlyErrorMs = 250;

  /// 真值偏离平滑时钟超过这个量视为 seek，直接对齐（唯一允许后退的情形）。
  static const double _snapErrorMs = 1000;

  /// 按帧推进的**平滑、单调**播放位置（毫秒）。
  ///
  /// 播放器时钟（media_kit `state.position`）约 200ms 才更新一次，且每次到达都带不定的
  /// 延迟。修前的做法是真值每变一次就**硬重锚**到真值、再叠「只进不退」钳制：真值比外推
  /// 落后时钳制让弹幕原地停住，领先时一下跳过去——每 200ms 一顿一跳，就是「一卡一卡地
  /// 抽动前进」。
  ///
  /// 现在画面位置由一根自由运行的时钟给出：每帧按「帧间隔 × 速率」前进，只把它与真值
  /// 估计（锚点真值 + 自锚点起的外推）的误差**慢慢**揉进去（限幅微调速度），真值采样
  /// 本身不再直接出现在画面上。seek（误差 > 1s）才一次性对齐；暂停冻结当前位置。
  int _smoothPositionMs() {
    final int raw = widget.positionMs();
    final int frameUs =
        SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds;
    final bool playing = widget.isPlaying?.call() ?? true;
    final double speed = widget.speed?.call() ?? 1.0;

    if (_anchorRawMs == null) {
      _anchorRawMs = raw;
      _anchorFrameUs = frameUs;
      _lastFrameUs = frameUs;
      _smoothMs = raw.toDouble();
      return raw;
    }

    final double dtMs = (frameUs - _lastFrameUs).clamp(0, 1 << 31) / 1000.0;
    _lastFrameUs = frameUs;
    if (raw != _anchorRawMs) {
      _anchorRawMs = raw;
      _anchorFrameUs = frameUs;
    }

    if (!playing) {
      // 锚点帧时间跟着挪到当下：恢复播放时外推从零算起，不把暂停时长当成落后。
      _anchorFrameUs = frameUs;
      // 暂停时真值就是画面帧；只有它明显挪动（暂停中 seek / 逐帧）才跟过去。
      if ((raw - _smoothMs).abs() > _snapErrorMs) _smoothMs = raw.toDouble();
      return _smoothMs.round();
    }

    final double sinceAnchorMs = ((frameUs - _anchorFrameUs) / 1000.0).clamp(
      0.0,
      _maxExtrapolateMs,
    );
    final double target = _anchorRawMs! + sinceAnchorMs * speed;
    final double predicted = _smoothMs + dtMs * speed;
    final double error = target - predicted;

    if (error.abs() > _snapErrorMs) {
      _smoothMs = target;
      return _smoothMs.round();
    }

    double correction = error * (dtMs / _convergeTauMs).clamp(0.0, 1.0);
    if (error.abs() <= _slewOnlyErrorMs) {
      final double limit = dtMs * speed.abs() * _maxSlewRatio;
      correction = correction.clamp(-limit, limit);
    }
    final double next = predicted + correction;
    // 只进不退：退出边缘不来回穿越活动 / 淡出阈值。
    if (next > _smoothMs) _smoothMs = next;
    return _smoothMs.round();
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
