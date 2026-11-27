import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart'
    show videoM3eFormatTime;

// 方案 C（Apple 外观）底部控制条的排版件。纯布局 / 文本，与设计系统无关——玻璃由
// 调用方用 `VideoGlassSurface` 垫在背后，本文件不画任何控件外观。

/// 底部条的一行：前导簇 · 已播时间 · 进度条道 · 剩余时间 · 后随簇（macOS 单行条）；
/// 触屏只用前导 / 后随两簇（中间留空）。
///
/// 一次布局分宽、不回读上一帧：先给前导簇（播放 / ±10 / 学习键，比后随簇重要）
/// 足额宽度（只给后随簇留一个按钮位放「⋯」），再把剩下的给后随簇，最后进度条道吃
/// 余量且不小于 [minLaneWidth]。两簇都是 `VideoControlBar(fill: false)`：拿到的宽度
/// 不够时自己按优先级把按钮收进「⋯」，与其它控制条同一判据。
class VideoAppleBarRow extends StatelessWidget {
  const VideoAppleBarRow({
    super.key,
    required this.leading,
    required this.trailing,
    this.elapsed,
    this.lane,
    this.remaining,
    required this.gap,
    required this.minLaneWidth,
    required this.trailingReserve,
  });

  final Widget leading;
  final Widget trailing;

  /// 已播时间；null = 不显示（用户把时间指示器移出了播放器）。
  final Widget? elapsed;

  /// 进度条道；null = 中段留空（触屏：进度条在上一行）。
  final Widget? lane;

  /// 剩余时间。
  final Widget? remaining;

  /// 相邻件之间的间距。
  final double gap;

  /// 进度条道的最小宽度（窄窗下先收后随簇的按钮，不把进度条压没）。
  final double minLaneWidth;

  /// 给后随簇保底的宽度（至少放得下「⋯」）。
  final double trailingReserve;

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(
      delegate: _VideoAppleBarRowDelegate(
        gap: gap,
        minLaneWidth: minLaneWidth,
        trailingReserve: trailingReserve,
        rtl: Directionality.of(context) == TextDirection.rtl,
      ),
      children: <Widget>[
        LayoutId(id: _BarSlot.leading, child: leading),
        if (elapsed != null) LayoutId(id: _BarSlot.elapsed, child: elapsed!),
        if (lane != null) LayoutId(id: _BarSlot.lane, child: lane!),
        if (remaining != null)
          LayoutId(id: _BarSlot.remaining, child: remaining!),
        LayoutId(id: _BarSlot.trailing, child: trailing),
      ],
    );
  }
}

enum _BarSlot { leading, elapsed, lane, remaining, trailing }

class _VideoAppleBarRowDelegate extends MultiChildLayoutDelegate {
  _VideoAppleBarRowDelegate({
    required this.gap,
    required this.minLaneWidth,
    required this.trailingReserve,
    required this.rtl,
  });

  final double gap;
  final double minLaneWidth;
  final double trailingReserve;
  final bool rtl;

  @override
  void performLayout(Size size) {
    final double w = size.width;
    final double h = size.height;
    Size loose(_BarSlot id, double maxWidth) => layoutChild(
      id,
      BoxConstraints(maxWidth: math.max(0, maxWidth), maxHeight: h),
    );

    final Size elapsed = hasChild(_BarSlot.elapsed)
        ? loose(_BarSlot.elapsed, w)
        : Size.zero;
    final Size remaining = hasChild(_BarSlot.remaining)
        ? loose(_BarSlot.remaining, w)
        : Size.zero;
    final bool hasLane = hasChild(_BarSlot.lane);
    final double labels =
        (elapsed.width > 0 ? elapsed.width + gap : 0) +
        (remaining.width > 0 ? remaining.width + gap : 0);
    final double budget = w - labels - minLaneWidth - 2 * gap;
    final Size leading = loose(_BarSlot.leading, budget - trailingReserve);
    final Size trailing = loose(_BarSlot.trailing, budget - leading.width);

    double y(Size s) => (h - s.height) / 2;
    // 从行首（LTR 左 / RTL 右）往行尾排。
    double place(_BarSlot id, Size s, double start) {
      positionChild(id, Offset(rtl ? w - start - s.width : start, y(s)));
      return start + s.width;
    }

    double cursor = place(_BarSlot.leading, leading, 0) + gap;
    if (elapsed.width > 0) {
      cursor = place(_BarSlot.elapsed, elapsed, cursor) + gap;
    }
    final double trailingStart = w - trailing.width;
    place(_BarSlot.trailing, trailing, trailingStart);
    double laneEnd = trailingStart - gap;
    if (remaining.width > 0) {
      final double remStart = laneEnd - remaining.width;
      place(_BarSlot.remaining, remaining, remStart);
      laneEnd = remStart - gap;
    }
    if (hasLane) {
      final double laneWidth = math.max(0, laneEnd - cursor);
      final Size lane = layoutChild(
        _BarSlot.lane,
        BoxConstraints.tightFor(width: laneWidth, height: h),
      );
      place(_BarSlot.lane, lane, cursor);
    }
  }

  @override
  bool shouldRelayout(_VideoAppleBarRowDelegate oldDelegate) =>
      oldDelegate.gap != gap ||
      oldDelegate.minLaneWidth != minLaneWidth ||
      oldDelegate.trailingReserve != trailingReserve ||
      oldDelegate.rtl != rtl;
}

/// 进度条两端的时间（AVKit：左已播、右「−剩余」），等宽数字。
///
/// 接 media_kit [Player] 的位置 / 时长流，只在显示的秒数变化时重建。
class VideoAppleTimeLabel extends StatefulWidget {
  const VideoAppleTimeLabel({
    super.key,
    required this.player,
    required this.style,
    required this.remaining,
  });

  final Player player;
  final TextStyle style;

  /// true = 「−剩余」，false = 已播。
  final bool remaining;

  @override
  State<VideoAppleTimeLabel> createState() => _VideoAppleTimeLabelState();
}

class _VideoAppleTimeLabelState extends State<VideoAppleTimeLabel>
    with StateResourceScope<VideoAppleTimeLabel> {
  late Duration _position = _floor(widget.player.state.position);
  late Duration _duration = widget.player.state.duration;

  static Duration _floor(Duration d) => Duration(seconds: d.inSeconds);

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    ownSubscription(
      widget.player.stream.position.listen((Duration p) {
        final Duration next = _floor(p);
        if (next != _position && mounted) setState(() => _position = next);
      }),
      slot: #position,
    );
    ownSubscription(
      widget.player.stream.duration.listen((Duration d) {
        if (d != _duration && mounted) setState(() => _duration = d);
      }),
      slot: #duration,
    );
  }

  @override
  void didUpdateWidget(VideoAppleTimeLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _position = _floor(widget.player.state.position);
      _duration = widget.player.state.duration;
      _listen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      videoAppleTimeLabelText(
        position: _position,
        duration: _duration,
        remaining: widget.remaining,
      ),
      maxLines: 1,
      softWrap: false,
      style: widget.style,
    );
  }
}

/// 时间标签文本（纯函数）：已播 `05:00`；剩余 `−00:48`（U+2212 减号，AVKit 写法）。
String videoAppleTimeLabelText({
  required Duration position,
  required Duration duration,
  required bool remaining,
}) {
  if (!remaining) return videoM3eFormatTime(position, reference: duration);
  final Duration left = duration > position
      ? duration - position
      : Duration.zero;
  return '−${videoM3eFormatTime(left, reference: duration)}';
}

/// 时间标签最宽可能的宽度（`−00:00:00`），触屏把进度条两端让出这么宽——宽度与
/// 片长无关，进度条轨道（及与之同源的章节刻度层）不随片子跳。
double videoAppleTimeLabelMaxWidth(TextStyle style, TextScaler scaler) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: '−00:00:00', style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width.ceilToDouble();
}
