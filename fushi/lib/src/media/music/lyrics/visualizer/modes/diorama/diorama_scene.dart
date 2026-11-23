/// 镜台的逐帧场景（folia `VisualizerDiorama.tsx` 的状态机 + `DioramaScene.tsx` 的 useFrame +
/// `dioramaSceneFrame.ts` 的逐帧写入）。持有走廊段、相机、栅格缓存、点云与尘埃，全部逐帧值都在
/// 这里，不进 widget 状态。
///
/// [DioramaScene.step] 产出与后端无关的 [DioramaRenderFrame]：Flutter GPU 渲染器（真 3D，
/// `diorama_gpu.dart`）直接吃它；[DioramaScene.paint] 是 GPU 不可用时的 Canvas 后备实现
/// （2.5D：文字平面取局部仿射近似、点云逐点在 CPU 上投影）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_audio.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_render_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_particles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_sequencer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_text_raster.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_tuning.dart';

/// 段落里已飞过多少行之后可以丢掉。
const int _pruneMarginBehind = 4;

/// 循环 / 回到开头：行下标跳回这里以内才算。
const int _loopRestartMaxIndex = 1;

class _Transition {
  const _Transition(this.outgoingIndex, this.startElapsed);

  final int outgoingIndex;
  final double startElapsed;
}

class _RasterEntry {
  _RasterEntry(this.raster, this.identity, this.wrapEm, this.withUnits);

  final DioramaLineRaster raster;
  final String identity;
  final double wrapEm;
  final bool withUnits;
}

class DioramaScene {
  /// [forGpu]：栅格产出 GPU 纹理、点云跑满预算（GPU 渲染器）；否则走 Canvas 后备实现。
  DioramaScene({this.forGpu = false});

  final bool forGpu;

  LyricVisualizerContext? _ctx;
  LyricVisualizerRuntime? _runtime;
  List<DioramaSceneLine> _lines = const <DioramaSceneLine>[];
  final List<DioramaSceneLine> _phantom = buildDioramaPhantomLines();
  DioramaSettings? _settings;
  LyricVisualizerTuning? _settingsFor;
  LyricVisualizerIntensity? _intensityFor;

  /// 栅格的设备像素比（字图清晰度）。
  double pixelRatio = 1;

  final DioramaSequencer _seq = DioramaSequencer();
  final DioramaCameraRig _rig = DioramaCameraRig();
  int _lastLocal = 0;
  String? _lastKey;
  int _epoch = 0;
  _Transition? _transition;
  int _globalIndex = 0;

  double? _lastElapsed;
  double? _prevPlayback;

  // 阻尼主题色（换歌 / 换色时整景滑过去）。
  bool _colorsInit = false;
  Color _textPrimary = const Color(0xFFFFFFFF);
  Color _textAccent = const Color(0xFFFFFFFF);
  Color _textSecondary = const Color(0xFFFFFFFF);
  Color _bg = const Color(0xFF000000);
  Color _pPrimary = const Color(0xFFFFFFFF);
  Color _pAccent = const Color(0xFFFFFFFF);
  Color _pSecondary = const Color(0xFFFFFFFF);

  final Map<int, _RasterEntry> _rasters = <int, _RasterEntry>{};

  Float64List _light = Float64List(0);
  Float64List _soul = Float64List(0);
  int _unitsFor = -1;

  // 音频（folia 的三个频段追踪器、整体呼吸、歌词跳动）。
  DioramaBandTracker _bassTracker = DioramaBandTracker();
  DioramaBandTracker _midTracker = DioramaBandTracker();
  DioramaBandTracker _trebleTracker = DioramaBandTracker();
  int? _prevTimeMs;
  double _bassSus = 0;
  double _midSus = 0;
  double _trebleSus = 0;
  double _clusterPulse = 1;
  double _powerEnv = 0;
  double _trebleEnv = 0;

  /// 随拍跳起的单元（当前行内下标，-1 = 没有）与它所在的全局行；跳起高度（行高倍数）。
  int _hopUnit = -1;
  int _hopFor = -1;
  double _hop = 0;

  /// 当前行各单元的关键词颜色（folia `keywordUnitColors`），按 [_keywordKey] 缓存。
  Map<int, Color> _keywordColors = const <int, Color>{};
  Object? _keywordKey;

  // 点云
  DioramaParticleGeometry? _geom;
  String _geomKey = '';
  DioramaRipplePool _pool = DioramaRipplePool();
  final DioramaElastic _elastic = DioramaElastic();
  double _flowTime = 0;
  double _formation = 1;
  double _locked = 0.4;
  // 尘埃
  Float32List _motes = Float32List(0);
  List<int> _moteWritten = <int>[];
  String _moteKey = '';
  int _moteRevision = 0;

  bool _disposed = false;

  /// 当前的全局行（测试用）。
  int get globalIndex => _globalIndex;

  /// 走廊段数（测试用）。
  int get segmentCount => _seq.segments.length;

  /// 切歌飞行中（测试用）。
  bool get transitioning => _transition != null;

  void update(LyricVisualizerContext c) {
    _ctx = c;
    if (!identical(c.runtime, _runtime)) {
      _runtime = c.runtime;
      _lines = buildDioramaSceneLines(c.runtime);
      // 新歌有自己的响度：追踪器从头对上它，不带上一首的谷底 / 峰值。
      _bassTracker = DioramaBandTracker();
      _midTracker = DioramaBandTracker();
      _trebleTracker = DioramaBandTracker();
      _prevTimeMs = null;
    }
    if (_settingsFor != c.tuning || _intensityFor != c.intensity) {
      _settingsFor = c.tuning;
      _intensityFor = c.intensity;
      _settings = DioramaSettings.read(c.tuning, c.intensity);
    }
  }

  void dispose() {
    _disposed = true;
    for (final _RasterEntry e in _rasters.values) {
      e.raster.dispose();
    }
    _rasters.clear();
    _sprite?.dispose();
    _glowSprite?.dispose();
    _sprite = null;
    _glowSprite = null;
  }

  // ─── 状态机：切歌 / 循环 / 粘滞行 ──────────────────────────────────────

  void _advance(int timeMs, double now, double elapsed, bool animate) {
    final LyricVisualizerContext c = _ctx!;
    final bool instrumental = _lines.isEmpty;
    final List<DioramaSceneLine> lines = instrumental ? _phantom : _lines;
    final int readHead = instrumental
        ? (now / dioramaInstrumentalSecondsPerFrame).floor().clamp(
            0,
            dioramaInstrumentalFrames - 1,
          )
        : c.runtime.activeLineAt(timeMs);

    final DioramaSegment? out = _seq.active;
    final int outLocal = out == null ? 0 : _lastLocal.clamp(0, out.span - 1);
    final int outGlobal = out == null ? 0 : out.globalStart + outLocal;
    final bool isNewSong = out == null || out.seed != c.seed;
    final bool lyricsChanged = !isNewSong && !identical(out.lines, lines);
    final bool isLoop =
        out != null &&
        !isNewSong &&
        readHead >= 0 &&
        readHead <= _loopRestartMaxIndex &&
        _lastLocal > readHead;
    if (isNewSong) {
      DioramaVec origin = DioramaVec.zero;
      if (out != null) {
        origin =
            dioramaFrameAt(out.frames, outLocal).position +
            dioramaPickTransitionOffset(c.seed, _epoch + 1);
      }
      _seq.append(
        seed: c.seed,
        lines: lines,
        round: 0,
        placementOrigin: origin,
      );
    } else if (lyricsChanged) {
      _seq.updateActiveLines(lines);
    }
    final DioramaSegment active = _seq.active!;
    final bool keyChanged = active.key != _lastKey;
    final bool hadPrevious = _lastKey != null;
    if (keyChanged) {
      _lastKey = active.key;
      _lastLocal = 0;
    }
    if (isLoop) _lastLocal = 0;
    final bool starting = (keyChanged && hadPrevious) || isLoop;
    if (starting && animate) {
      _epoch++;
      _transition = _Transition(outGlobal, elapsed);
    }
    if (readHead >= 0) _lastLocal = readHead;
    final int rawLocal = readHead >= 0 ? readHead : _lastLocal;
    final int local = rawLocal.clamp(0, math.max(active.span - 1, 0));
    _globalIndex = active.globalStart + local;
    if (_transition != null &&
        (!animate ||
            elapsed - _transition!.startElapsed >= dioramaTransitionDuration)) {
      _transition = null;
    }
    final int? outgoing = _transition?.outgoingIndex;
    final int pruneFrom = outgoing != null
        ? math.min(_globalIndex, outgoing)
        : _globalIndex;
    _seq.prune(pruneFrom - _pruneMarginBehind);
  }

  // ─── 音频：频段追踪器生波纹，拍点就绪后拍点接管低 / 中频波纹与整体呼吸 ──────────

  /// folia `DioramaParticleField` 的 useFrame 音频部分 + `DioramaScene` 的歌词跳动选字。
  void _stepAudio(
    LyricVisualizerContext c,
    int timeMs,
    double now,
    double delta,
    bool corridor,
    double gain,
  ) {
    final double? prev = _prevPlayback;
    final bool jump = prev == null || now - prev < -0.05 || now - prev > 0.5;
    final double readHeadAlong =
        _globalIndex * (dioramaStepDistance / dioramaCorridorRadius);
    final LyricVisualizerAudioFrame f = c.audioFrameAt(timeMs);
    // folia：bass、(lowMid + mid) / 2、treble 三个频段（没有分段数据时两段都是合并的 mid）。
    final DioramaBandSignal bass = _bassTracker.step(f.low, delta);
    final DioramaBandSignal mid = _midTracker.step(
      (f.lowMid + f.upperMid) / 2,
      delta,
    );
    final DioramaBandSignal treble = _trebleTracker.step(f.high, delta);
    final (double flowSpeed, double bandPulse) = dioramaParticleAudioResponse(
      bass,
      mid,
    );
    final LyricVisualizerBeats beats = LyricVisualizerBeats.of(c);
    final bool beatFx = beats.hasBeats;
    final int? prevMs = _prevTimeMs;
    final DioramaBeatTriggers fired = beatFx && prevMs != null
        ? dioramaBeatTriggers(beats, prevMs, timeMs, jump: jump)
        : (beat: null, downbeat: null);
    _prevTimeMs = timeMs;
    if (jump) {
      _flowTime = now * 0.28;
      _pool = DioramaRipplePool();
    } else if (now > prev) {
      if (gain > 0.001) {
        final List<DioramaBandSignal> bands = <DioramaBandSignal>[
          bass,
          mid,
          treble,
        ];
        for (int i = 0; i < bands.length; i++) {
          if (!bands[i].onset) continue;
          // 拍点就绪后低 / 中频的波纹归拍点，只有高频还跟频段起音（踩镲不是拍）。
          if (beatFx && i < 2) continue;
          _pool.spawn(
            i,
            bands[i].transient,
            _flowTime,
            corridor: corridor,
            readHeadAlong: readHeadAlong,
          );
        }
        // 每拍一圈：强度按这一拍的重音增益（无节奏段为 0，不生），低频为主的拍生低频尺度。
        for (final LyricVisualizerBeatEvent? e in <LyricVisualizerBeatEvent?>[
          fired.downbeat,
          fired.beat,
        ]) {
          if (e == null) continue;
          final ({int index, double strength}) ripple = dioramaBeatRipple(e);
          if (ripple.strength <= 0) continue;
          _pool.spawn(
            ripple.index,
            ripple.strength,
            _flowTime,
            corridor: corridor,
            readHeadAlong: readHeadAlong,
          );
        }
        // 纯音乐、也没有音频分析时：没有任何起音可读，按 1.25 秒一下给走廊一点起伏。
        final DioramaResolvedLine? r = _seq.resolve(_globalIndex);
        final bool phantom =
            f.fallback &&
            _lines.isEmpty &&
            r != null &&
            r.segment.lines.isNotEmpty &&
            !r.segment.lines.first.hasText;
        if (phantom && (now / 1.25).floor() > (prev / 1.25).floor()) {
          _pool.spawn(
            1,
            0.6,
            _flowTime,
            corridor: corridor,
            readHeadAlong: readHeadAlong,
          );
        }
      }
      _flowTime += (now - prev) * flowSpeed;
    }
    _prevPlayback = now;
    _bassSus = bass.sustained;
    _midSus = mid.sustained;
    _trebleSus = treble.sustained;
    // 拍钟包络（folia：按每拍重音增益冲顶、160 / 200 ms 衰减）。
    final double beatEnv = beatFx ? beats.beatImpactAt(timeMs) : 0;
    final double downEnv = beatFx ? beats.downbeatImpactAt(timeMs) : 0;
    _clusterPulse = beatFx
        ? dioramaBeatClusterPulse(beatEnv, downEnv)
        : bandPulse;
    // 歌词跳动：拍落下时选中正在唱的单元（拍落在字之间就取最后开唱的），跳到拍衰减完。
    if (fired.beat != null || fired.downbeat != null) {
      final DioramaResolvedLine? r = _seq.resolve(_globalIndex);
      int picked = -1;
      if (r != null && r.localIndex < r.segment.lines.length) {
        final List<DioramaUnit> units = r.segment.lines[r.localIndex].units;
        for (int i = 0; i < units.length; i++) {
          if (units[i].start <= now) picked = i;
        }
      }
      _hopUnit = picked;
      _hopFor = _globalIndex;
    }
    _hop = beatFx ? dioramaLyricHop(beatEnv, downEnv) : 0;
    _powerEnv = dioramaStepEnvelope(
      _powerEnv,
      math.min(1, f.power) * gain,
      18,
      3.5,
      delta,
    );
    _trebleEnv = dioramaStepEnvelope(
      _trebleEnv,
      math.min(1, f.high) * gain,
      14,
      3.2,
      delta,
    );
  }

  // ─── 栅格缓存 ──────────────────────────────────────────────────────────

  double _wrapEm(double aspect, DioramaTextPlacement p, double fontScale) {
    final double frameWidth =
        2 *
        dioramaHeroDistance *
        math.tan(dioramaFovDeg * math.pi / 360) *
        aspect;
    final double em =
        frameWidth *
        0.9 /
        (dioramaMinFitScale * p.scale * fontScale * dioramaLineFontSize);
    return em.floorToDouble().clamp(4.0, 400.0);
  }

  DioramaLineRaster? _rasterFor(
    DioramaVisibleLine v,
    double wrapEm, {
    required bool withUnits,
    required bool force,
    required List<int> budget,
  }) {
    final String identity =
        '${v.segment.key}:${v.segment.linesEpoch}:${v.localIndex}';
    final _RasterEntry? e = _rasters[v.index];
    if (e != null &&
        e.identity == identity &&
        e.wrapEm == wrapEm &&
        (!withUnits || e.withUnits)) {
      return e.raster;
    }
    if (!force && budget[0] <= 0) {
      return e?.identity == identity ? e!.raster : null;
    }
    budget[0]--;
    final DioramaLineRaster r = DioramaLineRaster.build(
      v.line,
      fontPx: 64 * pixelRatio.clamp(1.0, 2.0),
      wrapEm: wrapEm,
      withUnits: withUnits,
      forGpu: forGpu,
    );
    e?.raster.dispose();
    _rasters[v.index] = _RasterEntry(r, identity, wrapEm, withUnits);
    return r;
  }

  // ─── 每帧 ──────────────────────────────────────────────────────────────

  /// 推进一帧并产出要画的东西；没东西可画（未就绪 / 尺寸为空 / 已释放）时为 null。
  DioramaRenderFrame? step(Size size, LyricVisualizerTick tick) {
    final LyricVisualizerContext? c = _ctx;
    final DioramaSettings? s = _settings;
    if (_disposed || c == null || s == null || size.isEmpty) return null;
    final bool animate = c.motion;
    final double elapsed = tick.elapsed;
    final double delta = animate && _lastElapsed != null
        ? (elapsed - _lastElapsed!).clamp(0.0, 0.1)
        : 0;
    _lastElapsed = elapsed;
    final double now = tick.timeMs / 1000;
    final DioramaMotionParams motion = s.motion;
    final double aspect = size.width / size.height;

    _advance(tick.timeMs, now, elapsed, animate);
    _stepColors(c.palette, animate ? delta : -1);

    final int gi = _globalIndex;
    final int? outgoing = _transition?.outgoingIndex;
    final List<int> mounted = dioramaMountedIndices(
      gi,
      outgoing,
      _seq.totalLines,
    );
    final List<DioramaVisibleLine> visible = dioramaVisibleLines(
      _seq,
      mounted,
      gi,
      outgoing,
      motion.weaveScale,
    );
    final Set<int> mountedSet = mounted.toSet();
    _rasters.removeWhere((int k, _RasterEntry e) {
      if (mountedSet.contains(k)) return false;
      e.raster.dispose();
      return true;
    });

    // 当前行：栅格（含逐单元图集）与世界宽度（相机按它定横移幅度）。
    DioramaVisibleLine? activeEntry;
    for (final DioramaVisibleLine v in visible) {
      if (v.index == gi) activeEntry = v;
    }
    final List<int> budget = <int>[dioramaNeighborRasterBudget];
    DioramaLineRaster? activeRaster;
    double activeFit = 1;
    double activeWidth = 0;
    if (activeEntry != null && activeEntry.line.hasText) {
      activeRaster = _rasterFor(
        activeEntry,
        _wrapEm(aspect, activeEntry.placement, c.fontScale),
        withUnits: true,
        force: true,
        budget: budget,
      );
      if (activeRaster != null) {
        final double wpp = dioramaLineFontSize / activeRaster.fontPx;
        activeFit =
            dioramaFrameFitScale(
              activeRaster.width * wpp,
              dioramaHeroDistance,
              dioramaFovDeg,
              aspect,
            ) *
            activeEntry.placement.scale *
            c.fontScale;
        activeWidth = activeRaster.width * wpp * activeFit;
      }
    }

    final DioramaCamera camera = _rig.step(
      resolved: _seq.resolve(gi),
      now: now,
      delta: delta,
      elapsed: elapsed,
      motion: motion,
      animate: animate,
      activeLineWidth: activeWidth,
      transitionEpoch: _epoch,
      width: size.width,
      height: size.height,
    );

    DioramaMotesDraw? motes;
    DioramaParticlesDraw? particles;
    if (animate) {
      final bool corridor = s.geometry.corridor;
      final double gain = motion.audioLevel;
      _stepAudio(c, tick.timeMs, now, delta, corridor, gain);
      if (s.showParticles) motes = _stepMotes(s, elapsed);
      if (s.geometry.enabled) {
        final double pulseScale = _elastic.step(
          dioramaPulseTarget(_clusterPulse, gain, corridor),
          delta,
        );
        final bool transitioning = _transition != null;
        _locked = transitioning ? 0 : math.min(0.4, _locked + delta);
        _formation = dioramaStepEnvelope(
          _formation,
          !transitioning && _locked >= 0.4 ? 1 : 0,
          1.5,
          3.2,
          delta,
        );
        final DioramaParticleGeometry? g = _stepGeometry(s, mounted, outgoing);
        if (g != null && g.count > 0) {
          particles = DioramaParticlesDraw(
            geometry: g,
            pool: _pool,
            palette: <ui.Color>[_pPrimary, _pAccent, _pSecondary],
            frame: DioramaParticleFrame(
              time: _flowTime,
              amplitude:
                  gain *
                  (corridor
                      ? math.min(0.45, 0.1 + _bassSus * 0.18 + _midSus * 0.08)
                      : 0.34),
              maxSwell: 0.85 * (corridor ? 0.45 : 0.34),
              offsetGain: _midSus * gain,
              flow: corridor ? 1 : 0,
              formation: _formation,
              scatter: corridor ? 6 : 1.4,
              pulse: pulseScale,
              sizeBase: corridor ? 0.072 : 0.05,
              sizeGain: corridor ? 0.34 : 0.3,
              glowIntensity: s.particleGlowIntensity,
              // folia：高频持续能量当亮度代理（调色板偏热色）、也决定浪尖上的细纹。
              centroid: math.min(1, 0.2 + _trebleSus * 0.8),
              detail: math.min(1, _trebleSus * gain),
            ),
          );
        }
      }
    }

    final List<DioramaPlane> planes = <DioramaPlane>[];
    _neighborPlanes(
      planes,
      camera,
      visible,
      gi,
      outgoing,
      aspect,
      c.fontScale,
      budget,
    );
    if (activeEntry != null && activeRaster != null) {
      _activePlanes(
        planes,
        camera,
        activeEntry,
        activeRaster,
        activeFit,
        now,
        delta,
        elapsed,
        animate,
        s,
      );
    }
    return DioramaRenderFrame(
      camera: camera,
      fogColor: _bg,
      motes: motes,
      particles: particles,
      planes: planes,
    );
  }

  void _stepColors(LyricVisualizerPalette p, double delta) {
    final Color pp = dioramaEnsureContrast(p.primary, p.background);
    final Color pa = dioramaEnsureContrast(p.accent, p.background);
    final Color ps = dioramaEnsureContrast(p.secondary, p.background);
    if (!_colorsInit || delta < 0) {
      _colorsInit = true;
      _textPrimary = p.text;
      _textAccent = p.accent;
      _textSecondary = p.secondary;
      _bg = p.background;
      _pPrimary = pp;
      _pAccent = pa;
      _pSecondary = ps;
      return;
    }
    final double k = 1 - math.exp(-dioramaColorDampRate * delta);
    _textPrimary = Color.lerp(_textPrimary, p.text, k)!;
    _textAccent = Color.lerp(_textAccent, p.accent, k)!;
    _textSecondary = Color.lerp(_textSecondary, p.secondary, k)!;
    _bg = Color.lerp(_bg, p.background, k)!;
    _pPrimary = Color.lerp(_pPrimary, pp, k)!;
    _pAccent = Color.lerp(_pAccent, pa, k)!;
    _pSecondary = Color.lerp(_pSecondary, ps, k)!;
  }

  // ─── 背景尘埃 ──────────────────────────────────────────────────────────

  DioramaMotesDraw? _stepMotes(DioramaSettings s, double elapsed) {
    final DioramaSegment? seg = _seq.active;
    if (seg == null) return null;
    final int per = s.moteCircumference * s.moteRadial;
    final String key = '${s.moteCircumference}x${s.moteRadial}@${seg.key}';
    if (key != _moteKey) {
      _moteKey = key;
      _motes = Float32List(dioramaMoteWindowLines * per * 3);
      _moteWritten = List<int>.filled(dioramaMoteWindowLines, -1 << 30);
      _moteRevision++;
    }
    final int last = math.max(0, _seq.totalLines - 1);
    for (
      int line = _globalIndex - dioramaMoteLinesBehind;
      line <= _globalIndex + dioramaMoteLinesAhead;
      line++
    ) {
      final int slot = dioramaMoteSlot(line);
      if (_moteWritten[slot] == line) continue;
      final int anchor = line.clamp(0, last);
      final DioramaResolvedLine? r = _seq.resolve(anchor);
      if (r == null) continue;
      dioramaWriteMoteLine(
        _motes,
        r.frame.extended(line - anchor),
        line,
        s.moteCircumference,
        s.moteRadial,
        seg.seed,
      );
      _moteWritten[slot] = line;
      _moteRevision++;
    }
    return DioramaMotesDraw(
      positions: _motes,
      revision: _moteRevision,
      ox: math.sin(elapsed * 0.17) * 0.12,
      oy: math.sin(elapsed * 0.11 + 1.7) * 0.09,
      oz: math.cos(elapsed * 0.13) * 0.12,
      color: Color.lerp(_pSecondary, _pAccent, 0.3)!,
      alpha: 0.16 + 0.18 * _powerEnv,
      sizeWorld: 0.03 * (1 + 0.42 * _trebleEnv),
    );
  }

  // ─── 点云阵列 / 长廊 ───────────────────────────────────────────────────

  DioramaParticleGeometry? _stepGeometry(
    DioramaSettings s,
    List<int> mounted,
    int? outgoing,
  ) {
    final DioramaSegment? seg = _seq.active;
    final String key = <Object?>[
      s.geometry.corridor,
      s.geometry.strands,
      s.geometry.blobs,
      s.geometry.ribbons,
      s.geometry.rings,
      s.particleDensity,
      s.particleScale,
      s.motion.weaveScale,
      s.motion.subMode,
      _globalIndex,
      outgoing,
      _seq.totalLines,
      seg?.key,
      seg?.linesEpoch,
    ].join('|');
    if (key != _geomKey) {
      _geomKey = key;
      final double share = forGpu ? 1.0 : dioramaCpuPointShare;
      if (s.geometry.corridor) {
        final List<DioramaCorridorSpan> spans = <DioramaCorridorSpan>[
          if (outgoing != null) ...dioramaCorridorWindow(_seq, outgoing),
          ...dioramaCorridorWindow(_seq, _globalIndex),
        ];
        _geom = DioramaParticleGeometry.corridorTunnel(
          spans,
          s.particleDensity,
          share: share,
        );
      } else {
        _geom = DioramaParticleGeometry.clouds(
          dioramaBuildClusters(
            _seq,
            mounted,
            s.motion,
            s.geometry,
            s.particleScale,
          ),
          s.particleDensity,
          share: share,
        );
      }
    }
    return _geom;
  }

  // ─── 文字平面 ──────────────────────────────────────────────────────────

  void _neighborPlanes(
    List<DioramaPlane> out,
    DioramaCamera camera,
    List<DioramaVisibleLine> visible,
    int gi,
    int? outgoing,
    double aspect,
    double fontScale,
    List<int> budget,
  ) {
    for (final DioramaVisibleLine v in visible) {
      if (v.index == gi || !v.line.hasText) continue;
      final int offset = v.index - gi;
      final double opacity = v.isOutgoing
          ? dioramaOutgoingLineOpacity(v.index - (outgoing ?? v.index))
          : dioramaNeighborLineOpacity(offset);
      if (opacity <= 0) continue;
      final DioramaLineRaster? r = _rasterFor(
        v,
        _wrapEm(aspect, v.placement, fontScale),
        // GPU 纹理异步就绪：下一句连逐单元图集一起预热，轮到它当当前行时已经可画。
        withUnits: forGpu && offset == 1 && !v.isOutgoing,
        force: v.isOutgoing && v.index == outgoing,
        budget: budget,
      );
      if (r == null) continue;
      final double wpp = dioramaLineFontSize / r.fontPx;
      final double fit =
          dioramaFrameFitScale(
            r.width * wpp,
            dioramaHeroDistance,
            dioramaFovDeg,
            aspect,
          ) *
          v.placement.scale *
          fontScale;
      final double dist = v.position.distanceTo(camera.position);
      final double alpha = opacity * dioramaTextLife(dist);
      if (alpha < 0.004) continue;
      final Rect full = Offset.zero & r.lineSize;
      out.add(
        DioramaPlane(
          raster: r,
          layer: DioramaRasterLayer.line,
          src: full,
          dst: full,
          anchor: full.center,
          world: v.position,
          right: v.orientation.rotate(const DioramaVec(1, 0, 0)),
          up: v.orientation.rotate(const DioramaVec(0, 1, 0)),
          scale: wpp * fit,
          color: v.isOutgoing || offset < 0 ? _textPrimary : _textSecondary,
          alpha: alpha,
          additive: false,
          depthTest: true,
          cpuFog: true,
          renderOrder: DioramaRenderOrder.neighbor,
          sortDepth: dist,
        ),
      );
    }
  }

  void _activePlanes(
    List<DioramaPlane> out,
    DioramaCamera camera,
    DioramaVisibleLine entry,
    DioramaLineRaster raster,
    double fit,
    double now,
    double delta,
    double elapsed,
    bool animate,
    DioramaSettings s,
  ) {
    if (raster.atlasSize == null) return;
    final List<DioramaUnit> units = entry.line.units;
    if (_unitsFor != entry.index || _light.length != units.length) {
      _unitsFor = entry.index;
      _light = Float64List(units.length);
      _soul = Float64List(units.length);
    }
    final double wpp = dioramaLineFontSize / raster.fontPx;
    final double scale = wpp * fit;
    final DioramaVec rt = entry.orientation.rotate(const DioramaVec(1, 0, 0));
    final DioramaVec ut = entry.orientation.rotate(const DioramaVec(0, 1, 0));
    final double dist = entry.position.distanceTo(camera.position);
    final double life = dioramaTextLife(dist);
    final double breath = animate ? 0.9 + 0.1 * math.sin(elapsed * 1.9) : 1;

    // 关键词配色：主题 wordColors 命中的单元以自己的颜色为跟唱目标（按目标配色算、换行 / 换主题
    // 才重算）。
    final LyricVisualizerContext? ctx = _ctx;
    final Object kwKey = Object.hash(
      entry.index,
      entry.line.layoutText,
      s.keywordColoring ? ctx?.theme : null,
      ctx?.palette,
    );
    if (kwKey != _keywordKey) {
      _keywordKey = kwKey;
      final LyricVisualizerPalette? p = ctx?.palette;
      _keywordColors = s.keywordColoring && p != null
          ? dioramaKeywordUnitColors(
              ctx?.theme,
              entry.line.layoutText,
              <(int, int)>[
                for (final DioramaUnit u in units) (u.charStart, u.charEnd),
              ],
              dioramaEnsureContrast(p.primary, p.background),
              dioramaEnsureContrast(p.accent, p.background),
              p.background,
            )
          : const <int, Color>{};
    }
    // 跟唱色：一般就是强调色；强调色与主文字色几乎一样时（灰阶主题）往一个明度错开的中性灰靠。
    final Color primary = _textPrimary;
    Color sungTint = _textAccent;
    final double sep =
        (sungTint.r - primary.r).abs() +
        (sungTint.g - primary.g).abs() +
        (sungTint.b - primary.b).abs();
    if (sep < 0.4) {
      final double deficit = 1 - sep / 0.4;
      final double pl = (primary.r + primary.g + primary.b) / 3;
      final double al = (sungTint.r + sungTint.g + sungTint.b) / 3;
      final double target = pl > 0.5
          ? al * (1 - 0.5 * deficit)
          : al + (1 - al) * 0.55 * deficit;
      sungTint = Color.lerp(
        sungTint,
        Color.from(alpha: 1, red: target, green: target, blue: target),
        deficit,
      )!;
    }
    final double gradStrength = math.min(1.5, s.gradientIntensity);
    final double gradHot = ((gradStrength - 0.1) / 1.4).clamp(0.0, 1.0);
    final double deepK = 0.8 - 0.18 * gradHot;
    final Color gradDeep = Color.from(
      alpha: 1,
      red: sungTint.r * deepK,
      green: sungTint.g * deepK,
      blue: sungTint.b * deepK,
    );
    final double glowStrength = math.min(1.5, s.glowIntensity);
    final double soulStrength = math.min(1.5, s.soulIntensity);

    for (int i = 0; i < units.length && i < raster.units.length; i++) {
      final DioramaPlacedUnit? pu = raster.units[i];
      if (pu == null) continue;
      final DioramaUnit u = units[i];
      final bool isCurrent = now >= u.start && now < u.end;
      final bool sung = now >= u.end;
      final double span = math.max(u.end - u.start, 0.001);
      final double sungMix = sung
          ? 1
          : (isCurrent ? dioramaClamp01((now - u.start) / span) : 0);
      _light[i] = animate
          ? dioramaStepEnvelope(_light[i], isCurrent ? 1 : 0, 14, 4.5, delta)
          : (isCurrent ? 1 : 0);
      final double gradEnergy =
          dioramaGradientEnergy(now, u.start, u.end) * gradStrength;
      final double baseOpacity = math.min(
        1.0,
        (dioramaUnsungUnitOpacity +
                (dioramaActiveLineOpacity - dioramaUnsungUnitOpacity) *
                    sungMix +
                0.08 * math.min(1.0, gradEnergy)) *
            life,
      );
      final Color target =
          _keywordColors[i] ?? (s.gradientIntensity > 0 ? gradDeep : sungTint);
      final double progress = s.gradientIntensity > 0
          ? gradEnergy
          : _light[i] * 1.15;
      final Color fill = Color.lerp(primary, target, dioramaClamp01(progress))!;

      // 随拍跳起（folia 歌词跳动）：只有拍落下时正在唱的那个单元，跳单元高度的 _hop 倍。
      final double lift = animate && _hopFor == entry.index && i == _hopUnit
          ? _hop * pu.height * scale
          : 0;
      final DioramaVec world =
          entry.position +
          rt * (pu.layoutCenter.dx * scale) +
          ut * (-pu.layoutCenter.dy * scale + lift);
      DioramaPlane plane(
        DioramaRasterLayer layer,
        Rect dst,
        double alpha,
        bool additive,
        int order,
      ) => DioramaPlane(
        raster: raster,
        layer: layer,
        src: pu.atlasRect,
        dst: dst,
        anchor: pu.atlasCenter,
        world: world,
        right: rt,
        up: ut,
        scale: scale,
        color: fill,
        alpha: alpha,
        additive: additive,
        depthTest: false,
        cpuFog: false,
        renderOrder: order,
        sortDepth: dist,
      );
      if (baseOpacity > 0.004) {
        out.add(
          plane(
            DioramaRasterLayer.units,
            pu.atlasRect,
            baseOpacity,
            false,
            DioramaRenderOrder.unitBase,
          ),
        );
      }
      // 普通辉光：叠加的模糊字，永远不移位（移位是灵魂出窍的事）。
      final double glowLevel =
          _light[i] * life * breath * (0.6 + 0.4 * _powerEnv) * glowStrength;
      if (glowLevel > 0.012) {
        out.add(
          plane(
            DioramaRasterLayer.glow,
            pu.atlasRect,
            math.min(1.0, dioramaUnitGlowMaxOpacity * glowLevel),
            true,
            DioramaRenderOrder.unitGlow,
          ),
        );
      }
      // 灵魂出窍：唱时按「当前字出窍」开关决定是否离体，唱完的字飘起、膨胀、淡去。
      _soul[i] = animate
          ? dioramaStepEnvelope(_soul[i], isCurrent ? 1 : 0, 12, 2.2, delta)
          : 0;
      if (animate && soulStrength > 0) {
        final double flightMix = sung
            ? dioramaSmoothstep01((now - u.end) / dioramaSoulHandoffSeconds)
            : 0;
        final double activeReach = s.soulActiveEnabled ? soulStrength : 0;
        final double onGlyph = (1 - flightMix) * activeReach;
        final double flown = flightMix * soulStrength;
        final double soulOpacity = math.min(
          1.0,
          dioramaSoulMaxOpacity * life * _soul[i] * (onGlyph + flown),
        );
        if (soulOpacity > 0.015) {
          final double liftPx =
              raster.fontPx *
              (dioramaSoulActiveLiftEm * onGlyph +
                  dioramaSoulDetachLiftEm * flown);
          final double swell =
              1 +
              dioramaSoulActiveSwell * onGlyph +
              dioramaSoulDetachSwell * flown;
          // 以单元中心为原点放大 swell 倍、再上抬 liftPx（栅格像素）。
          final Offset a = pu.atlasCenter;
          final Rect r = pu.atlasRect;
          final Rect dst = Rect.fromLTRB(
            a.dx + (r.left - a.dx) * swell,
            a.dy - liftPx + (r.top - a.dy) * swell,
            a.dx + (r.right - a.dx) * swell,
            a.dy - liftPx + (r.bottom - a.dy) * swell,
          );
          out.add(
            plane(
              DioramaRasterLayer.units,
              dst,
              soulOpacity,
              true,
              DioramaRenderOrder.unitSoul,
            ),
          );
        }
      }
    }
  }

  // ─── Canvas 后备实现（GPU 不可用时） ────────────────────────────────────

  final DioramaPointBatch _contrast = DioramaPointBatch();
  final DioramaPointBatch _glow = DioramaPointBatch();
  final DioramaPointBatch _moteBatch = DioramaPointBatch();
  ui.Image? _sprite;
  ui.Image? _glowSprite;
  static const double _spriteSize = 64;

  /// 推进一帧并用 Canvas 画出来（2.5D 近似）。
  void paint(Canvas canvas, Size size, LyricVisualizerTick tick) {
    final DioramaRenderFrame? f = step(size, tick);
    if (f == null) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final DioramaMotesDraw? motes = f.motes;
    final DioramaParticlesDraw? particles = f.particles;
    if (motes != null || particles != null) {
      _sprite ??= buildDioramaSprite(glow: false);
      _glowSprite ??= buildDioramaSprite(glow: true);
    }
    if (motes != null) _paintMotes(canvas, f.camera, motes);
    if (particles != null) _paintParticles(canvas, f.camera, particles);
    for (final DioramaPlane p in f.planes) {
      _paintPlane(canvas, f.camera, p);
    }
    canvas.restore();
  }

  void _paintMotes(Canvas canvas, DioramaCamera camera, DioramaMotesDraw m) {
    final Float32List pos = m.positions;
    final int n = pos.length ~/ 3;
    _moteBatch.reset(n, _spriteSize);
    for (int i = 0; i < n; i++) {
      final (double xc, double yc, double depth) = camera.toView(
        pos[i * 3] + m.ox,
        pos[i * 3 + 1] + m.oy,
        pos[i * 3 + 2] + m.oz,
      );
      if (depth <= DioramaCamera.near) continue;
      final double sx = camera.width / 2 + xc / depth * camera.focal;
      final double sy = camera.height / 2 - yc / depth * camera.focal;
      if (sx < -8 ||
          sy < -8 ||
          sx > camera.width + 8 ||
          sy > camera.height + 8) {
        continue;
      }
      final double fog = dioramaFogFactor(depth);
      final double a = m.alpha * (1 - fog);
      if (a < 0.01) continue;
      final double px = (m.sizeWorld * camera.height / 2 / depth).clamp(
        1.0,
        5.0,
      );
      _moteBatch.add(
        sx,
        sy,
        px,
        _spriteSize,
        m.color.withValues(alpha: a).toARGB32(),
      );
    }
    _moteBatch.draw(
      canvas,
      _sprite!,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  void _paintParticles(
    Canvas canvas,
    DioramaCamera camera,
    DioramaParticlesDraw p,
  ) {
    dioramaEvaluateParticles(
      geometry: p.geometry,
      pool: p.pool,
      f: p.frame,
      camera: camera,
      palette: p.palette,
      contrast: _contrast,
      glow: _glow,
      spriteSize: _spriteSize,
    );
    if (p.frame.glowIntensity > 0) {
      _glow.draw(canvas, _glowSprite!, Paint()..blendMode = BlendMode.plus);
    }
    _contrast.draw(
      canvas,
      _sprite!,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  /// 把栅格平面在 [DioramaPlane.world] 处的透视取局部仿射近似，返回画布矩阵；看不到（在镜头
  /// 后、背面朝向）时为 null。
  static Float64List? _planeMatrix(DioramaCamera camera, DioramaPlane p) {
    final (double xc, double yc, double depth) = camera.toView(
      p.world.x,
      p.world.y,
      p.world.z,
    );
    if (depth <= 0.25) return null;
    final double k = camera.focal;
    final double sx = camera.width / 2 + xc / depth * k;
    final double sy = camera.height / 2 - yc / depth * k;
    if ((sx - camera.width / 2).abs() > camera.width * 2.5 ||
        (sy - camera.height / 2).abs() > camera.height * 2.5) {
      return null;
    }
    final (double rx, double ry, double rd) = camera.dirToView(p.right);
    final (double ux, double uy, double ud) = camera.dirToView(p.up);
    final double d2 = depth * depth;
    final double s = p.scale;
    final double a = k * (rx * depth - xc * rd) / d2 * s;
    final double b = -k * (ry * depth - yc * rd) / d2 * s;
    final double cc = -k * (ux * depth - xc * ud) / d2 * s;
    final double dd = k * (uy * depth - yc * ud) / d2 * s;
    if (a * dd - b * cc <= 0) return null;
    final double tx = sx - (a * p.anchor.dx + cc * p.anchor.dy);
    final double ty = sy - (b * p.anchor.dx + dd * p.anchor.dy);
    return Float64List.fromList(<double>[
      a,
      b,
      0,
      0,
      cc,
      dd,
      0,
      0,
      0,
      0,
      1,
      0,
      tx,
      ty,
      0,
      1,
    ]);
  }

  void _paintPlane(Canvas canvas, DioramaCamera camera, DioramaPlane p) {
    final ui.Image? image = switch (p.layer) {
      DioramaRasterLayer.line => p.raster.lineImage,
      DioramaRasterLayer.units => p.raster.unitAtlas,
      DioramaRasterLayer.glow => p.raster.glowAtlas,
    };
    if (image == null) return;
    final double alpha = p.cpuFog
        ? p.alpha * (1 - dioramaFogFactor(p.sortDepth))
        : p.alpha;
    if (alpha < 0.004) return;
    final Float64List? m = _planeMatrix(camera, p);
    if (m == null) return;
    canvas.save();
    canvas.transform(m);
    final Paint paint = Paint()
      ..color = Color.from(alpha: alpha, red: 1, green: 1, blue: 1)
      ..colorFilter = ColorFilter.mode(p.color, BlendMode.srcIn);
    if (p.additive) paint.blendMode = BlendMode.plus;
    if (p.layer != DioramaRasterLayer.glow) {
      paint.filterQuality = FilterQuality.medium;
    }
    canvas.drawImageRect(image, p.src, p.dst, paint);
    canvas.restore();
  }
}
