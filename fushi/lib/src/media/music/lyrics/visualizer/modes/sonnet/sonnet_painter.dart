/// 商籁的逐帧绘制（folia `SonnetVisualizer.tsx` 的 ticker + `sonnetShotUpdate.ts` +
/// `sonnetPostProcess.ts`）：按时间选段 / 镜头，算镜头运动与跟焦，画 MG、逐字入场、导引线，
/// 再叠转场（淡 / 模糊 / 故障条）、后期、片尾海报与外框。场景缓存在 [SonnetDirector]。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_decor.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_mg.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_typography.dart';

/// 场景缓存 + 构建输入。尺寸 / 参数 / 配色 / 字号变化时整体作废。
class SonnetDirector {
  SonnetDirector({
    required this.runtime,
    required this.program,
    this.title,
    this.artist,
    this.album,
    String? fontFamily,
    FontWeight? fontWeight,
  }) : finalEnd = _finalEndOf(program),
       measurer = SonnetTextMeasurer(
         fontFamily: fontFamily,
         manualWeight: fontWeight,
       );

  final LyricVisualizerRuntime runtime;
  final SonnetProgram program;
  final String? title;
  final String? artist;
  final String? album;

  /// 末句结束（秒）；纯音乐的虚拟「♪」行不触发片尾。
  final double finalEnd;

  final SonnetTextMeasurer measurer;
  final Map<int, SonnetSceneView> _scenes = <int, SonnetSceneView>{};
  SonnetSceneInputs? _inputs;
  final List<TextPainter> _poster = <TextPainter>[];

  static double _finalEndOf(SonnetProgram p) {
    double end = 0;
    for (final SonnetParagraph para in p.paragraphs) {
      for (final SonnetCompiledLine l in para.lines) {
        if (l.text.trim() == '♪') continue;
        end = math.max(end, l.renderEnd);
      }
    }
    return end <= 0 ? double.infinity : end;
  }

  /// 每帧调用：输入变了就清缓存。
  void configure({
    required Size size,
    required SonnetSettings settings,
    required SonnetColors colors,
    required double fontScale,
    required bool motion,
  }) {
    final SonnetSceneInputs? old = _inputs;
    if (old != null &&
        old.size == size &&
        old.settings == settings &&
        old.colors == colors &&
        old.fontScale == fontScale &&
        old.motion == motion) {
      return;
    }
    _clearScenes();
    _clearPoster();
    _inputs = SonnetSceneInputs(
      program: program,
      size: size,
      settings: settings,
      colors: colors,
      measurer: measurer,
      fontScale: fontScale,
      motion: motion,
      title: title,
      artist: artist,
      album: album,
    );
  }

  SonnetSceneInputs get inputs => _inputs!;

  int get cachedSceneCount => _scenes.length;

  /// 第 [index] 段的场景；只留 ±1 段，每帧最多顺带预建一个邻段。
  SonnetSceneView sceneAt(int index) {
    final SonnetSceneView scene = _scenes[index] ??= buildSonnetScene(
      inputs,
      index,
    );
    final List<int> stale = _scenes.keys
        .where((int k) => (k - index).abs() > 1)
        .toList();
    for (final int k in stale) {
      _scenes.remove(k)?.dispose();
    }
    final int next = index + 1;
    if (next < program.paragraphs.length && !_scenes.containsKey(next)) {
      _scenes[next] = buildSonnetScene(inputs, next);
    }
    return scene;
  }

  /// 片尾海报的三行字（曲名 / 艺人 / 专辑）。
  List<TextPainter> posterLines() {
    if (_poster.isNotEmpty) return _poster;
    final SonnetSceneInputs i = inputs;
    final double w = i.size.width;
    final List<(String, int, double, Color)> rows =
        <(String, int, double, Color)>[
          (
            (title ?? '').trim(),
            900,
            (w * 0.07).clamp(28.0, 96.0),
            i.colors.primary,
          ),
          (
            (artist ?? '').trim(),
            700,
            (w * 0.028).clamp(14.0, 32.0),
            i.colors.secondary,
          ),
          (
            (album ?? '').trim(),
            300,
            (w * 0.02).clamp(12.0, 22.0),
            i.colors.accent,
          ),
        ];
    for (final (String text, int weight, double size, Color color) in rows) {
      if (text.isEmpty) continue;
      final TextPainter p = TextPainter(
        text: TextSpan(
          text: text,
          style: measurer.styleFor(weight, size).copyWith(color: color),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: w * 0.8);
      _poster.add(p);
    }
    return _poster;
  }

  void _clearScenes() {
    for (final SonnetSceneView s in _scenes.values) {
      s.dispose();
    }
    _scenes.clear();
  }

  void _clearPoster() {
    for (final TextPainter p in _poster) {
      p.dispose();
    }
    _poster.clear();
  }

  void dispose() {
    _clearScenes();
    _clearPoster();
  }
}

/// 后期着色器（`shaders/visualizer_sonnet_post.frag`）。加载失败（如 widget 测试没打包着色器）
/// 返回 null，后期退回 CPU 近似。
Future<ui.FragmentProgram?>? _postProgramLoad;
ui.FragmentProgram? _postProgram;

void ensureSonnetPostProgram() {
  _postProgramLoad ??=
      ui.FragmentProgram.fromAsset(
        'shaders/visualizer_sonnet_post.frag',
      ).then<ui.FragmentProgram?>(
        (ui.FragmentProgram p) => _postProgram = p,
        onError: (Object e) {
          debugPrint('[sonnet] post shader unavailable: $e');
          return null;
        },
      );
}

class SonnetPainter extends CustomPainter {
  SonnetPainter({
    required this.director,
    required this.ticks,
    required this.settings,
    required this.colors,
    required this.fontScale,
    required this.motion,
    required this.devicePixelRatio,
    required this.visualizer,
    required this.beatReader,
    this.animationScale = 1,
  }) : super(repaint: ticks);

  final SonnetDirector director;
  final LyricVisualizerTicks ticks;
  final SonnetSettings settings;
  final SonnetColors colors;
  final double fontScale;
  final bool motion;
  final double devicePixelRatio;

  /// 样式输入（取音频帧 / 节拍网格）。
  final LyricVisualizerContext visualizer;

  /// 随拍特效读取器（持有高频平滑状态，跨帧复用）。
  final SonnetBeatFxReader beatReader;

  /// 主题强度倍数（folia `resolveSonnetAnimationScale`）：乘在镜头与字效上。
  final double animationScale;

  static final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || director.program.paragraphs.isEmpty) return;
    director.configure(
      size: size,
      settings: settings,
      colors: colors,
      fontScale: fontScale,
      motion: motion,
    );
    final int timeMs = ticks.value.timeMs;
    final double time = timeMs / 1000;
    final SonnetProgram program = director.program;
    final int index = program.paragraphIndexAt(time);
    final SonnetSceneView scene = director.sceneAt(index);
    final int shotIndex = findSonnetActiveShotIndex(
      scene.paragraph.shots,
      time,
    );
    final SonnetTransitionFrame baseTransition = motion
        ? resolveSonnetSceneTransition(
            program,
            index,
            shotIndex,
            time,
            settings.enableTransitions,
          )
        : sonnetIdleTransition;
    final SonnetCreditsFrame credits = resolveSonnetCreditsFrame(
      time,
      director.finalEnd,
    );
    final LyricVisualizerAudioFrame audio = visualizer.audioFrameAt(timeMs);
    final SonnetBeatFxFrame? beatFx = motion
        ? beatReader.read(
            visualizer,
            audio,
            timeMs,
            wallTimeSec: ticks.value.elapsed,
          )
        : null;
    // 强拍撕裂与转场故障条共用一个滤镜，取大者（folia `beatTearWins`）。
    final SonnetTransitionFrame transition =
        beatFx != null && beatFx.tear > baseTransition.glitch
        ? SonnetTransitionFrame(
            alpha: baseTransition.alpha,
            blur: baseTransition.blur,
            glitch: beatFx.tear,
            glitchSeed: beatFx.tearSeed / 997,
          )
        : baseTransition;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas sc = Canvas(recorder);
    _paintBackground(sc, scene, size);
    if (scene.shots.isNotEmpty) {
      _paintShot(
        sc,
        scene.shots[shotIndex.clamp(0, scene.shots.length - 1)],
        time,
        size,
        audio,
        beatFx,
      );
    }
    final ui.Picture picture = recorder.endRecording();

    final bool post =
        settings.postProcessEnabled && !settings.showOnlyText && motion;
    final Rect bounds = Offset.zero & size;
    if (post && settings.postProcessContrast > 0) {
      final double v = settings.postProcessContrast * 0.5 + 1;
      final double o = 128 * (1 - v);
      canvas.saveLayer(
        bounds,
        Paint()
          ..colorFilter = ColorFilter.matrix(<double>[
            v,
            0,
            0,
            0,
            o,
            0,
            v,
            0,
            0,
            o,
            0,
            0,
            v,
            0,
            o,
            0,
            0,
            0,
            1,
            0,
          ]),
      );
    }
    final double alpha = transition.alpha * credits.lyricAlpha;
    final double blur = transition.blur / 2 + credits.lyricBlur / 2;
    final bool layered = alpha < 1 || blur > 0.01;
    if (layered) {
      final Paint lp = Paint()
        ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0));
      if (blur > 0.01) {
        lp.imageFilter = ui.ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: TileMode.decal,
        );
      }
      canvas.saveLayer(bounds, lp);
    }
    if (post && _paintShaderPost(canvas, picture, size)) {
      // 着色器已画完（含暗角）。
    } else {
      _paintGlitched(canvas, picture, size, transition);
      if (post) _paintCpuPost(canvas, picture, size);
    }
    if (layered) canvas.restore();
    if (post && settings.postProcessGrain > 0) {
      _paintGrain(canvas, size, timeMs);
    }
    if (post && settings.postProcessContrast > 0) canvas.restore();
    picture.dispose();

    if (credits.active && credits.posterAlpha > 0) {
      _paintPoster(canvas, size, credits);
    }
    if (settings.outerFrameMode != 'none' && !settings.showOnlyText) {
      _paintFrame(canvas, size);
    }
  }

  // ---------------------------------------------------------------------------
  // 背景 / 元信息
  // ---------------------------------------------------------------------------

  void _paintBackground(Canvas canvas, SonnetSceneView scene, Size size) {
    if (scene.drawBackdrop) {
      canvas.drawRect(
        Offset.zero & size,
        _paint
          ..color = colors.background.withValues(alpha: 0.10)
          ..style = PaintingStyle.fill,
      );
    }
    for (final SonnetBgLine l in scene.bgLines) {
      _paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = l.width
        ..color = l.color.withValues(alpha: l.alpha);
      canvas.drawLine(Offset(l.x, l.y), Offset(l.x + l.length, l.y), _paint);
    }
    final TextPainter? title = scene.metaTitle;
    if (title != null) {
      canvas.save();
      canvas.translate(28, size.height - 28);
      canvas.rotate(-math.pi / 2);
      title.paint(canvas, Offset(0, -title.height));
      canvas.restore();
    }
    final TextPainter? desc = scene.metaDescription;
    if (desc != null) {
      desc.paint(canvas, Offset(size.width - 28 - desc.width, 28));
    }
  }

  // ---------------------------------------------------------------------------
  // 镜头
  // ---------------------------------------------------------------------------

  void _prepareTracking(SonnetShotView view) {
    if (view.trackSegments != null) return;
    final List<SonnetSegmentView> track = view.segments
        .where(
          (SonnetSegmentView s) =>
              s.role != SonnetSegmentRole.decoration &&
              s.trackingGlyphs.isNotEmpty,
        )
        .toList();
    double done = view.shot.start;
    for (final SonnetSegmentView s in view.segments) {
      for (final SonnetGlyphView g in s.glyphs) {
        done = math.max(done, g.settle);
      }
    }
    view
      ..trackSegments = track
      ..revealDone = done
      ..focusRanges = <(double, double)>[
        for (final SonnetSegmentView s in track)
          (s.trackingGlyphs.first.start, s.trackingGlyphs.last.settle),
      ];
  }

  (double, double) _focusAt(SonnetShotView view, double t) {
    final List<SonnetSegmentView> track = view.trackSegments!;
    if (track.isEmpty) return (view.basePivotX, view.basePivotY);
    final List<double> weights = resolveSonnetFocusWeights(view.focusRanges, t);
    double x = 0;
    double y = 0;
    for (int i = 0; i < track.length; i++) {
      final (
        double fx,
        double fy,
      ) = resolveSonnetSegmentCameraFocus(<(double, double, double)>[
        for (final SonnetGlyphView g in track[i].trackingGlyphs)
          (g.baseX, g.baseY, g.start),
      ], t);
      x += fx * weights[i];
      y += fy * weights[i];
    }
    return (x, y);
  }

  void _paintShot(
    Canvas canvas,
    SonnetShotView view,
    double time,
    Size size,
    LyricVisualizerAudioFrame audio,
    SonnetBeatFxFrame? beatFx,
  ) {
    final SonnetShot shot = view.shot;
    final double w = size.width;
    final double h = size.height;
    final double typo = motion ? settings.typographyMotion * animationScale : 0;
    final double cam = motion ? settings.cameraIntensity * animationScale : 0;
    final bool onlyText = settings.showOnlyText;
    _prepareTracking(view);

    final SonnetMotionFrame frame = resolveSonnetShotMotionFrame(
      shot.kind,
      resolveSonnetShotProgress(shot, time),
    );
    // 镜头结束后的空档里沿镜头末段的方向继续慢慢漂（folia gap drift），画面不至于定住。
    final double gapTime = math.max(0, time - shot.end);
    if (gapTime > 0 && motion) {
      final SonnetMotionFrame tail = resolveSonnetShotMotionFrame(
        shot.kind,
        0.8,
      );
      final double drift = (1 - math.exp(-gapTime * 0.4)) * 2.0;
      frame
        ..x += (frame.x - tail.x) * drift
        ..y += (frame.y - tail.y) * drift
        ..scale += (frame.scale - tail.scale) * drift
        ..rotation += (frame.rotation - tail.rotation) * drift;
    }
    final double phase = (hashSonnetSeed(shot.id) % 1024) / 1024 * math.pi * 2;
    final SonnetMotionFrame breath = resolveSonnetCameraBreath(time, phase);
    final double bw = resolveSonnetBreathWeight(time, view.revealDone);
    final double dx = (frame.x + breath.x * bw) * w * cam;
    final double dy = (frame.y + breath.y * bw) * h * cam;
    // 随拍推镜：绕跟焦点缩放，倾斜左右交替（外框不跟着动）。
    final double scale =
        shot.camera.zoom *
        (1 + (frame.scale - 1 + breath.scale * bw) * cam) *
        (beatFx?.zoom ?? 1);
    final double rotation =
        (shot.camera.rotation + frame.rotation + breath.rotation * bw) * cam +
        (beatFx?.rotation ?? 0);
    double pivotX = view.basePivotX;
    double pivotY = view.basePivotY;
    if (cam > 0 && shot.kind != SonnetShotKind.posterBlocks) {
      final (double fx, double fy) = resolveSonnetSmoothedFocus(
        time,
        shot.start,
        shot.end,
        (double t) => _focusAt(view, t),
      );
      final double k = math.min(1, cam);
      pivotX += (fx - pivotX) * k;
      pivotY += (fy - pivotY) * k;
    }

    // MG：进度在镜头里最后一句起唱前后画完，至少一秒。
    double lastCue = shot.start;
    for (final double c in shot.cueTimes) {
      lastCue = math.max(lastCue, c);
    }
    final double targetFinish = math.min(
      shot.end,
      math.max(lastCue, shot.start + 0.95 * (shot.end - shot.start)),
    );
    final double drawDuration = math.max(1, targetFinish - shot.start);
    final double mg = motion
        ? sonnetClamp01((time - shot.start) / drawDuration)
        : 1;
    final Offset center = Offset(w / 2, h / 2);
    // 图标：随拍帧时随词起跳，否则按频段呼吸（folia `sonnetShotMg.updateTime`）。
    if (beatFx == null) {
      final double target = resolveSonnetIconAudioTarget(audio);
      view.smoothedIconAudio +=
          (target - view.smoothedIconAudio) *
          (target > view.smoothedIconAudio ? 0.34 : 0.16);
    }
    final double? onsetK = beatFx == null
        ? null
        : resolveSonnetIconOnsetPop(time, shot.cueTimes);
    // MG 线条随高频闪亮。
    final bool flash = beatFx != null && !onlyText;
    if (flash) {
      canvas.saveLayer(
        null,
        Paint()
          ..color = Color.fromRGBO(
            0,
            0,
            0,
            resolveSonnetLineFlashAlpha(beatFx.lineLift),
          ),
      );
    }
    if (!onlyText) {
      if (settings.showBackgroundMg) {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        view.bg.paint(canvas, mg);
        canvas.restore();
      }
      canvas.save();
      canvas.translate(center.dx + dx * 0.4, center.dy + dy * 0.4);
      canvas.rotate(motion ? (time - shot.start) * 0.05 * cam : 0);
      canvas.scale(1 + (scale - 1) * 0.3);
      if (settings.showBackgroundMg) view.geo?.paint(canvas, mg);
      final SonnetFixedGeo? fixed = view.fixedGeo;
      if (settings.showFixedGeo && fixed != null) {
        canvas.save();
        canvas.rotate(motion ? -(time - shot.start) * 0.1 * cam : 0);
        fixed.paint(canvas, mg);
        canvas.restore();
      }
      if (settings.showBackgroundDecor) {
        _paintParticles(canvas, view, time, mg, onsetK);
      }
      canvas.restore();
    }
    if (flash) canvas.restore();

    final double flare = beatFx?.flare ?? 0;
    final bool flaring = flare > 0.02 && !onlyText;
    final Canvas outer = canvas;
    ui.PictureRecorder? textRecorder;
    if (flaring) {
      textRecorder = ui.PictureRecorder();
      canvas = Canvas(textRecorder);
    }
    canvas.save();
    canvas.translate(view.baseX + dx, view.baseY + dy);
    canvas.rotate(rotation);
    canvas.scale(scale);
    canvas.translate(-pivotX, -pivotY);
    for (final SonnetSegmentView seg in view.segments) {
      if (!onlyText && settings.showFixedGeo && motion) {
        seg.frameDecor?.paint(canvas, time);
      }
      _paintSegment(
        canvas,
        seg,
        shot,
        time,
        typo,
        pivotX - view.basePivotX,
        pivotY - view.basePivotY,
      );
      final SonnetGuide? guide = seg.guide;
      if (guide != null &&
          settings.showGuide &&
          !onlyText &&
          motion &&
          guide.activeAt(time)) {
        canvas.save();
        canvas.translate(guide.x, guide.y);
        guide.paint(canvas, time, guide.maxAlpha);
        canvas.restore();
      }
    }
    canvas.restore();
    if (textRecorder != null) {
      // 强拍光晕增亮（folia 光晕层 alpha 抬高）：文字层再叠一份模糊的滤色副本。
      final ui.Picture text = textRecorder.endRecording();
      outer.drawPicture(text);
      final double sigma = math.max(6, 18 * fontScale);
      outer.saveLayer(
        null,
        Paint()
          ..blendMode = BlendMode.screen
          ..color = Color.fromRGBO(0, 0, 0, flare.clamp(0.0, 1.0))
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.decal,
          ),
      );
      outer.drawPicture(text);
      outer.restore();
      text.dispose();
    }
  }

  void _paintParticles(
    Canvas canvas,
    SonnetShotView view,
    double time,
    double mg,
    double? onsetK,
  ) {
    final double dur = math.max(0.001, view.shot.end - view.shot.start);
    final double audio = view.smoothedIconAudio.clamp(0.0, 1.0);
    for (final SonnetParticle p in view.particles) {
      if (!p.icon) {
        if (mg <= 0) continue;
        paintSonnetParticle(canvas, p, alphaMul: math.min(1, mg * 2));
        continue;
      }
      double k = 1;
      if (motion) {
        final double entry = math.min(
          p.preferredDuration,
          math.min(math.max(0.08, dur * 0.18), dur),
        );
        final double delay = p.entryPhase * (dur - entry);
        k = sonnetClamp01((time - view.shot.start - delay) / entry);
      }
      if (k <= 0) continue;
      final double loopPulse = motion
          ? (math.sin((time - view.shot.start) * math.pi * 0.7 + p.phase) + 1) *
                0.5
          : 0;
      final double audioScale = onsetK != null
          ? resolveSonnetIconPopScale(onsetK)
          : 1 + audio * 0.42;
      final double alphaLift = onsetK != null
          ? 0.86 + onsetK * 0.24
          : 0.72 + audio * 0.38;
      final double s =
          (motion ? easeSonnetElasticOut(k) : 1) *
          audioScale *
          (1 + loopPulse * 0.025);
      paintSonnetParticle(
        canvas,
        p,
        scale: s,
        alphaMul: math.min(1, k * (alphaLift + loopPulse * 0.03)),
      );
    }
  }

  void _paintSegment(
    Canvas canvas,
    SonnetSegmentView seg,
    SonnetShot shot,
    double time,
    double typo,
    double driftX,
    double driftY,
  ) {
    final bool emphasis = isSonnetEmphasisRole(seg.role);
    final bool impact = shot.kind == SonnetShotKind.typeImpact && emphasis;
    for (final SonnetGlyphView g in seg.glyphs) {
      final bool waiting = time < g.start;
      if (waiting) continue;
      final double p = motion
          ? resolveSonnetSegmentProgress(g.start, g.settle, time)
          : 1;
      final double offset = (1 - p) * typo;
      final double coreAlpha = motion ? 0.16 + 0.84 * p : 1;
      final double sc =
          (impact ? 0.52 + 0.48 * p : 0.86 + 0.14 * p) * (1 + g.zDepth * 0.45);
      final double x =
          g.baseX + g.enterX * offset - driftX * g.zDepth * 2.5 * 0.1;
      final double y =
          g.baseY + g.enterY * offset - driftY * g.zDepth * 2.5 * 0.1;
      final double rot = g.finalRotation + g.entryRotation * offset;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rot);
      canvas.scale(motion ? sc : 1 + g.zDepth * 0.45);
      final bool layer = coreAlpha < 0.999;
      final SonnetTextFixedGeo? shape = g.bgShape;
      final SonnetStaff? staff = g.staff;
      if (shape != null) {
        shape.paint(canvas, coreAlpha);
      } else if (staff != null) {
        staff.paint(canvas, time, coreAlpha);
      } else {
        if (layer) {
          canvas.saveLayer(
            null,
            Paint()..color = Color.fromRGBO(0, 0, 0, coreAlpha),
          );
        }
        final TextPainter core = g.core!;
        final Offset at = Offset(-core.width / 2, -core.height / 2);
        if (g.caOffset > 0 && motion) {
          final double ca = g.caOffset * (1 - 0.8 * p);
          g.cyan?.paint(canvas, at.translate(-ca, 0));
          g.red?.paint(canvas, at.translate(ca, 0));
        }
        core.paint(canvas, at);
        if (layer) canvas.restore();
        final TextPainter? ghost = g.ghost;
        if (ghost != null && motion && g.ghostDuration > 0) {
          final double k = (time - g.start) / g.ghostDuration;
          if (k > 0 && k < 1) {
            final double ease = easeSonnetExpoOut(k);
            for (final SonnetGhost gh in g.ghosts) {
              final double a = gh.alphaBase * math.sin(math.pi * k);
              if (a <= 0.01) continue;
              canvas.saveLayer(
                null,
                Paint()..color = Color.fromRGBO(0, 0, 0, a),
              );
              ghost.paint(canvas, at.translate(gh.dx * ease, gh.dy * ease));
              canvas.restore();
            }
          }
        }
      }
      canvas.restore();
    }
  }

  // ---------------------------------------------------------------------------
  // 转场故障条 / 后期
  // ---------------------------------------------------------------------------

  void _paintGlitched(
    Canvas canvas,
    ui.Picture picture,
    Size size,
    SonnetTransitionFrame t,
  ) {
    if (t.glitch <= 0.001) {
      canvas.drawPicture(picture);
      return;
    }
    final int seed = (t.glitchSeed * 1000003).floor();
    const int bands = 14;
    final double bh = size.height / bands;
    final double brightness = 1 + t.glitch * 0.35;
    canvas.saveLayer(
      Offset.zero & size,
      Paint()
        ..colorFilter = ColorFilter.matrix(<double>[
          brightness,
          0,
          0,
          0,
          0,
          0,
          brightness,
          0,
          0,
          0,
          0,
          0,
          brightness,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
    );
    for (int i = 0; i < bands; i++) {
      double shift = 0;
      if (sonnetHash01(seed, i, 3) > 0.58) {
        shift =
            (sonnetHash01(seed, i, 5) - 0.5) * 2 * t.glitch * 0.1 * size.width;
      } else if (sonnetHash01(seed, i, 7) > 0.88) {
        shift =
            (sonnetHash01(seed, i, 9) - 0.5) *
            2 *
            t.glitch *
            0.037 *
            size.width;
      }
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, i * bh, size.width, bh + 0.5));
      canvas.translate(shift, 0);
      canvas.drawPicture(picture);
      canvas.restore();
    }
    canvas.restore();
  }

  bool _paintShaderPost(Canvas canvas, ui.Picture picture, Size size) {
    final ui.FragmentProgram? program = _postProgram;
    final SonnetSettings s = settings;
    final bool needsShader =
        s.postProcessLensDistortion > 0 ||
        s.postProcessLensDispersion > 0 ||
        s.postProcessRgbShift > 0 ||
        s.postProcessHalftone > 0;
    if (program == null || !needsShader) return false;
    final double dpr = devicePixelRatio.clamp(1.0, 2.0);
    final int pw = math.max(1, (size.width * dpr).round());
    final int ph = math.max(1, (size.height * dpr).round());
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas c = Canvas(rec);
    c.scale(dpr);
    c.drawPicture(picture);
    final ui.Picture scaled = rec.endRecording();
    final ui.Image image = scaled.toImageSync(pw, ph);
    scaled.dispose();
    final ui.FragmentShader shader = program.fragmentShader()
      ..setFloat(0, pw.toDouble())
      ..setFloat(1, ph.toDouble())
      ..setFloat(2, s.postProcessLensDistortion)
      ..setFloat(3, s.postProcessLensDispersion)
      ..setFloat(4, s.postProcessRgbShift)
      ..setFloat(5, s.postProcessHalftone)
      ..setFloat(6, s.postProcessVignette)
      ..setImageSampler(0, image);
    canvas.save();
    canvas.scale(1 / dpr);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, pw.toDouble(), ph.toDouble()),
      Paint()..shader = shader,
    );
    canvas.restore();
    shader.dispose();
    image.dispose();
    return true;
  }

  /// 没有着色器时：RGB 错位（红 / 蓝通道各画一份变亮叠加）+ 径向暗角。
  void _paintCpuPost(Canvas canvas, ui.Picture picture, Size size) {
    final Rect bounds = Offset.zero & size;
    final double shift = settings.postProcessRgbShift * 3;
    if (shift > 0) {
      final Offset dir = const Offset(0.9063, 0.4226) * shift;
      for (final (Offset off, List<double> m) in <(Offset, List<double>)>[
        (
          dir,
          <double>[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0],
        ),
        (
          -dir,
          <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
        ),
      ]) {
        canvas.saveLayer(
          bounds,
          Paint()
            ..blendMode = BlendMode.lighten
            ..colorFilter = ColorFilter.matrix(m),
        );
        canvas.translate(off.dx, off.dy);
        canvas.drawPicture(picture);
        canvas.restore();
      }
    }
    final double v = settings.postProcessVignette;
    if (v > 0) {
      final double r = size.shortestSide > 0
          ? math.sqrt(size.width * size.width + size.height * size.height) / 2
          : 1;
      final double inner = (0.52 * size.shortestSide / r).clamp(0.0, 0.95);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.radial(
            bounds.center,
            r,
            <Color>[
              const Color(0x00000000),
              const Color(0x00000000),
              Color.fromRGBO(0, 0, 0, (v * 0.6).clamp(0.0, 1.0)),
            ],
            <double>[0, inner, 1],
          ),
      );
    }
  }

  /// 胶片颗粒：按帧换种子的稀疏亮 / 暗点。
  void _paintGrain(Canvas canvas, Size size, int timeMs) {
    final double g = settings.postProcessGrain;
    final int count = math.min(
      6000,
      (size.width * size.height / 900 * g).round(),
    );
    if (count <= 0) return;
    final SonnetRng rng = SonnetRng(timeMs ~/ 42 + 0x6a1);
    final Float32List light = Float32List(count);
    final Float32List dark = Float32List(count);
    for (int i = 0; i < count ~/ 2; i++) {
      light[i * 2] = rng.next() * size.width;
      light[i * 2 + 1] = rng.next() * size.height;
      dark[i * 2] = rng.next() * size.width;
      dark[i * 2 + 1] = rng.next() * size.height;
    }
    final Paint p = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.square;
    canvas.drawRawPoints(
      ui.PointMode.points,
      light,
      p..color = Color.fromRGBO(255, 255, 255, (g * 0.22).clamp(0.0, 1.0)),
    );
    canvas.drawRawPoints(
      ui.PointMode.points,
      dark,
      p..color = Color.fromRGBO(0, 0, 0, (g * 0.22).clamp(0.0, 1.0)),
    );
  }

  // ---------------------------------------------------------------------------
  // 片尾 / 外框
  // ---------------------------------------------------------------------------

  void _paintPoster(Canvas canvas, Size size, SonnetCreditsFrame credits) {
    final List<TextPainter> lines = director.posterLines();
    if (lines.isEmpty) return;
    const double gap = 14;
    final double total =
        lines.fold<double>(0, (double s, TextPainter p) => s + p.height) +
        gap * (lines.length - 1);
    canvas.saveLayer(
      Offset.zero & size,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, credits.posterAlpha.clamp(0.0, 1.0)),
    );
    canvas.translate(
      size.width / 2,
      size.height / 2 + credits.posterOffsetY * size.height,
    );
    canvas.scale(credits.posterScale);
    double y = -total / 2;
    for (final TextPainter p in lines) {
      p.paint(canvas, Offset(-p.width / 2, y));
      y += p.height + gap;
    }
    canvas.restore();
  }

  void _paintFrame(Canvas canvas, Size size) {
    const double inset = 16;
    final Rect r = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    if (r.width <= 0 || r.height <= 0) return;
    _paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.primary.withValues(alpha: 0.28);
    canvas.drawRect(r, _paint);
    _paint
      ..strokeWidth = 3
      ..color = colors.accent.withValues(alpha: 0.6);
    const double arm = 18;
    for (final (Offset c, double sx, double sy) in <(Offset, double, double)>[
      (r.topLeft, 1, 1),
      (r.topRight, -1, 1),
      (r.bottomLeft, 1, -1),
      (r.bottomRight, -1, -1),
    ]) {
      canvas.drawLine(c, c.translate(sx * arm, 0), _paint);
      canvas.drawLine(c, c.translate(0, sy * arm), _paint);
    }
  }

  @override
  bool shouldRepaint(SonnetPainter old) =>
      old.director != director ||
      old.settings != settings ||
      old.colors != colors ||
      old.fontScale != fontScale ||
      old.motion != motion ||
      old.devicePixelRatio != devicePixelRatio;
}
