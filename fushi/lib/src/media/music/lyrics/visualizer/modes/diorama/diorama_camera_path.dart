/// 镜台的路径 / 文字摆放 / 运镜语言 / 程序化点云阵列（folia `cameraPath.ts` 的移植）。
///
/// 1. 蜿蜒路径：每句歌词往前走一步，航向按种子化的正弦偏航 / 俯仰，每句一个本地坐标系。
/// 2. 文字自由摆放：每句偏离路径中线、自带缩放 / 滚转 / 偏航与构图偏移。
/// 3. 运镜：每句按自身性格（副歌、长短、段落、长音）挑一种镜头运动，表达成本地坐标里的相机偏移。
/// 4. 阵列：每句按镜头生长一组几何点云（环、门柱、柱廊、拱、螺旋……），避开文字与相机轨道。
/// 5. 生命周期：从远雾里生出，离镜头太近时溶掉。
///
/// 纯函数，不碰画布，便于单测。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';

/// 每句沿路径前进的距离。
const double dioramaStepDistance = 8;
const double dioramaMaxYaw = 0.5;
const double dioramaMaxPitch = 0.32;

/// 相机落后读头的距离（英雄机位）。
const double dioramaHeroDistance = 5.2;
const double dioramaCameraLift = 0.5;
const double dioramaSafeFrameFraction = 0.92;
const double dioramaSwayAmp = 0.4;
const double dioramaLiftAmp = 0.4;
const double dioramaDistAmp = 0.5;

/// 相机离目标位姿超过这个距离（拖进度跳了很多行）就直接切过去。
const double dioramaSnapDistance = 24;
const double dioramaTextOffsetR = 1.8;
const double dioramaTextOffsetU = 1.2;
const double dioramaTextRoll = 0.2;
const double dioramaTextYaw = 0.16;
const double dioramaTextLook = 1.1;
const double dioramaShapeFadeInStart = 20;
const double dioramaShapeFadeInEnd = 27;
const double dioramaShapeDissolveStart = 3.0;
const double dioramaShapeDissolveEnd = 1.2;

/// 竖直视角（three.js 相机 `fov`）。
const double dioramaFovDeg = 55;

const double _degToRad = math.pi / 180;

/// 透视相机在 [distance] 处可见的半宽。
double dioramaFrameHalfWidth(
  double distance,
  double verticalFovDeg,
  double aspect,
) => distance * math.tan((verticalFovDeg * _degToRad) / 2) * aspect;

// ─── 运动参数：调参 + 风格 → 一组缩放 ──────────────────────────────────────

/// 运镜风格（folia 跟随主题的 animationIntensity：`LyricVisualizerContext.intensity`）。
enum DioramaSubMode { calm, normal, chaotic }

class DioramaMotionParams {
  const DioramaMotionParams({
    required this.moveScale,
    required this.driftScale,
    required this.smoothTime,
    required this.audioLevel,
    required this.weaveScale,
    required this.subMode,
  });

  final double moveScale;
  final double driftScale;
  final double smoothTime;
  final double audioLevel;
  final double weaveScale;
  final DioramaSubMode subMode;
}

DioramaMotionParams resolveDioramaMotionParams({
  required double cameraSpeed,
  required double motionAmount,
  required double audioReactivity,
  required DioramaSubMode subMode,
}) {
  final (
    double move,
    double drift,
    double smooth,
    double audio,
    double weave,
  ) = switch (subMode) {
    DioramaSubMode.normal => (1.0, 0.62, 0.42, 1.0, 1.0),
    DioramaSubMode.calm => (0.6, 0.4, 0.56, 0.5, 0.5),
    DioramaSubMode.chaotic => (1.35, 0.85, 0.33, 1.35, 1.35),
  };
  final double motion = motionAmount.clamp(0.4, 1.6);
  final double speed = cameraSpeed.clamp(0.55, 1.85);
  final double a = audioReactivity.clamp(0.0, 1.5);
  return DioramaMotionParams(
    moveScale: move * motion,
    driftScale: drift * motion,
    smoothTime: smooth / speed,
    audioLevel: audio * a,
    weaveScale: weave * motion,
    subMode: subMode,
  );
}

// ─── 蜿蜒路径与每句坐标系 ──────────────────────────────────────────────────

class DioramaFrame {
  const DioramaFrame({
    required this.position,
    required this.forward,
    required this.right,
    required this.up,
  });

  final DioramaVec position;
  final DioramaVec forward;
  final DioramaVec right;
  final DioramaVec up;

  static const DioramaFrame straight = DioramaFrame(
    position: DioramaVec.zero,
    forward: DioramaVec(0, 0, -1),
    right: DioramaVec(1, 0, 0),
    up: DioramaVec(0, 1, 0),
  );

  DioramaFrame translated(DioramaVec offset) => DioramaFrame(
    position: position + offset,
    forward: forward,
    right: right,
    up: up,
  );

  /// 沿同一航向继续 [steps] 句（路径只在有歌词的地方存在，延伸让尘埃 / 隧道不在末句断掉）。
  DioramaFrame extended(int steps) => steps == 0
      ? this
      : DioramaFrame(
          position: position + forward * (dioramaStepDistance * steps),
          forward: forward,
          right: right,
          up: up,
        );

  /// 本地 (右, 上, 纵深) → 世界点；纵深为正 = 沿路径往前（远离相机、在文字后面）。
  DioramaVec compose(double r, double u, double d) => DioramaVec(
    position.x + right.x * r + up.x * u + forward.x * d,
    position.y + right.y * r + up.y * u + forward.y * d,
    position.z + right.z * r + up.z * u + forward.z * d,
  );
}

/// 为一首歌建整条走廊（folia `buildDioramaPath`）。
List<DioramaFrame> buildDioramaPath(int count, int seed) {
  final int base = dioramaHashSeed(seed);
  final int n = math.max(count, 1);
  final List<DioramaVec> positions = <DioramaVec>[];
  DioramaVec pos = DioramaVec.zero;
  for (int i = 0; i <= n; i++) {
    positions.add(pos);
    final double yaw =
        dioramaMaxYaw *
        (math.sin(i * 0.23 + base * 0.017) * 0.62 +
            math.sin(i * 0.11 + base * 0.041 + 1.3) * 0.38);
    final double pitch =
        dioramaMaxPitch * math.sin(i * 0.17 + base * 0.029 + 0.7);
    final double cp = math.cos(pitch);
    final DioramaVec dir = DioramaVec(
      math.sin(yaw) * cp,
      math.sin(pitch),
      -math.cos(yaw) * cp,
    );
    pos = pos + dir * dioramaStepDistance;
  }
  final List<DioramaFrame> frames = <DioramaFrame>[];
  for (int i = 0; i < n; i++) {
    final DioramaVec forward = (positions[i + 1] - positions[i]).normalized;
    final DioramaVec right = forward.cross(DioramaVec.worldUp).normalized;
    final DioramaVec up = right.cross(forward).normalized;
    frames.add(
      DioramaFrame(
        position: positions[i],
        forward: forward,
        right: right,
        up: up,
      ),
    );
  }
  return frames;
}

DioramaFrame dioramaFrameAt(List<DioramaFrame> frames, int index) {
  if (frames.isEmpty) return DioramaFrame.straight;
  return frames[index.clamp(0, frames.length - 1)];
}

/// 读头横向跟随唱到的字（tanh 饱和，没有硬夹的拐角）。
double resolveDioramaReadHeadTruck(
  double wordProgress,
  double trackWidth,
  double visibleHalfWidth,
) {
  if (trackWidth <= 0) return 0;
  final double wordOffset = (dioramaClamp01(wordProgress) - 0.5) * trackWidth;
  final double allowed = math.max(
    (visibleHalfWidth - trackWidth / 2).abs(),
    0.001,
  );
  return allowed * _tanh(wordOffset / allowed);
}

double _tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  final double e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

// ─── 每句文字的自由摆放 ────────────────────────────────────────────────────

class DioramaTextPlacement {
  const DioramaTextPlacement({
    required this.offsetR,
    required this.offsetU,
    required this.scale,
    required this.roll,
    required this.yaw,
    required this.lookR,
  });

  final double offsetR;
  final double offsetU;
  final double scale;
  final double roll;
  final double yaw;
  final double lookR;
}

DioramaTextPlacement dioramaTextPlacement(
  int lineIndex,
  int seed,
  double weave,
) {
  final int base = dioramaHashSeed(seed);
  final int i = math.max(lineIndex, 0);
  final double jitterR = (dioramaSeededUnit(base + i * 11.0 + 2) - 0.5) * 0.6;
  final double jitterU = (dioramaSeededUnit(base + i * 11.0 + 4) - 0.5) * 0.6;
  final double wanderR = math.sin(i * 0.47 + base * 0.019) * 0.7 + jitterR;
  final double wanderU =
      math.sin(i * 0.29 + base * 0.027 + 0.9) * 0.7 + jitterU;
  return DioramaTextPlacement(
    offsetR: wanderR * dioramaTextOffsetR * weave,
    offsetU: wanderU * dioramaTextOffsetU * weave,
    scale: 0.82 + dioramaSeededUnit(base + i * 11.0 + 5) * 0.46,
    roll:
        (dioramaSeededUnit(base + i * 11.0 + 6) - 0.5) *
        2 *
        dioramaTextRoll *
        weave,
    yaw:
        (dioramaSeededUnit(base + i * 11.0 + 7) - 0.5) *
        2 *
        dioramaTextYaw *
        weave,
    lookR:
        (dioramaSeededUnit(base + i * 11.0 + 8) - 0.5) *
        2 *
        dioramaTextLook *
        weave,
  );
}

/// 文字朝向：本地 +X → 坐标系右、+Y → 上、+Z → -前，再叠偏航与滚转（folia `frameQuaternion`）。
DioramaQuat dioramaFrameQuaternion(
  DioramaFrame frame, {
  double roll = 0,
  double yaw = 0,
}) {
  DioramaQuat q = DioramaQuat.fromBasis(frame.right, frame.up, -frame.forward);
  if (yaw != 0) q = q * DioramaQuat.axisAngle(const DioramaVec(0, 1, 0), yaw);
  if (roll != 0) q = q * DioramaQuat.axisAngle(const DioramaVec(0, 0, 1), roll);
  return q;
}

// ─── 运镜语言 ──────────────────────────────────────────────────────────────

enum DioramaShotKind {
  pushIn,
  pullBack,
  orbit,
  track,
  crane,
  hold,
  swell,
  spiral,
  pendulum,
  flyby,
  arc,
  float,
  glide,
}

/// 运镜选择需要的一句歌词的性格（folia 直接读 `Line`；这里抽成与数据源无关的形状）。
class DioramaLineCharacter {
  const DioramaLineCharacter({
    required this.noteSeconds,
    required this.isChorus,
    required this.sectionStart,
  });

  /// 每个音节（folia 的 word）的时长（秒）。
  final List<double> noteSeconds;
  final bool isChorus;

  /// 是段落开头（folia 用 blockIndex / songPart 变化判定）。
  final bool sectionStart;
}

/// 左右手性：轨道往哪边绕、飞掠从哪边过。阵列同用，保证几何生在相机要去的那一侧。
int dioramaShotDir(int lineIndex, int seed) =>
    dioramaSeededUnit(dioramaHashSeed(seed) + lineIndex * 7.0 + 3) < 0.5
    ? -1
    : 1;

Map<DioramaShotKind, double> _shotWeights(
  DioramaLineCharacter line,
  DioramaSubMode subMode,
) {
  double maxNote = 0;
  double sum = 0;
  int noteCount = 0;
  for (final double d in line.noteSeconds) {
    if (d > 0) {
      maxNote = math.max(maxNote, d);
      sum += d;
      noteCount++;
    }
  }
  final double avgNote = noteCount > 0 ? sum / noteCount : 0;
  final int wordCount = line.noteSeconds.length;
  final bool hasLongNote = maxNote >= 1.3;
  final bool staccato = noteCount >= 4 && avgNote > 0 && avgNote <= 0.34;
  final Map<DioramaShotKind, double> w = <DioramaShotKind, double>{
    DioramaShotKind.pushIn: 1,
    DioramaShotKind.pullBack: 1,
    DioramaShotKind.orbit: 1,
    DioramaShotKind.track: 1,
    DioramaShotKind.crane: 1,
    DioramaShotKind.hold: 1,
    DioramaShotKind.swell: 0.85,
    DioramaShotKind.spiral: 0.9,
    DioramaShotKind.pendulum: 1,
    DioramaShotKind.flyby: 0.9,
    DioramaShotKind.arc: 1,
    DioramaShotKind.float: 0.9,
    DioramaShotKind.glide: 1,
  };
  void add(DioramaShotKind k, double v) => w[k] = w[k]! + v;
  void mul(DioramaShotKind k, double v) => w[k] = w[k]! * v;
  if (line.isChorus) {
    add(DioramaShotKind.orbit, 2.4);
    add(DioramaShotKind.pushIn, 1.8);
    add(DioramaShotKind.spiral, 1.2);
    add(DioramaShotKind.crane, 0.8);
    add(DioramaShotKind.flyby, 0.6);
    add(DioramaShotKind.arc, 1.0);
    add(DioramaShotKind.glide, 0.6);
    add(DioramaShotKind.hold, -0.6);
    add(DioramaShotKind.track, -0.2);
  } else {
    add(DioramaShotKind.track, 1.1);
    add(DioramaShotKind.crane, 0.9);
    add(DioramaShotKind.hold, 0.9);
    add(DioramaShotKind.pendulum, 0.8);
    add(DioramaShotKind.float, 0.8);
    add(DioramaShotKind.glide, 0.6);
    add(DioramaShotKind.arc, 0.4);
  }
  if (wordCount >= 8) {
    add(DioramaShotKind.track, 1.6);
    add(DioramaShotKind.pullBack, 1);
    add(DioramaShotKind.orbit, -0.4);
    add(DioramaShotKind.pushIn, -0.3);
  } else if (wordCount <= 3) {
    add(DioramaShotKind.pushIn, 1.4);
    add(DioramaShotKind.orbit, 0.9);
    add(DioramaShotKind.hold, 0.5);
    add(DioramaShotKind.track, -0.8);
  }
  if (line.sectionStart) {
    add(DioramaShotKind.pullBack, 2.2);
    add(DioramaShotKind.crane, 1.4);
    add(DioramaShotKind.glide, 1.0);
    add(DioramaShotKind.pushIn, -0.4);
  }
  if (hasLongNote) {
    add(DioramaShotKind.swell, 2.4);
    add(DioramaShotKind.spiral, 1.0);
    add(DioramaShotKind.float, 1.2);
    add(DioramaShotKind.pendulum, 0.6);
    add(DioramaShotKind.orbit, 0.8);
    add(DioramaShotKind.arc, 0.6);
    add(DioramaShotKind.hold, 0.3);
    add(DioramaShotKind.track, -0.5);
  }
  if (staccato) {
    add(DioramaShotKind.track, 1.4);
    add(DioramaShotKind.flyby, 1.5);
    add(DioramaShotKind.pushIn, 0.8);
    add(DioramaShotKind.swell, -1.6);
    add(DioramaShotKind.hold, -0.8);
    add(DioramaShotKind.crane, -0.4);
  }
  if (subMode == DioramaSubMode.calm) {
    add(DioramaShotKind.hold, 1.4);
    add(DioramaShotKind.float, 1.3);
    add(DioramaShotKind.swell, 0.9);
    add(DioramaShotKind.glide, 0.8);
    add(DioramaShotKind.arc, 0.5);
    add(DioramaShotKind.crane, 0.4);
    mul(DioramaShotKind.orbit, 0.4);
    mul(DioramaShotKind.spiral, 0.35);
    mul(DioramaShotKind.flyby, 0.3);
    mul(DioramaShotKind.pendulum, 0.5);
    mul(DioramaShotKind.pushIn, 0.7);
  } else if (subMode == DioramaSubMode.chaotic) {
    add(DioramaShotKind.orbit, 1.3);
    add(DioramaShotKind.spiral, 1.3);
    add(DioramaShotKind.flyby, 1.2);
    add(DioramaShotKind.pendulum, 1.0);
    add(DioramaShotKind.pushIn, 0.8);
    add(DioramaShotKind.arc, 0.6);
    add(DioramaShotKind.crane, 0.4);
    mul(DioramaShotKind.hold, 0.35);
    mul(DioramaShotKind.float, 0.55);
    mul(DioramaShotKind.swell, 0.7);
  }
  for (final DioramaShotKind k in DioramaShotKind.values) {
    w[k] = math.max(0.05, w[k]!);
  }
  return w;
}

DioramaShotKind _weightedPick(Map<DioramaShotKind, double> weights, double u) {
  double total = 0;
  for (final DioramaShotKind k in DioramaShotKind.values) {
    total += weights[k]!;
  }
  double acc = dioramaClamp01(u) * total;
  for (final DioramaShotKind k in DioramaShotKind.values) {
    acc -= weights[k]!;
    if (acc <= 0) return k;
  }
  return DioramaShotKind.hold;
}

DioramaShotKind? _basePick(
  int lineIndex,
  List<DioramaLineCharacter> lines,
  int seed,
  DioramaSubMode subMode,
) {
  if (lineIndex < 0 || lineIndex >= lines.length) return null;
  final double u = dioramaSeededUnit(
    dioramaHashSeed(seed) + lineIndex * 101.0 + 7,
  );
  return _weightedPick(_shotWeights(lines[lineIndex], subMode), u);
}

/// 一句的运镜：加权抽取；与前两句任一相同就换一个，避免同几种动作扎堆（folia `getDioramaShot`）。
DioramaShotKind dioramaShotFor(
  int lineIndex,
  List<DioramaLineCharacter> lines,
  int seed,
  DioramaSubMode subMode,
) {
  final DioramaShotKind? pick = _basePick(lineIndex, lines, seed, subMode);
  if (pick == null) return DioramaShotKind.hold;
  final DioramaShotKind? prev1 = _basePick(lineIndex - 1, lines, seed, subMode);
  final DioramaShotKind? prev2 = _basePick(lineIndex - 2, lines, seed, subMode);
  if (pick == prev1 || pick == prev2) {
    List<DioramaShotKind> pool = DioramaShotKind.values
        .where((DioramaShotKind k) => k != pick && k != prev1 && k != prev2)
        .toList();
    if (pool.isEmpty) {
      pool = DioramaShotKind.values
          .where((DioramaShotKind k) => k != pick)
          .toList();
    }
    final double alt = dioramaSeededUnit(
      dioramaHashSeed(seed) + lineIndex * 53.0 + 19,
    );
    return pool[(dioramaClamp01(alt) * pool.length).floor() % pool.length];
  }
  return pick;
}

class DioramaShotOffset {
  const DioramaShotOffset({
    required this.right,
    required this.up,
    required this.back,
  });

  final double right;
  final double up;
  final double back;
}

double _easeInOut(double p) {
  final double c = dioramaClamp01(p);
  return c * c * (3 - 2 * c);
}

/// 运镜 + 进度 → 本地 (右, 上, 后) 相机偏移（folia `resolveShotOffset`）。
DioramaShotOffset resolveDioramaShotOffset(
  DioramaShotKind kind, {
  required double progress,
  required double wordProgress,
  required double hero,
  required double lift,
  required int seed,
  required int lineIndex,
  required double moveScale,
}) {
  final double e = _easeInOut(progress);
  final int dir = dioramaShotDir(lineIndex, seed);
  double right = 0;
  double up = lift;
  double back = hero;
  switch (kind) {
    case DioramaShotKind.pushIn:
      back = hero * (1.5 - 0.8 * e);
      up = lift * (1.2 - 0.5 * e) + 0.15;
    case DioramaShotKind.pullBack:
      back = hero * (0.85 + 1.15 * e);
      up = lift + 1.7 * e;
    case DioramaShotKind.orbit:
      final double theta = dir * 0.55 * (2 * e - 1);
      right = hero * math.sin(theta);
      back = hero * math.cos(theta);
      up = lift + 0.4;
    case DioramaShotKind.track:
      right =
          dir * hero * 0.34 * math.sin(math.pi * dioramaClamp01(wordProgress));
      back = hero * 1.06;
      up = lift + 0.12;
    case DioramaShotKind.crane:
      final double from = dir > 0 ? -1.5 : 2.4;
      final double to = dir > 0 ? 2.4 : -1.4;
      up = from + (to - from) * e;
      back = hero * 1.05;
    case DioramaShotKind.swell:
      final double theta = dir * 0.4 * e;
      right = hero * math.sin(theta) * 1.1;
      back = hero * (1.0 + 0.35 * e);
      up = lift + 1.2 * e + 0.3;
    case DioramaShotKind.spiral:
      final double theta = dir * 0.7 * (2 * e - 1);
      right = hero * math.sin(theta) * 0.85;
      back = hero * (1.05 - 0.1 * e);
      up = lift - 0.8 + 2.4 * e;
    case DioramaShotKind.pendulum:
      right = dir * hero * 0.45 * (2 * e - 1);
      up = lift + 0.9 - 0.9 * math.sin(math.pi * e);
      back = hero * 1.02;
    case DioramaShotKind.flyby:
      right = dir * hero * (0.7 - 1.4 * e);
      back = hero * (0.78 + 0.12 * math.sin(math.pi * e));
      up = lift + 0.05;
    case DioramaShotKind.arc:
      final double theta = dir * 0.5 * math.sin(math.pi * e);
      right = hero * math.sin(theta) * 1.3;
      back = hero * (1.05 + 0.12 * (1 - math.cos(theta)));
      up = lift + 0.5 * math.sin(math.pi * e);
    case DioramaShotKind.float:
      right = dir * hero * 0.16 * math.sin(e * math.pi * 2);
      up = lift + 0.6 + 0.5 * math.sin(e * math.pi * 2 + 1.0);
      back = hero * (1.05 + 0.06 * math.sin(e * math.pi));
    case DioramaShotKind.glide:
      right = dir * hero * 0.22 * e;
      up = lift + 1.4 * e;
      back = hero * (1.15 - 0.25 * e);
    case DioramaShotKind.hold:
      up = lift + 0.3 * math.sin(progress * math.pi);
      back = hero;
  }
  final double m = moveScale;
  return DioramaShotOffset(
    right: right * m,
    up: lift + (up - lift) * m,
    back: hero + (back - hero) * m,
  );
}

/// 停在已唱完的一句上太久（超过 3 秒、即歌词本身认定的间奏）时，构图慢慢回正（folia
/// `resolveHoldSettle`）；3 秒以内恒为 1。
double resolveDioramaHoldSettle(double secondsHeld) {
  final double t = dioramaClamp01((secondsHeld - 3) / 5);
  return 1 - t * t * (3 - 2 * t);
}

class DioramaCameraDrift {
  const DioramaCameraDrift({
    required this.swayX,
    required this.swayY,
    required this.lift,
    required this.dist,
  });

  final double swayX;
  final double swayY;
  final double lift;
  final double dist;
}

/// 手持感的闲置漂移（层叠慢正弦）。
DioramaCameraDrift resolveDioramaCameraDrift(
  double time,
  int seed,
  double scale,
) {
  final double ph = dioramaHashSeed(seed) * 0.017;
  return DioramaCameraDrift(
    swayX:
        (math.sin(time * 0.11 + ph) * 0.6 +
            math.sin(time * 0.047 + ph * 1.7) * 0.4) *
        dioramaSwayAmp *
        scale,
    swayY: math.sin(time * 0.09 + ph * 0.7) * dioramaSwayAmp * 0.5 * scale,
    lift:
        (math.sin(time * 0.13 + ph * 1.3) * 0.6 +
            math.sin(time * 0.061 + ph * 2.1) * 0.4) *
        dioramaLiftAmp *
        scale,
    dist: math.sin(time * 0.05 + ph * 1.1) * dioramaDistAmp * scale,
  );
}

// ─── 程序化阵列 ────────────────────────────────────────────────────────────

/// 点云图元：box = 立方体，sphere = 开口圆柱壳，cone = 三角晶体（四面体），torus = 圆环。
enum DioramaShapeKind { box, sphere, cone, torus }

class DioramaShapePlacement {
  const DioramaShapePlacement({
    required this.kind,
    required this.position,
    required this.scale,
    required this.stretchY,
    required this.colorSlot,
    required this.isFar,
  });

  final DioramaShapeKind kind;
  final DioramaVec position;
  final double scale;
  final double stretchY;
  final int colorSlot;

  /// 视差层：远景 = 纵深 > 3.5。
  final bool isFar;
}

/// 点云随节拍的最大整体缩放。
const double dioramaParticleAudioScaleMax = 1.44;

class _Spec {
  _Spec(
    this.kind,
    this.r,
    this.u,
    this.d,
    this.scale,
    this.stretchY,
    this.colorSlot,
  );

  final DioramaShapeKind kind;
  double r;
  double u;
  double d;
  final double scale;
  final double stretchY;
  final int? colorSlot;
}

double dioramaFamilyRadius(DioramaShapeKind kind) => switch (kind) {
  DioramaShapeKind.box => 0.5,
  DioramaShapeKind.sphere => 0.74,
  DioramaShapeKind.cone => 0.68,
  DioramaShapeKind.torus => 0.9,
};

double _specRadius(_Spec s) =>
    s.scale * math.max(dioramaFamilyRadius(s.kind), s.stretchY * 0.55);

void _separateSpecs(List<_Spec> specs) {
  for (int iter = 0; iter < 6; iter++) {
    for (int a = 0; a < specs.length; a++) {
      for (int b = a + 1; b < specs.length; b++) {
        final _Spec A = specs[a];
        final _Spec B = specs[b];
        final double minDist = (_specRadius(A) + _specRadius(B)) * 1.3;
        double dr = B.r - A.r;
        double du = B.u - A.u;
        double dd = B.d - A.d;
        double dist = math.sqrt(dr * dr + du * du + dd * dd);
        if (dist >= minDist) continue;
        if (dist < 0.001) {
          dr = 1;
          du = 0.5;
          dd = 0.25;
          dist = math.sqrt(dr * dr + du * du + dd * dd);
        }
        final double push = (minDist - dist) / 2 / dist;
        A.r -= dr * push;
        A.u -= du * push;
        A.d -= dd * push;
        B.r += dr * push;
        B.u += du * push;
        B.d += dd * push;
      }
    }
  }
  for (final _Spec s in specs) {
    s.d = math.max(s.d, 1);
  }
}

const double _textClearLateral = 5.2;
const double _textClearVertical = 1.4;

void _enforceTextClearance(List<_Spec> specs) {
  for (int i = 0; i < specs.length; i++) {
    final _Spec s = specs[i];
    final double radius = _specRadius(s) * dioramaParticleAudioScaleMax;
    if (s.u.abs() - radius < _textClearVertical &&
        s.r.abs() - radius < _textClearLateral) {
      final double side = s.r == 0 ? (i.isEven ? 1 : -1) : s.r.sign;
      s.r = side * (_textClearLateral + radius + 0.35);
    }
  }
}

void _enforceRailClearance(List<_Spec> specs) {
  for (int i = 0; i < specs.length; i++) {
    final _Spec s = specs[i];
    final double radius = _specRadius(s) * dioramaParticleAudioScaleMax;
    final double minimum = 2.8 + radius;
    final double distance = math.sqrt(s.r * s.r + s.u * s.u);
    if (distance >= minimum) continue;
    final double fallbackAngle = (i.isEven ? 1 : -1) * math.pi * 0.16;
    final double dirR = distance > 0.001
        ? s.r / distance
        : math.cos(fallbackAngle);
    final double dirU = distance > 0.001
        ? s.u / distance
        : math.sin(fallbackAngle);
    s.r = dirR * minimum;
    s.u = dirU * minimum;
  }
}

/// 按运镜长一组阵列（folia `buildFormation`）：轨道配环、推进配门柱、横移配柱廊、升降配拱……
List<DioramaShapePlacement> buildDioramaFormation(
  int lineIndex,
  int seed,
  DioramaShotKind shot,
  DioramaFrame frame,
  DioramaTextPlacement placement, {
  double volumeScale = 1,
}) {
  final double salt = dioramaHashSeed(seed) + lineIndex * 97.0;
  double rnd(num k) => dioramaSeededUnit(salt + k);
  final int dir = dioramaShotDir(lineIndex, seed);
  final List<_Spec> specs = <_Spec>[];
  final double vol = volumeScale.clamp(0.65, 1.6);
  void add(
    DioramaShapeKind kind,
    double r,
    double u,
    double d,
    double scale, [
    double stretchY = 1,
    int? colorSlot,
  ]) => specs.add(_Spec(kind, r, u, d, scale * vol, stretchY, colorSlot));
  void addPair(
    DioramaShapeKind kind,
    double lateral,
    double u,
    double d,
    double scale, [
    double stretchY = 1,
    int colorSlot = 0,
  ]) {
    add(kind, -lateral.abs(), u, d, scale, stretchY, colorSlot);
    add(kind, lateral.abs(), u, d, scale, stretchY, colorSlot);
  }

  switch (shot) {
    case DioramaShotKind.orbit:
      const int count = 6;
      final double radius = 4.4 + rnd(1) * 0.6;
      for (int j = 0; j < count; j++) {
        final double a = (j / count) * math.pi * 2 + rnd(2) * 0.6;
        add(
          j == 0 ? DioramaShapeKind.torus : DioramaShapeKind.sphere,
          math.cos(a) * radius,
          math.sin(a) * radius,
          0.6 + rnd(10 + j) * 1.4,
          0.42 + rnd(20 + j) * 0.32,
        );
      }
    case DioramaShotKind.pushIn:
      final double gate = 4.3 + rnd(1) * 0.5;
      for (int idx = 0; idx < 2; idx++) {
        final int side = idx == 0 ? -1 : 1;
        add(
          DioramaShapeKind.box,
          side * gate,
          -0.6,
          0.5 + rnd(idx) * 0.5,
          0.55 + rnd(2 + idx) * 0.2,
          2.8 + rnd(6 + idx) * 0.8,
        );
        add(
          DioramaShapeKind.box,
          side * (gate + 1.6),
          0.6,
          4.5 + rnd(3 + idx) * 2,
          0.7 + rnd(4 + idx) * 0.3,
          3.4,
        );
      }
    case DioramaShotKind.track:
      for (int si = 0; si < 2; si++) {
        final int side = si == 0 ? -1 : 1;
        for (int j = 0; j < 3; j++) {
          add(
            DioramaShapeKind.box,
            side * (4.2 + rnd(si * 5 + j) * 0.4),
            -0.4 + (rnd(si * 7 + j) - 0.5) * 0.6,
            0.5 + j * 2.4,
            0.5 + rnd(si * 3 + j) * 0.15,
            2.6 + rnd(si + j) * 0.6,
          );
        }
      }
    case DioramaShotKind.crane:
      const int count = 5;
      final double radius = 3.6 + rnd(1) * 0.5;
      for (int j = 0; j < count; j++) {
        final double a = math.pi * (0.15 + 0.7 * (j / (count - 1)));
        add(
          DioramaShapeKind.box,
          math.cos(a) * radius,
          math.sin(a).abs() * radius + 1.2,
          0.6 + rnd(30 + j) * 0.8,
          0.45 + rnd(40 + j) * 0.25,
          1.4,
        );
      }
    case DioramaShotKind.swell:
      final double lat = 4.2 + rnd(2) * 0.5;
      for (int j = 0; j < 2; j++) {
        addPair(
          DioramaShapeKind.box,
          lat,
          -1.5 + j * 2.1,
          1 + j * 1.2,
          0.48 - j * 0.06,
          1.45,
          j % 2,
        );
      }
      addPair(DioramaShapeKind.sphere, lat, 2.65, 3.4, 0.5, 1, 0);
    case DioramaShotKind.spiral:
      const int count = 7;
      const double radius = 4.3;
      for (int j = 0; j < count; j++) {
        final double frac = j / (count - 1);
        final double a = dir * frac * math.pi * 2.2 + rnd(1) * 0.5;
        add(
          DioramaShapeKind.sphere,
          math.cos(a) * radius,
          -2.2 + frac * 5.2,
          0.5 + frac * 2.2,
          0.32 + rnd(20 + j) * 0.2,
        );
      }
    case DioramaShotKind.pendulum:
      for (int j = 0; j < 4; j++) {
        add(
          DioramaShapeKind.box,
          -3.9 + j * 2.6 + (rnd(j) - 0.5) * 0.5,
          3.0 + rnd(j * 2) * 1.2,
          0.5 + rnd(j * 3) * 1.2,
          0.3 + rnd(j * 4) * 0.12,
          2.2 + rnd(j * 5) * 0.8,
        );
      }
    case DioramaShotKind.flyby:
      for (int j = 0; j < 3; j++) {
        addPair(
          DioramaShapeKind.box,
          4.25 + rnd(j) * 0.25,
          -0.45 + j * 0.45,
          1 + j * 2.1,
          0.42 + rnd(j * 3) * 0.1,
          2.2,
          j % 2,
        );
      }
    case DioramaShotKind.pullBack:
      addPair(
        DioramaShapeKind.sphere,
        5.8 + rnd(9) * 0.5,
        1.25,
        6.8 + rnd(11),
        1.25 + rnd(12) * 0.25,
        1,
        0,
      );
      for (int j = 0; j < 2; j++) {
        addPair(
          j == 0 ? DioramaShapeKind.box : DioramaShapeKind.cone,
          4.4 + j * 1.15,
          -1.4 + j * 2.2,
          2.2 + j * 2.1,
          0.58 + rnd(j * 4) * 0.18,
          j == 0 ? 1.5 : 1,
          1,
        );
      }
    case DioramaShotKind.arc:
      const int count = 5;
      final double radius = 5.2 + rnd(1) * 0.6;
      for (int j = 0; j < count; j++) {
        final double a = (-0.5 + j / (count - 1)) * 1.5 * dir;
        add(
          j == count ~/ 2 ? DioramaShapeKind.torus : DioramaShapeKind.sphere,
          math.sin(a) * radius,
          0.3 + math.cos(a) * 0.7,
          1.0 + rnd(20 + j) * 1.6,
          0.45 + rnd(30 + j) * 0.32,
        );
      }
    case DioramaShotKind.float:
      for (int j = 0; j < 3; j++) {
        addPair(
          DioramaShapeKind.sphere,
          4.1 + j * 0.85,
          -1.2 + j * 1.35,
          1.2 + j * 1.55,
          0.42 + rnd(j * 4) * 0.22,
          1,
          j % 2,
        );
      }
    case DioramaShotKind.glide:
      for (int j = 0; j < 3; j++) {
        addPair(
          DioramaShapeKind.box,
          4.25 + rnd(j) * 0.3,
          -1.5 + j * 1.7,
          1 + j * 1.7,
          0.46 + rnd(j * 2) * 0.12,
          1.85,
          j % 2,
        );
      }
    case DioramaShotKind.hold:
      addPair(
        DioramaShapeKind.torus,
        5.6,
        1.55,
        7.2 + rnd(1),
        1.05 + rnd(2) * 0.2,
        1,
        0,
      );
      addPair(
        DioramaShapeKind.sphere,
        4.45,
        -1.1,
        2.1 + rnd(4),
        0.58 + rnd(5) * 0.16,
        1,
        1,
      );
  }

  _enforceRailClearance(specs);
  _enforceTextClearance(specs);
  _separateSpecs(specs);
  _enforceRailClearance(specs);
  _enforceTextClearance(specs);

  return <DioramaShapePlacement>[
    for (int j = 0; j < specs.length; j++)
      DioramaShapePlacement(
        kind: specs[j].kind,
        position: frame.compose(
          placement.offsetR + specs[j].r,
          placement.offsetU + specs[j].u,
          specs[j].d,
        ),
        scale: specs[j].scale,
        stretchY: specs[j].stretchY,
        colorSlot: specs[j].colorSlot ?? (j % 2),
        isFar: specs[j].d > 3.5,
      ),
  ];
}

/// 几何的距离生命周期：远处从雾里生出，贴近镜头时溶掉。
double resolveDioramaShapeLife(double distanceToCamera) {
  final double farT = dioramaClamp01(
    (dioramaShapeFadeInEnd - distanceToCamera) /
        (dioramaShapeFadeInEnd - dioramaShapeFadeInStart),
  );
  final double nearT = dioramaClamp01(
    (distanceToCamera - dioramaShapeDissolveEnd) /
        (dioramaShapeDissolveStart - dioramaShapeDissolveEnd),
  );
  return farT * farT * (3 - 2 * farT) * nearT * nearT * (3 - 2 * nearT);
}
