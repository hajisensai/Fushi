/// 浮名的镜头（folia `fumeCamera.ts` + `fumeCameraStep.ts`）：盯哪一块、块里追到哪个字、
/// 换句时怎么飞过去（近处直线、远处先拉远再落下）、全曲末尾拉成全景，以及闲置漂浮。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_render_hints.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_article_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_timeline.dart';

const double fumeCameraScaleMin = 0.22;
const double fumeCameraScaleMax = 2.24;
const int fumeOverviewCameraSource = -2;
const double _teleportTriggerScreens = 2.75;

/// 镜头看向的点与缩放。
@immutable
class FumeViewTarget {
  const FumeViewTarget(this.x, this.y, this.scale);

  final double x;
  final double y;
  final double scale;
}

enum FumeTrackingMode { stepped, smooth }

enum FumeBridgeMode { none, direct, overview }

/// 换目标的一次过渡。
class FumeRetarget {
  int sourceLineIndex = -1;
  double startedAt = 0;
  double duration = 0.18;
  double fromX = 0;
  double fromY = 0;
  double fromScale = 1;
  FumeBridgeMode bridgeMode = FumeBridgeMode.none;
  double waypointX = 0;
  double waypointY = 0;
  double waypointScale = 1;
  double waypointPhase = 0.36;

  void reset({
    required int source,
    required double at,
    required double duration,
    required FumeCamera camera,
  }) {
    sourceLineIndex = source;
    startedAt = at;
    this.duration = duration;
    fromX = camera.x;
    fromY = camera.y;
    fromScale = camera.scale;
    bridgeMode = FumeBridgeMode.none;
    waypointX = 0;
    waypointY = 0;
    waypointScale = 1;
    waypointPhase = 0.36;
  }
}

/// 镜头的弹簧状态。
class FumeCamera {
  double x = 0;
  double y = 0;
  double vx = 0;
  double vy = 0;
  double focusX = 0;
  double focusY = 0;
  double scale = 1;
  double vScale = 0;
  double focusScale = 1;
}

/// 每帧原地更新的镜头状态（folia `FumeCameraState`）。
class FumeCameraState {
  final FumeCamera camera = FumeCamera();
  final FumeRetarget retarget = FumeRetarget();
  bool initialized = false;

  /// 新文章：镜头放到纸中央；已在跑：夹回文章范围。
  void syncToArticle(FumeArticle? article) {
    if (article == null) {
      initialized = false;
      return;
    }
    final FumeCamera c = camera;
    if (!initialized) {
      c
        ..x = article.width * 0.5
        ..y = article.height * 0.5
        ..vx = 0
        ..vy = 0
        ..focusX = article.width * 0.5
        ..focusY = article.height * 0.5
        ..scale = 1.18
        ..vScale = 0
        ..focusScale = 1.18;
      initialized = true;
      return;
    }
    c
      ..x = fumeClamp(c.x, 0, article.width)
      ..y = fumeClamp(c.y, 0, article.height)
      ..focusX = fumeClamp(c.focusX, 0, article.width)
      ..focusY = fumeClamp(c.focusY, 0, article.height)
      ..scale = fumeClamp(c.scale, fumeCameraScaleMin, fumeCameraScaleMax)
      ..focusScale = fumeClamp(
        c.focusScale,
        fumeCameraScaleMin,
        fumeCameraScaleMax,
      );
  }
}

Offset _blockCenter(FumeBlock b) =>
    Offset(b.x + b.width * 0.5, b.y + b.height * 0.5);

/// 定格追焦：落在已打印字数所在行的那个字上。
Offset fumeSteppedFocusPoint(FumeBlock block, int printedCount) {
  if (block.renderLines.isEmpty) return _blockCenter(block);
  final int offset = printedCount.clamp(0, block.graphemeCount);
  final FumeRenderLine line = block.renderLines.firstWhere(
    (FumeRenderLine l) => offset <= l.end,
    orElse: () => block.renderLines.last,
  );
  final int local = offset.clamp(line.start, line.end) - line.start;
  final double minX = block.x + line.left;
  final double maxX = minX + line.width;
  return Offset(
    fumeClamp(minX + line.offsetAt(local), minX, math.max(minX, maxX)),
    block.y + line.top + block.lineHeight * 0.5,
  );
}

/// 平滑追焦：按连续进度插到字内部，换行时在 0.7 字的窗口里混合上下两行。
Offset fumeSmoothFocusPoint(FumeBlock block, double printedProgress) {
  if (block.renderLines.isEmpty) return _blockCenter(block);
  final double offset = fumeClamp(
    printedProgress,
    0,
    block.graphemeCount.toDouble(),
  );
  int lineIndexFor(double o) {
    final int i = block.renderLines.indexWhere(
      (FumeRenderLine l) => o <= l.end,
    );
    return i >= 0 ? i : block.renderLines.length - 1;
  }

  Offset pointOn(int li, double o) {
    final FumeRenderLine line = block.renderLines[li];
    final double clamped = fumeClamp(
      o,
      line.start.toDouble(),
      line.end.toDouble(),
    );
    final int base = clamped.floor();
    final double frac = clamped - base;
    final int local = base - line.start;
    final double baseWidth = line.offsetAt(local);
    final double advance = line.advanceAt(local);
    final double minX = block.x + line.left;
    final double maxX = minX + line.width;
    return Offset(
      fumeClamp(minX + baseWidth + advance * frac, minX, math.max(minX, maxX)),
      block.y + line.top + block.lineHeight * 0.5,
    );
  }

  final int li = lineIndexFor(offset);
  Offset point = pointOn(li, offset);
  final FumeRenderLine current = block.renderLines[li];
  const double window = 0.7;
  if (li > 0 && offset < current.start + window) {
    final FumeRenderLine prev = block.renderLines[li - 1];
    final double blend = fumeEaseInOutCubic(
      fumeClamp(1 - ((offset - prev.end) / window), 0, 1),
    );
    point = Offset.lerp(point, pointOn(li - 1, prev.end.toDouble()), blend)!;
  } else if (li < block.renderLines.length - 1 &&
      offset > current.end - window) {
    final FumeRenderLine next = block.renderLines[li + 1];
    final double blend = fumeEaseInOutCubic(
      fumeClamp((offset - (current.end - window)) / window, 0, 1),
    );
    point = Offset.lerp(point, pointOn(li + 1, next.start.toDouble()), blend)!;
  }
  return point;
}

/// 刚换到一块时先看它的行首。
Offset fumeBlockEntryFocusPoint(FumeBlock block) {
  if (block.renderLines.isEmpty) return _blockCenter(block);
  final FumeRenderLine first = block.renderLines.first;
  return Offset(
    block.x + first.left,
    block.y + first.top + block.lineHeight * 0.5,
  );
}

/// 让当前块的行高在屏上约为短边的 11.5%。
double fumeCameraScaleForBlock(FumeBlock block, Size viewport) {
  final double minSide = math.max(math.min(viewport.width, viewport.height), 1);
  final double target = fumeClamp(minSide * 0.115, 64, 124);
  return fumeClamp(target / math.max(block.lineHeight, 1), 0.88, 2.2);
}

/// 换句过渡时长（随行的节奏：短句更快）。
double fumeCameraRetargetDuration(FumeLine line) {
  final double raw = math.max(line.end - line.start, 0);
  final LyricVisualizerRenderHints h = line.hints;
  final double enter = h.enterMs / 1000;
  final double exit = h.exitMs / 1000;
  final double hold = h.passHoldMs / 1000;
  switch (h.lineTransition) {
    case LyricVisualizerLineTransition.none:
      return fumeClamp(math.max(raw, 0.08) * 0.34, 0.04, 0.075);
    case LyricVisualizerLineTransition.fast:
      return fumeClamp(enter * 0.5 + exit * 0.12, 0.055, 0.095);
    case LyricVisualizerLineTransition.normal:
      return fumeClamp(enter * 0.44 + hold * 0.22, 0.075, 0.13);
  }
}

double fumeOverviewRetargetDuration(Size viewport) =>
    fumeClamp(math.min(viewport.width, viewport.height) / 1500, 0.38, 0.58);

/// 远距离换句：经由全景方向的一个高点飞过去（返回 null = 不需要）。
({double x, double y, double scale, double phase, double duration})?
fumeOverviewFlightBridge({
  required double fromX,
  required double fromY,
  required double fromScale,
  required double targetX,
  required double targetY,
  required double targetScale,
  required FumeViewTarget? overview,
  required Size viewport,
}) {
  if (overview == null) return null;
  final double safeScale = <double>[
    fromScale,
    targetScale,
    overview.scale,
    0.001,
  ].reduce(math.max);
  final double minSide = math.max(math.min(viewport.width, viewport.height), 1);
  final double worldDistance = math.sqrt(
    math.pow(fromX - targetX, 2) + math.pow(fromY - targetY, 2),
  );
  final double screenDistance = worldDistance * safeScale;
  if (worldDistance <= 0 ||
      screenDistance < minSide * _teleportTriggerScreens) {
    return null;
  }
  final double loft = fumeClamp(
    (screenDistance / minSide - _teleportTriggerScreens) / 3.4,
    0,
    1,
  );
  final double midX = fumeMix(fromX, targetX, 0.5);
  final double midY = fumeMix(fromY, targetY, 0.5);
  final double bias = fumeMix(0.18, 0.42, loft);
  final double wx = fumeMix(midX, overview.x, bias);
  final double wy = fumeMix(midY, overview.y, bias);
  final double endpointScale = math.max(
    math.max(fromScale, targetScale),
    0.001,
  );
  final double lofted = endpointScale * fumeMix(0.62, 0.4, loft);
  final double overviewLimited = overview.scale * fumeMix(1.85, 1.55, loft);
  final double ws = fumeClamp(
    math.max(lofted, overviewLimited),
    fumeCameraScaleMin,
    math.max(endpointScale * 0.92, fumeCameraScaleMin),
  );
  final double fromLeg =
      math.sqrt(math.pow(wx - fromX, 2) + math.pow(wy - fromY, 2)) *
      math.max(math.max(fromScale, ws), 0.001);
  final double toLeg =
      math.sqrt(math.pow(targetX - wx, 2) + math.pow(targetY - wy, 2)) *
      math.max(math.max(targetScale, ws), 0.001);
  final double total = fromLeg + toLeg;
  final double phase = total <= 0
      ? 0.36
      : fumeClamp(fromLeg / total, 0.26, 0.44);
  final double duration = fumeClamp(
    0.26 + (screenDistance / (minSide * 5.5)) * 0.28,
    0.3,
    0.68,
  );
  return (x: wx, y: wy, scale: ws, phase: phase, duration: duration);
}

/// 全景：框住所有块，留边。
FumeViewTarget fumeArticleOverviewCamera(FumeArticle article, Size viewport) {
  if (article.blocks.isEmpty) {
    final double fit = math.min(
      viewport.width / math.max(article.width, 1),
      viewport.height / math.max(article.height, 1),
    );
    return FumeViewTarget(
      article.width * 0.5,
      article.height * 0.5,
      fumeClamp(fit * 0.92, fumeCameraScaleMin, 0.72),
    );
  }
  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = double.negativeInfinity;
  double maxY = double.negativeInfinity;
  for (final FumeBlock b in article.blocks) {
    minX = math.min(minX, b.x);
    minY = math.min(minY, b.y);
    maxX = math.max(maxX, b.x + b.width);
    maxY = math.max(maxY, b.y + b.height);
  }
  final double padX = fumeClamp(viewport.width * 0.2, 120, 280);
  final double padY = fumeClamp(viewport.height * 0.2, 96, 220);
  final double fit = math.min(
    viewport.width / math.max(maxX - minX + padX * 2, 1),
    viewport.height / math.max(maxY - minY + padY * 2, 1),
  );
  return FumeViewTarget(
    (minX + maxX) * 0.5,
    (minY + maxY) * 0.5,
    fumeClamp(fit, fumeCameraScaleMin, 0.72),
  );
}

/// 镜头该盯的块：正在唱的；间奏里是最后一块已开始打印的。
FumeBlock? fumeFocusBlock(FumeArticle article, int activeLineIndex, double t) {
  if (activeLineIndex >= 0) {
    final FumeBlock? active = article.blockByLine[activeLineIndex];
    if (active != null) return active;
  }
  final List<FumeBlock> chrono = article.chronological;
  if (chrono.isEmpty) return null;
  if (t >= article.lastChronologicalRenderEnd) return chrono.last;
  for (int i = chrono.length - 1; i >= 0; i--) {
    if (fumePrintedGraphemeCount(chrono[i].line, t) > 0) return chrono[i];
  }
  return chrono.first;
}

/// 一帧镜头步进的结果。
class FumeCameraStepResult {
  const FumeCameraStepResult(
    this.showOverview,
    this.overviewTextRestoreProgress,
  );

  final bool showOverview;

  /// 0–1：全景飞入时，唱过的文字恢复成标准样式。
  final double overviewTextRestoreProgress;
}

/// 走一帧（folia `stepFumeCamera`）。[motion] 为 false 时镜头直接落到目标（无漂浮、无弹簧）。
FumeCameraStepResult fumeStepCamera(
  FumeCameraState state, {
  required FumeArticle article,
  required double time,
  required double wallSeconds,
  required double dt,
  required int lineIndex,
  required Size viewport,
  required FumeViewTarget? overview,
  required double overviewStartTime,
  required double cameraSpeed,
  required FumeTrackingMode tracking,
  required bool motion,
  LyricVisualizerIntensity intensity = LyricVisualizerIntensity.normal,
}) {
  final FumeCamera cam = state.camera;
  final FumeRetarget rt = state.retarget;
  final FumeBlock? focus = fumeFocusBlock(article, lineIndex, time);
  final bool showOverview = overview != null && time >= overviewStartTime;
  double tx = article.width * 0.5;
  double ty = article.height * 0.5;
  double ts = 1.18;
  Offset? entry;
  bool retargeted = false;

  if (showOverview) {
    tx = overview.x;
    ty = overview.y;
    ts = overview.scale;
    if (rt.sourceLineIndex != fumeOverviewCameraSource) {
      rt.reset(
        source: fumeOverviewCameraSource,
        at: time,
        duration: fumeClamp(
          fumeOverviewRetargetDuration(viewport) / cameraSpeed,
          0.12,
          1.2,
        ),
        camera: cam,
      );
      retargeted = true;
    }
  } else if (focus != null) {
    final Offset p = tracking == FumeTrackingMode.stepped
        ? fumeSteppedFocusPoint(
            focus,
            fumePrintedGraphemeCount(focus.line, time),
          )
        : fumeSmoothFocusPoint(
            focus,
            fumePrintedGraphemeProgress(focus.line, time),
          );
    entry = fumeBlockEntryFocusPoint(focus);
    tx = p.dx;
    ty = p.dy;
    ts = fumeCameraScaleForBlock(focus, viewport);
    if (rt.sourceLineIndex != focus.lineIndex) {
      rt.reset(
        source: focus.lineIndex,
        at: time,
        duration: fumeClamp(
          fumeCameraRetargetDuration(focus.line) / cameraSpeed,
          0.03,
          0.3,
        ),
        camera: cam,
      );
      retargeted = true;
    }
  } else if (rt.sourceLineIndex != -1) {
    rt.reset(
      source: -1,
      at: time,
      duration: fumeClamp(0.18 / cameraSpeed, 0.05, 0.4),
      camera: cam,
    );
    retargeted = true;
  }

  final double elapsed = math.max(time - rt.startedAt, 0);
  final double phase = fumeClamp(elapsed / math.max(rt.duration, 0.001), 0, 1);
  final double restore =
      showOverview && rt.sourceLineIndex == fumeOverviewCameraSource
      ? fumeEaseInOutCubic(phase)
      : 0;
  final double boost = 1 - fumeEaseOutCubic(phase);
  final double entryBias = math.pow(boost, 0.58).toDouble();
  if (entry != null) {
    tx = fumeMix(tx, entry.dx, entryBias);
    ty = fumeMix(ty, entry.dy, entryBias);
  }

  if (!motion) {
    // 减弱动态效果：不漂、不弹，直接定在目标上。
    cam
      ..x = tx
      ..y = ty
      ..focusX = tx
      ..focusY = ty
      ..scale = fumeClamp(ts, fumeCameraScaleMin, fumeCameraScaleMax)
      ..focusScale = cam.scale
      ..vx = 0
      ..vy = 0
      ..vScale = 0;
    return FumeCameraStepResult(showOverview, showOverview ? 1 : 0);
  }

  // 闲置漂浮（folia 按主题强度：calm 14px / 8.5s、normal 18px / 7s、chaotic 24px / 5.8s）。
  final double floatDistance = intensity.pick(14, 18, 24);
  final double floatDuration = intensity.pick(8.5, 7, 5.8);
  final double floatScaleAmp = intensity.pick(0.008, 0.011, 0.014);
  final double fp = (wallSeconds / floatDuration) * math.pi * 2;
  final double atten = showOverview ? 0.36 : 1;
  final double sfx = math.sin(fp * 0.74 + 0.8) * floatDistance * 0.34;
  final double sfy =
      (math.sin(fp) * floatDistance +
          math.sin(fp * 0.5 + 1.1) * floatDistance * 0.22) *
      atten;
  final double div = math.max(ts, 0.001);
  tx -= sfx / div;
  ty -= sfy / div;
  ts = fumeClamp(
    ts * (1 + math.sin(fp + 0.9) * floatScaleAmp * atten),
    fumeCameraScaleMin,
    fumeCameraScaleMax,
  );

  if (retargeted) {
    final double bridgeScale = math.max(math.max(cam.scale, ts), 0.001);
    final double dx = (tx - rt.fromX).abs() * bridgeScale;
    final double dy = (ty - rt.fromY).abs() * bridgeScale;
    rt
      ..bridgeMode =
          math.sqrt(dx * dx + dy * dy) >=
              math.min(viewport.width, viewport.height) * 0.42
          ? FumeBridgeMode.direct
          : FumeBridgeMode.none
      ..waypointX = tx
      ..waypointY = ty
      ..waypointScale = ts
      ..waypointPhase = 0.5;
    if (rt.sourceLineIndex >= 0) {
      final ({double x, double y, double scale, double phase, double duration})?
      bridge = fumeOverviewFlightBridge(
        fromX: rt.fromX,
        fromY: rt.fromY,
        fromScale: rt.fromScale,
        targetX: tx,
        targetY: ty,
        targetScale: ts,
        overview: overview,
        viewport: viewport,
      );
      if (bridge != null) {
        rt
          ..bridgeMode = FumeBridgeMode.overview
          ..waypointX = bridge.x
          ..waypointY = bridge.y
          ..waypointScale = bridge.scale
          ..waypointPhase = bridge.phase
          ..duration = math.max(
            rt.duration,
            fumeClamp(bridge.duration / cameraSpeed, 0.16, 0.9),
          );
      }
    }
  }

  final double cameraDistance = math.sqrt(
    math.pow(tx - cam.x, 2) + math.pow(ty - cam.y, 2),
  );
  if (rt.bridgeMode != FumeBridgeMode.none && phase < 1) {
    double bx;
    double by;
    double bs;
    if (rt.bridgeMode == FumeBridgeMode.overview) {
      final double bp = fumeEaseOutCubic(phase);
      bx = fumeQuadraticBezier(rt.fromX, rt.waypointX, tx, bp);
      by = fumeQuadraticBezier(rt.fromY, rt.waypointY, ty, bp);
      bs = fumeQuadraticBezier(rt.fromScale, rt.waypointScale, ts, bp);
    } else {
      final double bp = fumeEaseInOutCubic(phase);
      bx = fumeMix(rt.fromX, tx, bp);
      by = fumeMix(rt.fromY, ty, bp);
      bs = fumeMix(rt.fromScale, ts, bp);
    }
    final double catchUp =
        1 -
        math.exp(
          -dt *
              (rt.bridgeMode == FumeBridgeMode.overview
                  ? fumeMix(12.5, 22, 1 - phase)
                  : fumeMix(10.5, 17.5, 1 - phase)),
        );
    cam
      ..focusX = bx
      ..focusY = by
      ..focusScale = bs
      ..x = cam.x + (bx - cam.x) * catchUp
      ..y = cam.y + (by - cam.y) * catchUp
      ..scale = fumeClamp(
        cam.scale + (bs - cam.scale) * catchUp,
        fumeCameraScaleMin,
        fumeCameraScaleMax,
      )
      ..vx = cam.vx * 0.72
      ..vy = cam.vy * 0.72
      ..vScale = cam.vScale * 0.68;
  } else {
    final double boosted = fumeClamp(4.8 / math.max(rt.duration, 0.05), 20, 54);
    final double catchUp = 1 - math.exp(-dt * fumeMix(11.2, boosted, boost));
    cam
      ..focusX = cam.focusX + (tx - cam.focusX) * catchUp
      ..focusY = cam.focusY + (ty - cam.focusY) * catchUp
      ..focusScale =
          cam.focusScale +
          (ts - cam.focusScale) *
              (1 - math.exp(-dt * fumeMix(5.4, 12.8, boost)));
    final double spring = fumeMix(
      208,
      fumeClamp(15.8 / math.max(rt.duration * rt.duration, 0.0064), 260, 780),
      boost,
    );
    final double damping = fumeMix(
      24,
      fumeClamp(math.sqrt(spring) * 1.36, 24, 40),
      boost,
    );
    cam
      ..vx += ((cam.focusX - cam.x) * spring - cam.vx * damping) * dt
      ..vy += ((cam.focusY - cam.y) * spring - cam.vy * damping) * dt;
    final double maxV = fumeMix(
      1320,
      fumeClamp(
        cameraDistance / math.max(rt.duration * 0.28, 0.028),
        2600,
        8800,
      ),
      boost,
    );
    cam
      ..vx = fumeClamp(cam.vx, -maxV, maxV)
      ..vy = fumeClamp(cam.vy, -maxV, maxV)
      ..x = cam.x + cam.vx * dt
      ..y = cam.y + cam.vy * dt;
    final double sSpring = fumeMix(54, 108, boost);
    final double sDamp = fumeMix(13.5, 21, boost);
    cam.vScale = fumeClamp(
      cam.vScale +
          ((cam.focusScale - cam.scale) * sSpring - cam.vScale * sDamp) * dt,
      -1.6,
      1.6,
    );
    cam.scale = fumeClamp(
      cam.scale + cam.vScale * dt,
      fumeCameraScaleMin,
      fumeCameraScaleMax,
    );
  }
  return FumeCameraStepResult(showOverview, restore);
}

/// 背景层的视角：跟镜头视差（0.9 / 0.74）、略往下、缩放打 0.94 折。
({double centerX, double centerY, double cameraX, double cameraY, double scale})
fumeBackgroundView(Size scene, FumeCamera camera, Size viewport) {
  final double s = camera.scale;
  final double cx = scene.width * 0.5;
  final double cy = scene.height * 0.5;
  final double vOffset = fumeClamp(
    viewport.height * 0.22 / math.max(s, 0.001),
    48,
    180,
  );
  return (
    centerX: cx,
    centerY: cy,
    cameraX: fumeMix(cx, camera.x, 0.9),
    cameraY: fumeMix(cy, camera.y, 0.74) - vOffset,
    scale: fumeClamp(s * 0.94, fumeCameraScaleMin, fumeCameraScaleMax),
  );
}
