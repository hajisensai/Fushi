/// 全屏歌词动画样式「时计」（移植自 folia-major `src/components/visualizer/pendolo/`）。
///
/// 左侧（镜像时右侧）一只线框钟表机芯：擒纵主轮、太阳轮与三颗行星轮、传动齿轮、
/// 每秒走一齿的秒齿轮、惰轮、摆轮与游丝；歌词沿主轮外的弧线排开，焦点句停在刻度针
/// 指着的水平位置。换句时轮盘按擒纵弹簧一格格「咔哒」转过去，焦点句逐字扫亮，
/// 译文排在每句下面。可倾斜表盘（透视 + 分层视差），或切到「轮心视角」顺着刻度针看，
/// 句子立起来正对相机。
///
/// 实现：一个 CustomPainter（`repaint: ticks`）画机芯与歌词；擒纵弹簧 / 摆轮相位在
/// tick 回调里推进；每句的 TextPainter 按句缓存。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_clockwork.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry pendoloVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.pendolo,
  label: () => t.music_visualizer_mode_pendolo,
  description: () => t.music_visualizer_pendolo_description,
  icon: FushiIcons.timer,
  tunings: pendoloTuningSpecs,
  sharedBackdrop: true,
  // 译文排在每句歌词下面（folia 也不用共享字幕）。
  sharedSubtitle: false,
  builder: (LyricVisualizerContext c) => PendoloVisualizer(context: c),
);

/// 没有歌词时轮盘每这么多毫秒走一格（folia `INSTRUMENTAL_SECONDS_PER_FRAME`）。
const int _kInstrumentalStepMs = 5000;

/// 时计样式本体。
class PendoloVisualizer extends StatelessWidget {
  const PendoloVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  Widget build(BuildContext buildContext) => LyricVisualizerFrame(
    context: context,
    builder: (BuildContext _, LyricVisualizerTicks ticks) =>
        _PendoloStage(visualizer: context, ticks: ticks),
  );
}

/// 轮盘此刻的锚点（句下标，可能是 x.5 / -1 / 句数）。
double pendoloTargetIndexAt(LyricVisualizerRuntime runtime, int timeMs) {
  final List<LyricVisualizerLine> lines = runtime.lines;
  if (lines.isEmpty) return (timeMs ~/ _kInstrumentalStepMs).toDouble();
  return resolvePendoloAnchorIndex(
    lineCount: lines.length,
    activeIndex: runtime.activeLineAt(timeMs),
    lastStartedIndex: runtime.lastStartedLineAt(timeMs),
    lastLineEndMs: lines.last.endMs,
    timeMs: timeMs,
  );
}

class _PendoloStage extends StatefulWidget {
  const _PendoloStage({required this.visualizer, required this.ticks});

  final LyricVisualizerContext visualizer;
  final LyricVisualizerTicks ticks;

  @override
  State<_PendoloStage> createState() => _PendoloStageState();
}

class _CachedBlock {
  _CachedBlock(this.block, this.frame);

  final PendoloLineBlock block;
  int frame;
}

class _PendoloStageState extends State<_PendoloStage> {
  final PendoloClockworkMotion _motion = PendoloClockworkMotion();
  final PendoloClockworkPaths _paths = PendoloClockworkPaths();
  PendoloSpring? _spring;
  double _target = 0;
  double _lastElapsed = 0;

  late PendoloTuning _tuning;

  final Map<String, _CachedBlock> _blocks = <String, _CachedBlock>{};
  int _frame = 0;
  final Map<int, double> _heights = <int, double>{};
  String _heightsKey = '';

  ui.Image? _cover;
  String? _coverPath;
  ImageStream? _coverStream;
  ImageStreamListener? _coverListener;

  LyricVisualizerContext get _c => widget.visualizer;

  @override
  void initState() {
    super.initState();
    _tuning = PendoloTuning.read(_c.tuning);
    widget.ticks.addListener(_onTick);
    _onTick();
    _syncCover();
  }

  @override
  void didUpdateWidget(covariant _PendoloStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ticks, widget.ticks)) {
      oldWidget.ticks.removeListener(_onTick);
      widget.ticks.addListener(_onTick);
    }
    final LyricVisualizerContext o = oldWidget.visualizer;
    _tuning = PendoloTuning.read(_c.tuning);
    if (!identical(o.runtime, _c.runtime) ||
        o.palette != _c.palette ||
        o.fontScale != _c.fontScale ||
        o.tuning != _c.tuning) {
      _clearBlocks();
    }
    // 换歌：轮盘从新歌的锚点起步，不从上一首的位置转过来。
    if (o.seed != _c.seed || !identical(o.runtime, _c.runtime)) {
      _spring = null;
    }
    _syncCover();
    _onTick();
  }

  @override
  void dispose() {
    widget.ticks.removeListener(_onTick);
    _cancelCover();
    _cover?.dispose();
    _cover = null;
    _clearBlocks();
    super.dispose();
  }

  void _clearBlocks() {
    for (final _CachedBlock b in _blocks.values) {
      b.block.dispose();
    }
    _blocks.clear();
    _heights.clear();
    _heightsKey = '';
  }

  void _onTick() {
    final LyricVisualizerTick tick = widget.ticks.value;
    _target = pendoloTargetIndexAt(_c.runtime, tick.timeMs);
    final double dt = (tick.elapsed - _lastElapsed).clamp(0.0, 0.05);
    _lastElapsed = tick.elapsed;
    final PendoloSpring? spring = _spring;
    if (spring == null) {
      _spring = PendoloSpring(_target);
    } else if (_c.motion) {
      spring.step(_target, dt, _tuning.tickSnappiness);
    } else {
      spring.snap(_target);
    }
    if (_c.motion) {
      // 没有实时低音：用歌词节拍包络（每个字起唱时冲到 1）带动摆轮。
      final double bass = _c.runtime.pulseAt(tick.timeMs) * 0.6;
      _motion.step(dt, bass, paused: !_c.playing);
    }
  }

  // ---- 封面 ----------------------------------------------------------------

  void _syncCover() {
    final String? path = _tuning.showCover ? _c.coverPath : null;
    if (path == _coverPath) return;
    _coverPath = path;
    _cancelCover();
    _cover?.dispose();
    _cover = null;
    if (path == null || path.isEmpty) return;
    final File file = File(path);
    if (!file.existsSync()) return;
    final ImageStream stream = ResizeImage(
      FileImage(file),
      width: 512,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        stream.removeListener(listener);
        _coverStream = null;
        _coverListener = null;
        final ui.Image image = info.image.clone();
        info.dispose();
        if (!mounted || _coverPath != path) {
          image.dispose();
          return;
        }
        setState(() {
          _cover?.dispose();
          _cover = image;
        });
      },
      onError: (Object error, StackTrace? stackTrace) {
        stream.removeListener(listener);
        _coverStream = null;
        _coverListener = null;
      },
    );
    _coverStream = stream;
    _coverListener = listener;
    stream.addListener(listener);
  }

  void _cancelCover() {
    final ImageStreamListener? l = _coverListener;
    if (l != null) _coverStream?.removeListener(l);
    _coverStream = null;
    _coverListener = null;
  }

  // ---- 文字缓存 ------------------------------------------------------------

  PendoloLineBlock _block(
    LyricVisualizerLine line, {
    required bool focal,
    required double maxWidth,
    required PendoloAlign align,
    required Color primary,
    required Color fill,
    required Color secondary,
  }) {
    final String key =
        '${line.index}|${focal ? 1 : 0}|${maxWidth.round()}|${align.index}';
    final _CachedBlock? hit = _blocks[key];
    if (hit != null) {
      hit.frame = _frame;
      return hit.block;
    }
    final PendoloLineBlock block = PendoloLineBlock.build(
      line: line,
      focal: focal,
      fontScale: _c.fontScale,
      maxWidth: maxWidth,
      align: align,
      primary: primary,
      fillColor: fill,
      secondary: secondary,
    );
    _blocks[key] = _CachedBlock(block, _frame);
    return block;
  }

  void _evictBlocks() {
    if (_blocks.length < 48) return;
    _blocks.removeWhere((String _, _CachedBlock b) {
      final bool stale = _frame - b.frame > 90;
      if (stale) b.block.dispose();
      return stale;
    });
  }

  List<double> _blockHeights(
    List<LyricVisualizerLine> lines,
    double target,
    double measureWidth,
  ) {
    final String key =
        '${measureWidth.round()}|${_c.fontScale}|${_tuning.activeScale}';
    if (key != _heightsKey) {
      _heights.clear();
      _heightsKey = key;
    }
    return <double>[
      for (int i = 0; i < lines.length; i++)
        if ((i - target).abs() > 10)
          0
        else
          _heights.putIfAbsent(
            i,
            () => pendoloFocalBlockHeight(
              lines[i],
              fontScale: _c.fontScale,
              measureWidth: measureWidth,
              activeScale: _tuning.activeScale,
            ),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.infinite,
      painter: _PendoloPainter(this, widget.ticks),
    ),
  );
}

class _PendoloPainter extends CustomPainter {
  _PendoloPainter(this.s, this.ticks) : super(repaint: ticks);

  final _PendoloStageState s;
  final LyricVisualizerTicks ticks;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    s._frame++;
    final LyricVisualizerContext c = s._c;
    final PendoloTuning tu = s._tuning;
    final int t = ticks.value.timeMs;
    final double w = size.width;
    final double h = size.height;
    final double side = tu.sideSign;
    final double minSide = math.min(w, h);
    final double hubX = pendoloWheelCenterX(w, tu);
    final double hubY = h * tu.wheelCenterY;
    final double baseRadius = minSide * tu.arcRadius;
    final double lyricOffset = minSide * 0.06;
    final double ringRadius = baseRadius + lyricOffset;

    final double target = s._target;
    final double springValue = s._spring?.value ?? target;
    final double step = pendoloAngleStepRad(tu.arcAngleDeg);
    final double wheelRotationRad = -(springValue - target) * step;
    final double wheelRotationDeg = wheelRotationRad * 180 / math.pi;
    final double railRotationRad = wheelRotationRad * side;
    final double gearAngle = springValue * step;

    // 投影：轮心视角代替倾斜。
    final PendoloDialProjection tilt;
    if (tu.hubView) {
      final double camH =
          baseRadius *
          math.max(
            tu.hubViewHeight,
            PendoloLayerHeight.balance * tu.parallaxDepth + 0.15,
          );
      tilt = buildPendoloHubViewProjection(
        cameraHeightPx: camH,
        backDistancePx: baseRadius * tu.hubViewBack,
        targetDistancePx: ringRadius,
        side: side,
        hubX: hubX,
        hubY: hubY,
        viewportWidth: w,
        viewportHeight: h,
      );
    } else {
      tilt = buildPendoloTiltProjection(tu.tiltDeg, tu.tiltAxisDeg, w, h);
    }
    final double parallaxPx = tilt.flat ? 0 : tu.parallaxDepth * baseRadius;
    final PendoloDialProjection dial = buildPendoloDialProjection(
      tilt,
      mirrored: tu.mirrored,
    );

    final LyricVisualizerPalette pal = c.palette;
    final Color primary = pal.text;
    final Color accent = pal.primary;

    // ---- 机芯 ----
    if (tu.gearDecor != PendoloGearDecor.none ||
        tu.showCenterGradient ||
        (tu.showCover && s._cover != null)) {
      final PendoloClockworkFrame frame = PendoloClockworkFrame(
        hubX: hubX,
        hubY: hubY,
        anchors: PendoloClockworkAnchors(baseRadius, ringRadius),
        escapementAngle: gearAngle,
        phase: s._motion.phase,
        bassOscillation: s._motion.bassOscillation,
        secondGearAngle: s._motion.secondGearAngle,
        primary: primary,
        accent: accent,
        background: pal.background,
        decor: tu.gearDecor,
        showCenterGradient: tu.showCenterGradient,
        cover: tu.showCover ? s._cover : null,
        mirrored: tu.mirrored,
        dial: dial,
        parallaxScalePx: parallaxPx,
      );
      if (tu.lineGlow) {
        _paintGlowing(canvas, size, frame, accent);
      } else {
        paintPendoloClockwork(canvas, frame, s._paths);
      }
    }

    // ---- 歌词 ----
    final List<LyricVisualizerLine> lines = c.runtime.lines;
    if (lines.isEmpty) return;
    final double maxItemX = hubX + baseRadius;
    final double available = math.max(
      140,
      math.min(
        w * 0.46,
        tu.mirrored ? hubX - baseRadius - 48 : w - maxItemX - 48,
      ),
    );
    final List<double> heights = s._blockHeights(
      lines,
      target,
      available / tu.activeScale,
    );
    final List<PendoloLineItem> items = calculatePendoloWheelLayout(
      lineCount: lines.length,
      targetLineIndex: target,
      viewportWidth: w,
      viewportHeight: h,
      tuning: tu,
      radiusOffsetPx: lyricOffset,
      lineBlockHeights: heights,
    );
    final Color fill = Color.lerp(primary, accent, 0.32)!;
    final Color secondary = Color.lerp(primary, pal.background, 0.35)!;
    final PendoloDialProjection lyricLayer = buildPendoloLayerProjection(
      tilt,
      PendoloLayerHeight.lyrics * parallaxPx,
    );
    final PendoloAlign align = tu.hubView
        ? PendoloAlign.center
        : tu.mirrored
        ? PendoloAlign.right
        : PendoloAlign.left;

    PendoloLineBlock blockOf(PendoloLineItem item) => s._block(
      lines[item.index],
      focal: item.isActive,
      maxWidth: available / item.scale,
      align: align,
      primary: primary,
      fill: fill,
      secondary: secondary,
    );

    if (tu.hubView) {
      _paintStanding(
        canvas,
        items,
        blockOf,
        lyricLayer,
        hubX,
        hubY,
        railRotationRad,
        wheelRotationDeg,
        t,
      );
    } else {
      canvas.save();
      canvas.transform(
        Float64List.fromList(lyricLayer.canvasMatrix(hubX, hubY).storage),
      );
      canvas.rotate(railRotationRad);
      final double railDeg = railRotationRad * 180 / math.pi;
      for (final PendoloLineItem item in items) {
        final double opacity = pendoloRotatingLineOpacity(
          item.angleDeg,
          wheelRotationDeg,
          item.alpha,
        );
        if (opacity <= 0.003) continue;
        final PendoloLineBlock block = blockOf(item);
        canvas.save();
        canvas.translate(item.x - hubX, item.y - hubY);
        // 文字随轨道转一部分再回正一部分（folia：-0.65 × 轨道转角 + 0.35 × 弧上角度）。
        canvas.rotate(
          (-railDeg * 0.65 + side * item.angleDeg * 0.35) * math.pi / 180,
        );
        canvas.scale(item.scale);
        block.paint(
          canvas,
          Offset(tu.mirrored ? -block.width : 0, -block.height / 2),
          opacity,
          t,
        );
        canvas.restore();
      }
      canvas.restore();
    }
    s._evictBlocks();
  }

  /// 轮心视角：句子立起来正对相机，中点对着自己在弧上的锚点，底边落在锚点上。
  void _paintStanding(
    Canvas canvas,
    List<PendoloLineItem> items,
    PendoloLineBlock Function(PendoloLineItem) blockOf,
    PendoloDialProjection layer,
    double hubX,
    double hubY,
    double railRotationRad,
    double wheelRotationDeg,
    int t,
  ) {
    final double cr = math.cos(railRotationRad);
    final double sr = math.sin(railRotationRad);
    final List<(double, PendoloLineItem, Offset, double)> placed =
        <(double, PendoloLineItem, Offset, double)>[];
    for (final PendoloLineItem item in items) {
      double opacity = pendoloRotatingLineOpacity(
        item.angleDeg,
        wheelRotationDeg,
        item.alpha,
      );
      if (!item.isActive) {
        opacity *= pendoloStandSideLineAlpha(item.distanceFromActive);
      }
      opacity *= pendoloStandEdgeFade(item.angleDeg + wheelRotationDeg);
      if (opacity <= 0.003) continue;
      final double dx = item.x - hubX;
      final double dy = item.y - hubY;
      final double rx = dx * cr - dy * sr;
      final double ry = dx * sr + dy * cr;
      final ({double x, double y, double depthScale}) p = layer.project(rx, ry);
      // 相机背后或贴着相机平面的不画。
      if (p.depthScale > 4) continue;
      placed.add((p.depthScale, item, Offset(hubX + p.x, hubY + p.y), opacity));
    }
    // 远的先画。
    placed.sort(
      (
        (double, PendoloLineItem, Offset, double) a,
        (double, PendoloLineItem, Offset, double) b,
      ) => a.$1.compareTo(b.$1),
    );
    for (final (double, PendoloLineItem, Offset, double) e in placed) {
      final PendoloLineBlock block = blockOf(e.$2);
      canvas.save();
      canvas.translate(e.$3.dx, e.$3.dy);
      canvas.scale(e.$1 * e.$2.scale);
      block.paint(canvas, Offset(-block.width / 2, -block.height), e.$4, t);
      canvas.restore();
    }
  }

  /// 线条发光（folia CSS drop-shadow 4px / 12px）：先把机芯录成 Picture，按强调色
  /// 模糊叠两层光晕，再画本体。
  void _paintGlowing(
    Canvas canvas,
    Size size,
    PendoloClockworkFrame frame,
    Color accent,
  ) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    paintPendoloClockwork(Canvas(recorder), frame, s._paths);
    final ui.Picture picture = recorder.endRecording();
    final Rect bounds = Offset.zero & size;
    for (final (double sigma, double alpha) in <(double, double)>[
      (6, 0.3),
      (2, 0.65),
    ]) {
      canvas.saveLayer(
        bounds,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma)
          ..colorFilter = ColorFilter.mode(
            accent.withValues(alpha: alpha),
            BlendMode.srcIn,
          ),
      );
      canvas.drawPicture(picture);
      canvas.restore();
    }
    canvas.drawPicture(picture);
    picture.dispose();
  }

  @override
  bool shouldRepaint(covariant _PendoloPainter oldDelegate) => true;
}
