/// 镜台场景的结构推导（纯函数）：挂载哪些行、每行摆在哪、邻行透明度曲线、文字生命周期、
/// 取景缩放、渐变跟唱能量、点云阵列的取舍、背景尘埃窗口与长廊段。
///
/// 对应 folia `dioramaSceneConstants.ts` / `dioramaSceneLayout.ts` / `dioramaSceneUnits.ts` /
/// `dioramaGeometry.ts` / `dioramaMoteField.ts` / `dioramaParticleCorridor.ts`。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_sequencer.dart';

const int dioramaLinesAhead = 3;
const int dioramaLinesBehind = 2;
const int dioramaOutgoingLinesBehind = 2;
const int dioramaOutgoingLinesAhead = 1;
const int dioramaCorridorLinesAhead = 7;
const int dioramaCorridorLinesBehind = 6;

/// 每帧最多新栅格化几句邻行（切歌时把一批新行摊到几帧里，不卡一下）。
const int dioramaNeighborRasterBudget = 2;

/// 一个 em 的世界尺寸。
const double dioramaLineFontSize = 0.62;
const double dioramaTargetFrameWidthFraction = 0.72;
const double dioramaMinFitScale = 0.28;
const double dioramaFogNear = 12;
const double dioramaFogFar = 30;
const double dioramaTextDissolveStart = 2.0;
const double dioramaTextDissolveEnd = 0.9;
const double dioramaTextFadeInStart = 32;
const double dioramaTextFadeInEnd = 40;
const double dioramaColorDampRate = 1.2;
const double dioramaActiveLineOpacity = 0.92;
const double dioramaUnsungUnitOpacity = 0.5;
const double dioramaUnitGlowMaxOpacity = 0.9;
const double dioramaSoulMaxOpacity = 0.6;
const double dioramaSoulActiveLiftEm = 0.06;
const double dioramaSoulDetachLiftEm = 0.5;
const double dioramaSoulActiveSwell = 0.1;
const double dioramaSoulDetachSwell = 0.3;
const double dioramaSoulHandoffSeconds = 0.5;
const double dioramaGradientHoldSeconds = 0.35;
const double dioramaGradientTrailSeconds = 1.8;

/// 非当前行按与当前行的有向偏移取透明度：过去的行暗暗拖在后面，未来的行在雾里等。
double dioramaNeighborLineOpacity(int offset) => switch (offset) {
  -1 => 0.3,
  -2 => 0.1,
  1 => 0.34,
  2 => 0.16,
  3 => 0.06,
  _ => 0,
};

/// 切歌飞行时离去那段走廊的文字：统一的柔光，淡出交给距离生命周期。
double dioramaOutgoingLineOpacity(int offsetFromOutgoing) =>
    offsetFromOutgoing == 0
    ? 0.7
    : offsetFromOutgoing.abs() <= 2
    ? 0.45
    : 0.25;

/// 文字的距离生命周期：远处（32–40）淡入，掠过镜头（2.0–0.9）溶掉。
double dioramaTextLife(double distanceToCamera) {
  final double farT = dioramaClamp01(
    (dioramaTextFadeInEnd - distanceToCamera) /
        (dioramaTextFadeInEnd - dioramaTextFadeInStart),
  );
  final double nearT = dioramaClamp01(
    (distanceToCamera - dioramaTextDissolveEnd) /
        (dioramaTextDissolveStart - dioramaTextDissolveEnd),
  );
  return farT * farT * (3 - 2 * farT) * nearT * nearT * (3 - 2 * nearT);
}

/// 雾：线性雾因子 0（清晰）..1（完全没入背景色）。
double dioramaFogFactor(double distance) => dioramaClamp01(
  (distance - dioramaFogNear) / (dioramaFogFar - dioramaFogNear),
);

/// 把一行缩到英雄距离处最多占画面宽 72%（固定参考距离，相机推近时字真的变大）。
double dioramaFrameFitScale(
  double renderedWidth,
  double distance,
  double verticalFovDeg,
  double aspect,
) {
  if (renderedWidth <= 0 || distance <= 0) return 1;
  final double frameWidth =
      2 * distance * math.tan(verticalFovDeg * math.pi / 360) * aspect;
  return (frameWidth * dioramaTargetFrameWidthFraction / renderedWidth).clamp(
    dioramaMinFitScale,
    1.0,
  );
}

/// 渐变跟唱的单元能量：唱前 0，唱时缓升到 1，唱完保持一会儿再单向回落到 0（纯时钟函数）。
double dioramaGradientEnergy(double now, double start, double end) {
  if (now <= start) return 0;
  if (now < end) {
    return dioramaSmoothstep01((now - start) / math.max(end - start, 0.001));
  }
  final double since = now - end;
  if (since <= dioramaGradientHoldSeconds) return 1;
  return 1 -
      dioramaSmoothstep01(
        (since - dioramaGradientHoldSeconds) / dioramaGradientTrailSeconds,
      );
}

/// 要挂载的全局行：当前行附近一个前重后轻的窗口，切歌飞行时再加离去行附近一个窗口。
List<int> dioramaMountedIndices(
  int globalIndex,
  int? outgoingIndex,
  int total,
) {
  final Set<int> out = <int>{};
  void window(int center, int behind, int ahead) {
    final int start = math.max(center - behind, 0);
    final int end = math.min(center + ahead, total - 1);
    for (int i = start; i <= end; i++) {
      out.add(i);
    }
  }

  window(globalIndex, dioramaLinesBehind, dioramaLinesAhead);
  if (outgoingIndex != null) {
    window(
      outgoingIndex,
      dioramaOutgoingLinesBehind,
      dioramaOutgoingLinesAhead,
    );
  }
  return out.toList()..sort();
}

/// 一句挂载的行在路径上的摆放。
class DioramaVisibleLine {
  const DioramaVisibleLine({
    required this.index,
    required this.line,
    required this.segment,
    required this.localIndex,
    required this.placement,
    required this.position,
    required this.orientation,
    required this.isOutgoing,
  });

  final int index;
  final DioramaSceneLine line;
  final DioramaSegment segment;
  final int localIndex;
  final DioramaTextPlacement placement;
  final DioramaVec position;
  final DioramaQuat orientation;
  final bool isOutgoing;
}

List<DioramaVisibleLine> dioramaVisibleLines(
  DioramaSequencer seq,
  List<int> mounted,
  int globalIndex,
  int? outgoingIndex,
  double weave,
) {
  final List<DioramaVisibleLine> out = <DioramaVisibleLine>[];
  for (final int i in mounted) {
    final DioramaResolvedLine? r = seq.resolve(i);
    if (r == null || r.line == null) continue;
    final DioramaTextPlacement p = dioramaTextPlacement(
      r.localIndex,
      r.segment.seed,
      weave,
    );
    out.add(
      DioramaVisibleLine(
        index: i,
        line: r.line!,
        segment: r.segment,
        localIndex: r.localIndex,
        placement: p,
        position: r.frame.compose(p.offsetR, p.offsetU, 0),
        orientation: dioramaFrameQuaternion(r.frame, roll: p.roll, yaw: p.yaw),
        isOutgoing:
            outgoingIndex != null &&
            (i - outgoingIndex).abs() <= (i - globalIndex).abs(),
      ),
    );
  }
  return out;
}

// ─── 点云阵列的取舍 ────────────────────────────────────────────────────────

/// 几何开关（folia `DioramaGeometryVisibility`）。
class DioramaGeometryVisibility {
  const DioramaGeometryVisibility({
    required this.enabled,
    required this.corridor,
    required this.strands,
    required this.blobs,
    required this.ribbons,
    required this.rings,
  });

  final bool enabled;

  /// true = 长廊（沿路径的一整条点阵隧道）；false = 每句的点云阵列。
  final bool corridor;
  final bool strands;
  final bool blobs;
  final bool ribbons;
  final bool rings;

  bool kindVisible(DioramaShapeKind k) => switch (k) {
    DioramaShapeKind.box => strands,
    DioramaShapeKind.sphere => blobs,
    DioramaShapeKind.cone => ribbons,
    DioramaShapeKind.torus => rings,
  };
}

class DioramaCluster {
  const DioramaCluster({
    required this.shape,
    required this.sourceLine,
    required this.particleSeed,
  });

  final DioramaShapePlacement shape;
  final int sourceLine;

  /// 不含全局下标的稳定种子：单曲循环重建出同样的点云。
  final int particleSeed;
}

/// 两句之间隔多少句以内的点云才可能相撞。
const int dioramaClusterCollisionLineSpan = 2;

double _clusterRadius(DioramaShapePlacement s) =>
    s.scale *
    math.max(dioramaFamilyRadius(s.kind), s.stretchY * 0.55) *
    dioramaParticleAudioScaleMax;

/// 只去掉跨句的相撞（同一句的构图不删）。输入按 sourceLine 升序，早的句子赢，判定只取决于歌，
/// 与相机在哪无关——窗口滑动不会让周围的构图重洗（folia `selectVisibleDioramaClusters`）。
List<DioramaCluster> dioramaSelectVisibleClusters(
  List<DioramaCluster> shapes,
  DioramaGeometryVisibility v,
) {
  if (!v.enabled || v.corridor) return const <DioramaCluster>[];
  final List<DioramaCluster> candidates = shapes
      .where((DioramaCluster c) => v.kindVisible(c.shape.kind))
      .toList();
  final List<DioramaCluster> out = <DioramaCluster>[];
  for (int index = 0; index < candidates.length; index++) {
    final DioramaCluster cand = candidates[index];
    final double cr = _clusterRadius(cand.shape);
    bool keep = true;
    for (int ri = index - 1; ri >= 0; ri--) {
      final DioramaCluster rival = candidates[ri];
      if (cand.sourceLine - rival.sourceLine >
          dioramaClusterCollisionLineSpan) {
        break;
      }
      if (rival.sourceLine == cand.sourceLine) continue;
      final double clearance = math.max(
        1.8,
        (_clusterRadius(rival.shape) + cr) * 1.18,
      );
      if (rival.shape.position.distanceTo(cand.shape.position) < clearance) {
        keep = false;
        break;
      }
    }
    if (keep) out.add(cand);
  }
  return out;
}

/// 挂载窗口（加身后一点表决余量）上每句的阵列，过滤后只留挂载着的。
List<DioramaCluster> dioramaBuildClusters(
  DioramaSequencer seq,
  List<int> mounted,
  DioramaMotionParams motion,
  DioramaGeometryVisibility v,
  double particleScale,
) {
  if (!v.enabled || v.corridor) return const <DioramaCluster>[];
  final Set<int> mountedSet = mounted.toSet();
  final Set<int> indices = <int>{};
  for (final int i in mounted) {
    for (int back = 0; back <= dioramaClusterCollisionLineSpan; back++) {
      if (i - back >= 0) indices.add(i - back);
    }
  }
  final List<int> sorted = indices.toList()..sort();
  final List<DioramaCluster> all = <DioramaCluster>[];
  for (final int i in sorted) {
    final DioramaResolvedLine? r = seq.resolve(i);
    if (r == null) continue;
    final DioramaTextPlacement p = dioramaTextPlacement(
      r.localIndex,
      r.segment.seed,
      motion.weaveScale,
    );
    final DioramaShotKind shot = dioramaShotFor(
      r.localIndex,
      r.segment.characters,
      r.segment.seed,
      motion.subMode,
    );
    final List<DioramaShapePlacement> pieces = buildDioramaFormation(
      r.localIndex,
      r.segment.seed,
      shot,
      r.frame,
      p,
      volumeScale: particleScale,
    );
    for (int slot = 0; slot < pieces.length; slot++) {
      all.add(
        DioramaCluster(
          shape: pieces[slot],
          sourceLine: i,
          particleSeed: dioramaHashString(
            '${r.segment.seed}:${r.localIndex}:$slot:${pieces[slot].kind.name}',
          ),
        ),
      );
    }
  }
  return dioramaSelectVisibleClusters(
    all,
    v,
  ).where((DioramaCluster c) => mountedSet.contains(c.sourceLine)).toList();
}

// ─── 背景尘埃（环形缓冲的滑动窗口） ────────────────────────────────────────

const int dioramaMoteLinesBehind = 2;
const int dioramaMoteLinesAhead = 5;
const int dioramaMoteWindowLines =
    dioramaMoteLinesBehind + dioramaMoteLinesAhead + 1;
const int dioramaMoteCircumferenceMin = 4;
const int dioramaMoteCircumferenceMax = 48;
const int dioramaMoteRadialMin = 1;
const int dioramaMoteRadialMax = 4;
const double _moteInnerRadius = 2.4;
const double _moteRadialSpan = 5.2;
const double _moteVerticalSquash = 0.64;

int dioramaMoteSlot(int line) =>
    ((line % dioramaMoteWindowLines) + dioramaMoteWindowLines) %
    dioramaMoteWindowLines;

double _radicalInverse(int index, int base) {
  double result = 0;
  double fraction = 1 / base;
  int i = index;
  while (i > 0) {
    result += (i % base) * fraction;
    i ~/= base;
    fraction /= base;
  }
  return result;
}

/// 把一句的尘埃写进它的环形槽（叶序圆盘 × Hammersley 纵深 + 种子抖动；同一句永远同一团尘）。
void dioramaWriteMoteLine(
  Float32List out,
  DioramaFrame frame,
  int line,
  int circumference,
  int radial,
  int seed,
) {
  final int base = dioramaHashSeed(seed);
  final double golden = math.pi * (3 - math.sqrt(5));
  const double twoPi = math.pi * 2;
  final double phase = dioramaSeededUnit(base + 991.0) * twoPi;
  final int total = circumference * radial;
  int write = dioramaMoteSlot(line) * total * 3;
  for (int ri = 0; ri < radial; ri++) {
    for (int ci = 0; ci < circumference; ci++) {
      final int p = ri * circumference + ci;
      final double s = base + line * 131.0 + p * 17.0;
      final double stratum =
          (ri + 0.35 + dioramaSeededUnit(s + 4) * 0.3) / radial;
      final double radius =
          _moteInnerRadius + math.sqrt(stratum) * _moteRadialSpan;
      final double angle =
          phase +
          (line + ri) * golden +
          (ci / circumference) * twoPi +
          (dioramaSeededUnit(s + 3) - 0.5) * (twoPi / circumference);
      final double depth =
          (_radicalInverse(p + 1, 2) +
              (dioramaSeededUnit(s + 2) - 0.5) / total -
              0.5) *
          dioramaStepDistance;
      final DioramaVec pt = frame.compose(
        math.cos(angle) * radius,
        math.sin(angle) * radius * _moteVerticalSquash,
        depth,
      );
      out[write] = pt.x;
      out[write + 1] = pt.y;
      out[write + 2] = pt.z;
      write += 3;
    }
  }
}

// ─── 长廊 ──────────────────────────────────────────────────────────────────

const double dioramaCorridorRadius = 7.4;

class DioramaCorridorSpan {
  const DioramaCorridorSpan({
    required this.from,
    required this.to,
    required this.pathStart,
  });

  final DioramaFrame from;
  final DioramaFrame to;

  /// 绝对路径坐标（全局行下标）：波纹相位钉在世界里，窗口滑动时隧道不会滚。
  final int pathStart;
}

/// [center] 附近一段连续隧道，只在它自己的走廊段内取帧，越过两端时沿航向延伸。
List<DioramaCorridorSpan> dioramaCorridorWindow(
  DioramaSequencer seq,
  int center,
) {
  final DioramaResolvedLine? anchor = seq.resolve(center);
  if (anchor == null) return const <DioramaCorridorSpan>[];
  final DioramaSegment s = anchor.segment;
  final int first = s.globalStart;
  final int last = s.globalStart + s.span - 1;
  DioramaFrame frameAt(int index) {
    final int c = index.clamp(first, last);
    return dioramaFrameAt(s.frames, c - first).extended(index - c);
  }

  return <DioramaCorridorSpan>[
    for (
      int i = center - dioramaCorridorLinesBehind;
      i <= center + dioramaCorridorLinesAhead;
      i++
    )
      DioramaCorridorSpan(from: frameAt(i), to: frameAt(i + 1), pathStart: i),
  ];
}
