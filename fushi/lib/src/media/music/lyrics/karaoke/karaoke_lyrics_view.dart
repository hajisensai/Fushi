/// Flutter 原生逐字歌词（设计 §6.1）：`CustomPainter` + 预排版 [KaraokeLineLayout]。
///
/// - 时间：每帧读调用方给的 [FushiPlaybackClock]（已插值），**逐帧不跨 FFI**；
/// - 只有当前行组的画家挂在逐帧通知上（[RepaintBoundary] 隔开），其它行静态；
/// - 滚动：当前行停在视口 [KaraokeLyricsAppearance.anchor] 处，弹簧过去（[FushiSprings]）；
///   拖动进入预览（暂停自动居中、高亮预览行），松手跳到预览行，[kKaraokeResumeAutoScroll]
///   后恢复自动居中；
/// - 减弱动态效果 / 墨水屏（[fushiMotionEnabled]）：不上浮、不辉光、不呼吸、不弹簧，直接跳；
///   高对比度与上述情形下自动关非当前行模糊。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_appearance.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_line_layout.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_progress.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

export 'package:fushi/src/media/music/lyrics/karaoke/karaoke_appearance.dart'
    show KaraokeLyricsAppearance;

/// 行组绘制计数（测试 / profile 用：断言只有当前行组逐帧重绘）。
int karaokeDebugRowPaintCount = 0;

/// 拖动预览松手后多久恢复自动居中。
const Duration kKaraokeResumeAutoScroll = Duration(seconds: 3);

/// 长按（或 [KaraokeLyricsView.tapLooksUp] 时点按）命中的音节。
@immutable
class KaraokeLookupHit {
  const KaraokeLookupHit({
    required this.lineIndex,
    required this.syllableIndex,
    required this.charIndexInLine,
    required this.lineText,
    required this.globalRect,
  });

  /// [LyricTimeline.lines] 下标（和声行是它自己的下标）。
  final int lineIndex;
  final int syllableIndex;

  /// 被点中的字在 [lineText] 里的 UTF-16 下标。
  final int charIndexInLine;
  final String lineText;

  /// 被点中音节的全局矩形（查词弹窗锚点）。
  final Rect globalRect;
}

class KaraokeLyricsView extends StatefulWidget {
  const KaraokeLyricsView({
    super.key,
    required this.timeline,
    required this.clock,
    required this.playing,
    this.offsetMs = 0,
    this.appearance = const KaraokeLyricsAppearance(),
    this.onSeek,
    this.onLookup,
    this.tapLooksUp = false,
  });

  final LyricTimeline timeline;
  final FushiPlaybackClock clock;
  final bool playing;

  /// 显示时间 = 位置 + [offsetMs]（正 = 歌词提前）。
  final int offsetMs;

  final KaraokeLyricsAppearance appearance;

  /// 跳转到播放位置（毫秒）：点行、拖动预览松手。
  final ValueChanged<int>? onSeek;
  final ValueChanged<KaraokeLookupHit>? onLookup;

  /// true = 点按音节也查词（点在字外仍是跳转）。
  final bool tapLooksUp;

  @override
  State<KaraokeLyricsView> createState() => _KaraokeLyricsViewState();
}

/// 一组行（主行 + 和声行）的排版。
class _RowLayout {
  _RowLayout(this.span, this.main, this.backgrounds, this.size);

  final KaraokeRowSpan span;
  final KaraokeLineLayout main;

  /// (排版, 相对行组顶的纵向偏移)。
  final List<(KaraokeLineLayout, double)> backgrounds;
  final Size size;

  void dispose() {
    main.dispose();
    for (final (KaraokeLineLayout l, double _) in backgrounds) {
      l.dispose();
    }
  }
}

class _KaraokeLyricsViewState extends State<KaraokeLyricsView>
    with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker((Duration _) => _refresh());
  late final AnimationController _scroll = AnimationController.unbounded(
    vsync: this,
  );

  /// 原始播放位置（毫秒）：当前行组的画家监听它逐帧重绘。
  final ValueNotifier<int> _position = ValueNotifier<int>(0);

  List<KaraokeRowSpan> _rows = const <KaraokeRowSpan>[];
  List<_RowLayout> _layouts = const <_RowLayout>[];
  List<double> _tops = const <double>[];
  Object? _layoutKey;
  int _current = -1;
  int? _preview;
  bool _holdAutoScroll = false;
  Timer? _resumeTimer;
  double _viewportHeight = 0;
  double? _lastTarget;
  bool _motion = true;

  @override
  void initState() {
    super.initState();
    _rows = karaokeRows(widget.timeline);
    _position.value = widget.clock.position.inMilliseconds;
    _current = _computeCurrent();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = fushiMotionEnabled(context);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant KaraokeLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.timeline, widget.timeline)) {
      _rows = karaokeRows(widget.timeline);
      _layoutKey = null;
      _lastTarget = null;
    }
    _syncTicker();
    // 暂停时没有逐帧 Ticker：调用方重建（拖进度 / 改偏移）时同步一次。
    _refresh(fromBuild: true);
  }

  void _syncTicker() {
    final bool want = widget.playing && widget.timeline.isSynced;
    if (want && !_ticker.isActive) {
      _ticker.start();
    } else if (!want && _ticker.isActive) {
      _ticker.stop();
    }
  }

  int _computeCurrent() => karaokeCurrentRow(
    timeline: widget.timeline,
    rows: _rows,
    positionMs: _position.value,
    offsetMs: widget.offsetMs,
  );

  void _refresh({bool fromBuild = false}) {
    final int pos = widget.clock.position.inMilliseconds;
    if (_position.value != pos) _position.value = pos;
    final int cur = _computeCurrent();
    if (cur != _current) {
      if (fromBuild) {
        _current = cur;
      } else {
        setState(() => _current = cur);
      }
      _scheduleAutoScroll();
    }
  }

  void _scheduleAutoScroll() {
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _autoScroll();
    });
  }

  double _targetFor(int row) {
    if (_tops.isEmpty) return 0;
    final int r = row.clamp(0, _tops.length - 1);
    return _tops[r] - _viewportHeight * widget.appearance.anchor;
  }

  void _autoScroll({bool jump = false}) {
    if (_holdAutoScroll || _tops.isEmpty || !widget.timeline.isSynced) return;
    final double target = _targetFor(_current < 0 ? 0 : _current);
    if (_lastTarget == target && !jump) return;
    final bool first = _lastTarget == null;
    _lastTarget = target;
    if (jump || first || !_motion) {
      _scroll.value = target;
      return;
    }
    _scroll.animateWith(
      SpringSimulation(
        FushiSprings.spatialSlow.description,
        _scroll.value,
        target,
        _scroll.velocity,
      ),
    );
  }

  double get _minScroll => _tops.isEmpty
      ? 0
      : _tops.first - _viewportHeight * widget.appearance.anchor;

  double get _maxScroll => _tops.isEmpty
      ? 0
      : _tops.last - _viewportHeight * widget.appearance.anchor;

  int _rowAtAnchor() {
    final double y = _scroll.value + _viewportHeight * widget.appearance.anchor;
    int best = 0;
    double bestD = double.infinity;
    for (int i = 0; i < _tops.length; i++) {
      final double d = (_tops[i] + _layouts[i].size.height / 2 - y).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _onDragStart(DragStartDetails _) {
    _resumeTimer?.cancel();
    _scroll.stop();
    setState(() {
      _holdAutoScroll = true;
      _preview = widget.timeline.isSynced ? _rowAtAnchor() : null;
    });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _scroll.value = (_scroll.value - d.delta.dy).clamp(
      _minScroll,
      _maxScroll < _minScroll ? _minScroll : _maxScroll,
    );
    if (widget.timeline.isSynced) {
      final int p = _rowAtAnchor();
      if (p != _preview) setState(() => _preview = p);
    }
  }

  void _onDragEnd(DragEndDetails _) {
    final int? p = _preview;
    if (p != null && widget.onSeek != null && widget.timeline.isSynced) {
      widget.onSeek!(_seekPositionOf(_rows[p].main));
    }
    setState(() => _preview = null);
    _resumeTimer = Timer(kKaraokeResumeAutoScroll, () {
      if (!mounted) return;
      _holdAutoScroll = false;
      _lastTarget = _scroll.value;
      _autoScroll();
    });
  }

  int _seekPositionOf(int lineIndex) => karaokeSeekPositionForLine(
    line: widget.timeline.lines[lineIndex],
    offsetMs: widget.offsetMs,
  );

  void _ensureLayouts(double width, KaraokeResolvedStyle style) {
    final Object key = Object.hash(
      identityHashCode(widget.timeline),
      width,
      style,
    );
    if (key == _layoutKey) return;
    _layoutKey = key;
    for (final _RowLayout l in _layouts) {
      l.dispose();
    }
    final LyricTimeline t = widget.timeline;
    final bool lineLevel =
        t.timingQuality.index <= LyricTimingQuality.line.index;
    final List<_RowLayout> out = <_RowLayout>[];
    for (final KaraokeRowSpan span in _rows) {
      final TextAlign align = switch (t.sideOf(t.lines[span.main])) {
        LyricAgentSide.start => TextAlign.left,
        LyricAgentSide.center => TextAlign.center,
        LyricAgentSide.end => TextAlign.right,
      };
      final KaraokeLineLayout main = KaraokeLineLayout.build(
        line: t.lines[span.main],
        width: width,
        style: style.main,
        resolved: style,
        align: align,
        lineLevel: lineLevel,
      );
      double y = main.size.height;
      final List<(KaraokeLineLayout, double)> bgs =
          <(KaraokeLineLayout, double)>[];
      for (final int bi in span.backgrounds) {
        y += 4;
        final KaraokeLineLayout bg = KaraokeLineLayout.build(
          line: t.lines[bi],
          width: width,
          style: style.background,
          resolved: style,
          align: align,
          lineLevel: lineLevel,
        );
        bgs.add((bg, y));
        y += bg.size.height;
      }
      out.add(_RowLayout(span, main, bgs, Size(width, y)));
    }
    _layouts = out;
    final List<double> tops = <double>[];
    double acc = 0;
    for (final _RowLayout l in out) {
      tops.add(acc);
      acc += l.size.height + widget.appearance.rowSpacing;
    }
    _tops = tops;
    _lastTarget = null;
    _scheduleAutoScroll();
  }

  void _lookupAt(BuildContext rowContext, int row, Offset local) {
    final ValueChanged<KaraokeLookupHit>? cb = widget.onLookup;
    if (cb == null) return;
    final KaraokeLookupHit? hit = _hitAt(rowContext, row, local);
    if (hit != null) cb(hit);
  }

  KaraokeLookupHit? _hitAt(BuildContext rowContext, int row, Offset local) {
    final _RowLayout layout = _layouts[row];
    final List<(int, KaraokeLineLayout, double)> parts =
        <(int, KaraokeLineLayout, double)>[
          (layout.span.main, layout.main, 0),
          for (int k = 0; k < layout.backgrounds.length; k++)
            (
              layout.span.backgrounds[k],
              layout.backgrounds[k].$1,
              layout.backgrounds[k].$2,
            ),
        ];
    for (final (int li, KaraokeLineLayout l, double dy) in parts) {
      final ({int syllable, int charIndex})? h = l.hitTest(
        local - Offset(0, dy),
      );
      if (h == null) continue;
      final RenderBox? box = rowContext.findRenderObject() as RenderBox?;
      final Rect r = l.syllables[h.syllable].bounds.shift(Offset(0, dy));
      final Rect global = box == null
          ? r
          : Rect.fromPoints(
              box.localToGlobal(r.topLeft),
              box.localToGlobal(r.bottomRight),
            );
      return KaraokeLookupHit(
        lineIndex: li,
        syllableIndex: h.syllable,
        charIndexInLine: h.charIndex,
        lineText: l.line.text,
        globalRect: global,
      );
    }
    return null;
  }

  void _onRowTap(BuildContext rowContext, int row, Offset local) {
    if (widget.tapLooksUp && widget.onLookup != null) {
      final KaraokeLookupHit? hit = _hitAt(rowContext, row, local);
      if (hit != null) {
        widget.onLookup!(hit);
        return;
      }
    }
    if (!widget.timeline.isSynced) return;
    widget.onSeek?.call(_seekPositionOf(_rows[row].main));
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _ticker.dispose();
    _scroll.dispose();
    _position.dispose();
    for (final _RowLayout l in _layouts) {
      l.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KaraokeLyricsAppearance a = widget.appearance;
    final KaraokeResolvedStyle style = KaraokeResolvedStyle.of(context, a);
    final bool blur =
        a.blurInactive && _motion && !MediaQuery.highContrastOf(context);
    final Duration fade = fushiMotionDuration(context, FushiMotion.medium);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = (constraints.maxWidth - a.horizontalPadding * 2)
            .clamp(1.0, double.infinity);
        _viewportHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 600;
        _ensureLayouts(width, style);
        final bool synced = widget.timeline.isSynced;
        final int focus = _preview ?? _current;
        final List<Widget> children = <Widget>[
          for (int i = 0; i < _layouts.length; i++)
            _buildRow(
              i,
              focus: focus,
              synced: synced,
              blur: blur,
              fade: fade,
              style: style,
            ),
        ];
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: ClipRect(
            child: Flow(
              delegate: _KaraokeFlowDelegate(
                scroll: _scroll,
                tops: _tops,
                sizes: <Size>[for (final _RowLayout l in _layouts) l.size],
                padding: a.horizontalPadding,
              ),
              children: children,
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(
    int i, {
    required int focus,
    required bool synced,
    required bool blur,
    required Duration fade,
    required KaraokeResolvedStyle style,
  }) {
    final _RowLayout layout = _layouts[i];
    final bool isCurrent = synced && i == _current;
    final bool isFocus = !synced || i == focus;
    final int distance = focus < 0 ? i + 1 : (i - focus).abs();
    // 离当前行越远越糊、越淡（参考图：相邻行还看得清，往下逐行沉进背景）。
    final double sigma = blur && synced && !isFocus
        ? (distance.clamp(1, 4) * 1.1).toDouble()
        : 0;
    final double fadeOpacity = !synced || isFocus
        ? 1
        : (widget.appearance.inactiveOpacity - 0.07 * (distance - 1)).clamp(
            0.12,
            1.0,
          );
    Widget row = Builder(
      builder: (BuildContext rowContext) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (TapUpDetails d) => _onRowTap(rowContext, i, d.localPosition),
        onLongPressStart: (LongPressStartDetails d) =>
            _lookupAt(rowContext, i, d.localPosition),
        child: Semantics(
          label: layout.main.line.text,
          button: synced,
          child: CustomPaint(
            size: layout.size,
            painter: _KaraokeRowPainter(
              layout: layout,
              active: isCurrent,
              position: isCurrent ? _position : null,
              offsetMs: widget.offsetMs,
              motion: _motion,
              lineLevelSweep: widget.appearance.lineLevelSweep,
              liftPx: widget.appearance.liftPx,
              sungStatic: !synced,
            ),
          ),
        ),
      ),
    );
    // 模糊始终包一层、只切 enabled：切换当前行时不换子树类型（否则整行重挂、丢掉缓存层）。
    row = ImageFiltered(
      enabled: sigma > 0,
      imageFilter: ui.ImageFilter.blur(
        sigmaX: sigma > 0 ? sigma : 0.01,
        sigmaY: sigma > 0 ? sigma : 0.01,
      ),
      child: RepaintBoundary(child: row),
    );
    return AnimatedOpacity(
      key: ValueKey<int>(i),
      opacity: fadeOpacity,
      duration: fade,
      child: row,
    );
  }
}

class _KaraokeRowPainter extends CustomPainter {
  _KaraokeRowPainter({
    required this.layout,
    required this.active,
    required this.position,
    required this.offsetMs,
    required this.motion,
    required this.lineLevelSweep,
    required this.liftPx,
    required this.sungStatic,
  }) : super(repaint: position);

  final _RowLayout layout;
  final bool active;
  final ValueListenable<int>? position;
  final int offsetMs;
  final bool motion;
  final bool lineLevelSweep;
  final double liftPx;

  /// 无时间歌词：整首以已唱色静态显示。
  final bool sungStatic;

  @override
  void paint(Canvas canvas, Size size) {
    karaokeDebugRowPaintCount++;
    final ValueListenable<int>? pos = position;
    void one(int lineIndex, KaraokeLineLayout l) {
      if (active && pos != null) {
        l.paintActive(
          canvas,
          timeMs: karaokeLineTimeMs(positionMs: pos.value, offsetMs: offsetMs),
          motion: motion,
          lineLevelSweep: lineLevelSweep,
          liftPx: liftPx,
        );
      } else {
        l.paintStatic(canvas, sung: sungStatic);
      }
    }

    one(layout.span.main, layout.main);
    for (int k = 0; k < layout.backgrounds.length; k++) {
      final (KaraokeLineLayout l, double dy) = layout.backgrounds[k];
      canvas
        ..save()
        ..translate(0, dy);
      one(layout.span.backgrounds[k], l);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _KaraokeRowPainter old) =>
      !identical(old.layout, layout) ||
      old.active != active ||
      old.position != position ||
      old.offsetMs != offsetMs ||
      old.motion != motion ||
      old.lineLevelSweep != lineLevelSweep ||
      old.liftPx != liftPx ||
      old.sungStatic != sungStatic;
}

class _KaraokeFlowDelegate extends FlowDelegate {
  _KaraokeFlowDelegate({
    required this.scroll,
    required this.tops,
    required this.sizes,
    required this.padding,
  }) : super(repaint: scroll);

  final Animation<double> scroll;
  final List<double> tops;
  final List<Size> sizes;
  final double padding;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      i < sizes.length
      ? BoxConstraints.tight(sizes[i])
      : BoxConstraints.tight(Size.zero);

  @override
  void paintChildren(FlowPaintingContext context) {
    final double h = context.size.height;
    final double s = scroll.value;
    for (int i = 0; i < context.childCount && i < tops.length; i++) {
      final double y = tops[i] - s;
      // 视口外不画（也就不参与命中测试）。
      if (y > h || y + sizes[i].height < 0) continue;
      context.paintChild(
        i,
        transform: Matrix4.translationValues(padding, y, 0),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _KaraokeFlowDelegate old) =>
      !identical(old.tops, tops) || old.padding != padding;

  @override
  bool shouldRelayout(covariant _KaraokeFlowDelegate old) =>
      !identical(old.sizes, sizes) && !_sameSizes(old.sizes, sizes);

  static bool _sameSizes(List<Size> a, List<Size> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
