/// 全屏歌词动画样式「时计」（移植自 folia-major `src/components/visualizer/pendolo/`）。
///
/// 左侧（镜像时右侧）一只线框钟表机芯：擒纵主轮、太阳轮与三颗行星轮、传动齿轮、
/// 每秒走一齿的秒齿轮、惰轮、摆轮与游丝；歌词沿主轮外的弧线排开，焦点句停在刻度针
/// 指着的水平位置。换句时轮盘按擒纵弹簧一格格「咔哒」转过去，焦点句逐字扫亮，
/// 译文排在每句下面。可倾斜表盘（透视 + 分层视差），或切到「轮心视角」顺着刻度针看，
/// 句子立起来正对相机。
///
/// 音频：摆轮的摆速 / 摆幅跟共享音频帧的低频；鼓击就绪时「仿真鼓面」（轮心光晕、宝石闪光、
/// 表盘亮圈、表盘鼓起、强击抖屏）。动画强度档位（calm / normal / chaotic）调摆轮、擒纵弹簧与
/// 副歌强调；正在唱的副歌句加光晕、扫亮层发光、强调色比例 0.58。主题 wordColors 染扫亮层。
///
/// 实现：一个 CustomPainter（`repaint: ticks`）画机芯与歌词；擒纵弹簧 / 摆轮相位 / 鼓面状态
/// 在 tick 回调里推进；每句的 TextPainter 按句缓存。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_cover.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_beat_fx.dart';
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
  tuningPresets: pendoloTuningPresets,
  // folia：机芯画在用户选的背景上（中心渐变是样式自己的）。
  background: (_) => LyricVisualizerBackgroundRequest.selected,
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

/// 轮盘此刻的锚点（句下标，可能是 x.5 / -1 / 句数）。最后一句过了它的视觉结束
/// （`renderEndMs`，folia `renderHints.renderEndTime`）才转出去。
double pendoloTargetIndexAt(LyricVisualizerRuntime runtime, int timeMs) {
  final List<LyricVisualizerLine> lines = runtime.lines;
  if (lines.isEmpty) return (timeMs ~/ _kInstrumentalStepMs).toDouble();
  return resolvePendoloAnchorIndex(
    lineCount: lines.length,
    activeIndex: runtime.activeLineAt(timeMs),
    lastStartedIndex: runtime.lastStartedLineAt(timeMs),
    lastLineEndMs: lines.last.renderEndMs,
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

class _PendoloStageState extends State<_PendoloStage>
    with StateResourceScope<_PendoloStage> {
  final PendoloClockworkMotion _motion = PendoloClockworkMotion();
  final PendoloClockworkPaths _paths = PendoloClockworkPaths();
  final PendoloDrumhead _drum = PendoloDrumhead();
  final math.Random _rng = math.Random(7);
  final LyricVisualizerImageLoader _cover = LyricVisualizerImageLoader();
  PendoloSpring? _spring;
  double _target = 0;
  double _lastElapsed = 0;
  int? _lastTimeMs;

  late PendoloTuning _tuning;
  late PendoloMotionProfile _profile;

  /// 各句的副歌强调进度（只留还没退完的）。
  final Map<int, PendoloChorusRamp> _chorus = <int, PendoloChorusRamp>{};

  /// 此刻正在唱的句（副歌强调只给它）。
  int _playingLine = -1;

  final Map<String, _CachedBlock> _blocks = <String, _CachedBlock>{};
  int _frame = 0;
  final Map<int, double> _heights = <int, double>{};
  String _heightsKey = '';

  LyricVisualizerContext get _c => widget.visualizer;

  /// 主题字体 / 字重（folia `resolveThemeFontStack` / `resolveThemeFontWeight(theme, 400)`）。
  TextStyle get _baseStyle =>
      _c.applyThemeFont(const TextStyle(fontWeight: FontWeight.w400));

  @override
  void initState() {
    super.initState();
    _readTuning();
    listenTo(widget.ticks, _onTick, slot: #ticks);
    _onTick();
    _syncCover();
  }

  void _readTuning() {
    _tuning = PendoloTuning.read(_c.tuning);
    _profile = PendoloMotionProfile.of(_c.intensity);
  }

  @override
  void didUpdateWidget(covariant _PendoloStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ticks, widget.ticks)) {
      listenTo(widget.ticks, _onTick, slot: #ticks);
    }
    final LyricVisualizerContext o = oldWidget.visualizer;
    _readTuning();
    if (!identical(o.runtime, _c.runtime) ||
        o.palette != _c.palette ||
        o.fontScale != _c.fontScale ||
        o.tuning != _c.tuning ||
        o.theme != _c.theme ||
        o.intensity != _c.intensity) {
      _clearBlocks();
    }
    // 换歌：轮盘从新歌的锚点起步，不从上一首的位置转过来；鼓面与副歌强调归零。
    if (o.seed != _c.seed || !identical(o.runtime, _c.runtime)) {
      _spring = null;
      _drum.reset();
      _chorus.clear();
      _lastTimeMs = null;
    }
    _syncCover();
    _onTick();
  }

  @override
  void dispose() {
    _cover.dispose();
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
    final int timeMs = tick.timeMs;
    _target = pendoloTargetIndexAt(_c.runtime, timeMs);
    final double dt = (tick.elapsed - _lastElapsed).clamp(0.0, 0.05);
    _lastElapsed = tick.elapsed;
    final int? prevMs = _lastTimeMs;
    final bool jump =
        prevMs == null || timeMs < prevMs - 50 || timeMs - prevMs > 500;
    _lastTimeMs = timeMs;
    final PendoloSpring? spring = _spring;
    if (spring == null) {
      _spring = PendoloSpring(_target);
    } else if (_c.motion) {
      spring.step(
        _target,
        dt,
        _tuning.tickSnappiness,
        springScale: _profile.escapementSpring,
        dampingScale: _profile.escapementDamping,
      );
    } else {
      spring.snap(_target);
    }
    final LyricVisualizerAudioFrame audio = _c.audioFrameAt(timeMs);
    if (_c.motion) {
      // folia：摆轮跟实时低频（audioBands.bass）；没有音频分析时框架给歌词起字包络的代用帧。
      _motion.step(
        dt,
        audio.low,
        paused: !_c.playing,
        bassResponse: _profile.bassResponse,
        balanceSpeed: _profile.balanceSpeed,
        balanceAmplitude: _profile.balanceAmplitude,
        escapementSpring: _profile.escapementSpring,
        escapementDamping: _profile.escapementDamping,
      );
    }
    // 仿真鼓面：关了动效 / 暂停 / 强度 0 时静止。
    if (_c.motion && _c.playing && _tuning.drumheadStrength > 0) {
      // 拖进度 / 首帧只对齐，跳过的鼓击不补打（folia readDrumFrame 的 seek）。
      _drum.step(
        dt,
        jump
            ? kPendoloNoDrums
            : pendoloDrumFrameOf(LyricVisualizerBeats.of(_c), prevMs, timeMs),
        strength: _tuning.drumheadStrength,
        strikeAngle: _rng.nextDouble() * 2 * math.pi,
      );
    } else if (!_drum.idle) {
      _drum.reset();
    }
    // 副歌强调：正在唱的句（播放中）是副歌时缓入，其余缓出。
    final List<LyricVisualizerLine> lines = _c.runtime.lines;
    final int playing = _c.playing ? _c.runtime.activeLineAt(timeMs) : -1;
    _playingLine = playing;
    if (playing >= 0 && lines[playing].isChorus) {
      _chorus.putIfAbsent(playing, PendoloChorusRamp.new);
    }
    final double seconds = _profile.chorusTransitionSeconds;
    _chorus.removeWhere((int i, PendoloChorusRamp r) {
      final bool on = i == playing && i < lines.length && lines[i].isChorus;
      if (_c.motion) {
        r.step(on, dt, seconds);
      } else {
        r.step(on, 1e9, seconds);
      }
      return r.idle && !on;
    });
  }

  // ---- 封面 ----------------------------------------------------------------

  void _syncCover() {
    final String? path = _tuning.showCover ? _c.coverPath : null;
    if (path == _cover.path) return;
    final ImageProvider? provider = lyricVisualizerCoverProvider(path);
    _cover.loadProvider(
      provider == null ? null : ResizeImage(provider, width: 512),
      key: path,
    );
  }

  // ---- 文字缓存 ------------------------------------------------------------

  PendoloLineBlock _block(
    LyricVisualizerLine line, {
    required bool focal,
    required bool chorus,
    required double maxWidth,
    required PendoloAlign align,
    required Color primary,
    required Color accent,
    required Color secondary,
  }) {
    final String key =
        '${line.position}|${focal ? 1 : 0}|${chorus ? 1 : 0}|'
        '${maxWidth.round()}|${align.index}|${_c.subtitle.hashCode}';
    final _CachedBlock? hit = _blocks[key];
    if (hit != null) {
      hit.frame = _frame;
      return hit.block;
    }
    final PendoloChorusLook look = PendoloChorusLook.of(
      chorus,
      chorus,
      _profile,
    );
    final PendoloLineBlock block = PendoloLineBlock.build(
      line: line,
      focal: focal,
      fontScale: _c.fontScale,
      maxWidth: maxWidth,
      align: align,
      primary: primary,
      fillColor: Color.lerp(primary, accent, look.accentMix)!,
      secondary: secondary,
      baseStyle: _baseStyle,
      theme: _c.theme,
      glowAccent: accent,
      chorusGlow: look.glow,
      subtitle: _c.subtitle,
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
    final TextStyle base = _baseStyle;
    final String key =
        '${measureWidth.round()}|${_c.fontScale}|${_tuning.activeScale}|'
        '${base.fontFamily}|${base.fontWeight?.value}|${_c.subtitle.hashCode}|'
        '${_c.theme?.fontFamily}|${_c.theme?.fontWeight?.value}';
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
              baseStyle: base,
              subtitle: _c.subtitle,
              theme: _c.theme,
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
  _PendoloPainter(this.s, this.ticks)
    : super(repaint: Listenable.merge(<Listenable>[ticks, s._cover]));

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
    final PendoloDrumhead drum = s._drum;
    final Color fxColor = pendoloBeatFxColor(accent);

    void inLayer(double height, void Function() draw) {
      final PendoloDialProjection p = buildPendoloLayerProjection(
        dial,
        height * parallaxPx,
      );
      canvas.save();
      canvas.transform(
        Float64List.fromList(p.canvasMatrix(hubX, hubY).storage),
      );
      draw();
      canvas.restore();
    }

    // ---- 鼓面光晕：在机芯与歌词之下、抖屏之外（folia 同层次） ----
    if (drum.glow > 0) {
      inLayer(PendoloLayerHeight.dialFace, () {
        paintPendoloDrumHalo(
          canvas,
          drum,
          pendoloWaveReach(hubX, hubY, size),
          fxColor,
        );
      });
    }

    // 抖屏 + 鼓起（以轮心为原点）。
    final Offset shake = drum.shakeOffset(s._rng);
    final bool shaken = shake != Offset.zero || drum.breath != 1;
    if (shaken) {
      canvas.save();
      canvas.translate(hubX + shake.dx, hubY + shake.dy);
      canvas.scale(drum.breath);
      canvas.translate(-hubX, -hubY);
    }

    // ---- 机芯 ----
    final ui.Image? cover = tu.showCover ? s._cover.image : null;
    final PendoloClockworkAnchors anchors = PendoloClockworkAnchors(
      baseRadius,
      ringRadius,
    );
    if (tu.gearDecor != PendoloGearDecor.none ||
        tu.showCenterGradient ||
        cover != null) {
      final PendoloClockworkFrame frame = PendoloClockworkFrame(
        hubX: hubX,
        hubY: hubY,
        anchors: anchors,
        escapementAngle: gearAngle,
        phase: s._motion.phase,
        bassOscillation: s._motion.bassOscillation,
        secondGearAngle: s._motion.secondGearAngle,
        primary: primary,
        accent: accent,
        background: pal.background,
        decor: tu.gearDecor,
        showCenterGradient: tu.showCenterGradient,
        cover: cover,
        mirrored: tu.mirrored,
        dial: dial,
        parallaxScalePx: parallaxPx,
        balanceIcon: c.theme?.glyphIcons.firstOrNull,
      );
      if (tu.lineGlow) {
        _paintGlowing(canvas, size, frame, accent);
      } else {
        paintPendoloClockwork(canvas, frame, s._paths);
      }
    }

    // ---- 鼓面叠加：亮起的刻度圈 / 外圈、宝石闪光（folia drawPendoloBeatFxOverlay2d） ----
    if (drum.tickDialLight > 0 || drum.outerDialLight > 0) {
      inLayer(PendoloLayerHeight.ticks, () {
        paintPendoloDialLights(canvas, drum, baseRadius, gearAngle, fxColor);
      });
    }
    if (drum.jewelFlare > 0.01) {
      for (final PendoloJewel j in pendoloJewels(anchors, gearAngle)) {
        inLayer(j.height, () {
          canvas.translate(j.x, j.y);
          paintPendoloJewelFlare(canvas, drum.jewelFlare, j.small, fxColor);
        });
      }
    }

    // ---- 歌词 ----
    final List<LyricVisualizerLine> lines = c.runtime.lines;
    if (lines.isNotEmpty) {
      _paintLyrics(
        canvas,
        size,
        lines,
        tu,
        tilt,
        parallaxPx,
        hubX,
        hubY,
        baseRadius,
        lyricOffset,
        target,
        railRotationRad,
        wheelRotationDeg,
        primary,
        accent,
        pal.background,
        t,
      );
    }
    if (shaken) canvas.restore();
    s._evictBlocks();
  }

  void _paintLyrics(
    Canvas canvas,
    Size size,
    List<LyricVisualizerLine> lines,
    PendoloTuning tu,
    PendoloDialProjection tilt,
    double parallaxPx,
    double hubX,
    double hubY,
    double baseRadius,
    double lyricOffset,
    double target,
    double railRotationRad,
    double wheelRotationDeg,
    Color primary,
    Color accent,
    Color background,
    int t,
  ) {
    final double w = size.width;
    final double h = size.height;
    final double side = tu.sideSign;
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
    final Color secondary = Color.lerp(primary, background, 0.35)!;
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
      chorus:
          item.isActive &&
          item.index == s._playingLine &&
          lines[item.index].isChorus,
      maxWidth: available / item.scale,
      align: align,
      primary: primary,
      accent: accent,
      secondary: secondary,
    );

    /// 画一句（原点 = 句的锚点，已缩放）：副歌光晕与放大跟着强调进度。
    void paintBlock(
      PendoloLineItem item,
      PendoloLineBlock block,
      Offset origin,
      Offset pivot,
      double opacity,
    ) {
      final PendoloChorusRamp? ramp = s._chorus[item.index];
      final double k = item.isActive ? (ramp?.eased ?? 0) : 0;
      if (k > 0) {
        final double scale = 1 + (s._profile.chorusHaloScale - 1) * k;
        canvas.save();
        canvas.translate(pivot.dx, pivot.dy);
        canvas.scale(scale);
        canvas.translate(-pivot.dx, -pivot.dy);
        _paintChorusHalo(
          canvas,
          block,
          origin,
          accent,
          s._profile.chorusHaloOpacity * k * opacity,
          s._profile.chorusGlow,
          tu.mirrored,
        );
        block.paint(canvas, origin, opacity, t);
        canvas.restore();
      } else {
        block.paint(canvas, origin, opacity, t);
      }
    }

    if (tu.hubView) {
      _paintStanding(
        canvas,
        items,
        blockOf,
        paintBlock,
        lyricLayer,
        hubX,
        hubY,
        railRotationRad,
        wheelRotationDeg,
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
        paintBlock(
          item,
          block,
          Offset(tu.mirrored ? -block.width : 0, -block.height / 2),
          Offset.zero,
          opacity,
        );
        canvas.restore();
      }
      canvas.restore();
    }
  }

  /// folia 副歌光晕：句子外扩 0.7em × 1.1em 的圆角块，强调色径向渐变（中心偏 42% / 镜像 58%），
  /// 再模糊 10px × 光晕倍率。
  void _paintChorusHalo(
    Canvas canvas,
    PendoloLineBlock block,
    Offset origin,
    Color accent,
    double opacity,
    double glow,
    bool mirrored,
  ) {
    if (opacity <= 0.003) return;
    final double em = block.fontPx;
    final Rect r = Rect.fromLTWH(
      origin.dx - 1.1 * em,
      origin.dy - 0.7 * em,
      block.width + 2.2 * em,
      block.height + 1.4 * em,
    );
    final double blur = 10 * glow;
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(16)),
      Paint()
        ..shader =
            RadialGradient(
              center: Alignment(mirrored ? 0.16 : -0.16, 0),
              radius: 0.5,
              colors: <Color>[
                accent.withValues(alpha: 0.14 * opacity),
                accent.withValues(alpha: 0.035 * opacity),
                accent.withValues(alpha: 0),
              ],
              stops: const <double>[0, 0.55, 0.82],
            ).createShader(
              Rect.fromCenter(
                center: r.center,
                width: math.max(r.width, r.height),
                height: math.max(r.width, r.height),
              ),
            )
        ..maskFilter = blur > 0.5
            ? MaskFilter.blur(BlurStyle.normal, blur / 2)
            : null,
    );
  }

  /// 轮心视角：句子立起来正对相机，中点对着自己在弧上的锚点，底边落在锚点上。
  void _paintStanding(
    Canvas canvas,
    List<PendoloLineItem> items,
    PendoloLineBlock Function(PendoloLineItem) blockOf,
    void Function(PendoloLineItem, PendoloLineBlock, Offset, Offset, double)
    paintBlock,
    PendoloDialProjection layer,
    double hubX,
    double hubY,
    double railRotationRad,
    double wheelRotationDeg,
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
      paintBlock(
        e.$2,
        block,
        Offset(-block.width / 2, -block.height),
        Offset.zero,
        e.$4,
      );
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
