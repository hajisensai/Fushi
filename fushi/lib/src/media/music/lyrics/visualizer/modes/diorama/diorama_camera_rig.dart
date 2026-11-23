/// 镜台的相机（folia `CameraRig.tsx`）：每帧用 SmoothDamp 追「读头」（这句文字实际落点 + 跟着
/// 唱到的字横移），按这句分到的运镜给出偏移；朝向先合成目标（瞄准 + 读字回正 + 保证不出画），
/// 再由唯一一个四元数低通跟随器写进相机，上游的任何折点都变成平滑转动。切歌 / 循环时在正常跟随
/// 之上叠一段弧线飞行。相机不读音频。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_sequencer.dart';

/// 一帧的相机：位置、朝向与视口；负责把世界点投到屏幕。
class DioramaCamera {
  DioramaCamera({
    required this.position,
    required this.orientation,
    required this.width,
    required this.height,
    this.fovDeg = dioramaFovDeg,
  }) : right = orientation.rotate(const DioramaVec(1, 0, 0)),
       up = orientation.rotate(const DioramaVec(0, 1, 0)),
       back = orientation.rotate(const DioramaVec(0, 0, 1)),
       focal = height / 2 / math.tan(fovDeg * math.pi / 360);

  final DioramaVec position;
  final DioramaQuat orientation;
  final double width;
  final double height;
  final double fovDeg;
  final DioramaVec right;
  final DioramaVec up;
  final DioramaVec back;

  /// 屏幕像素 / (世界单位 / 深度)。
  final double focal;

  /// 近裁剪面。
  static const double near = 0.1;

  double get aspect => height <= 0 ? 1 : width / height;

  /// 相机空间：(x 右, y 上, depth 向前为正)。
  (double, double, double) toView(double x, double y, double z) {
    final double rx = x - position.x;
    final double ry = y - position.y;
    final double rz = z - position.z;
    return (
      rx * right.x + ry * right.y + rz * right.z,
      rx * up.x + ry * up.y + rz * up.z,
      -(rx * back.x + ry * back.y + rz * back.z),
    );
  }

  /// 世界点 → 屏幕 (x, y, depth)；在近裁剪面后面时 depth ≤ near。
  (double, double, double) project(DioramaVec p) {
    final (double xc, double yc, double d) = toView(p.x, p.y, p.z);
    if (d <= near) return (0, 0, d);
    return (width / 2 + xc / d * focal, height / 2 - yc / d * focal, d);
  }

  /// 世界方向 → 相机空间方向（不平移）。
  (double, double, double) dirToView(DioramaVec v) =>
      (v.dot(right), v.dot(up), -v.dot(back));
}

/// 运镜风格对应的读字回正上限（composed 的镜头几乎完全回正，表现型的只回一部分）。
double _alignCeiling(DioramaShotKind k) => switch (k) {
  DioramaShotKind.hold => 0.9,
  DioramaShotKind.pushIn => 0.85,
  DioramaShotKind.track => 0.85,
  DioramaShotKind.swell => 0.8,
  DioramaShotKind.float => 0.78,
  DioramaShotKind.glide => 0.72,
  DioramaShotKind.crane => 0.7,
  DioramaShotKind.pullBack => 0.7,
  DioramaShotKind.arc => 0.62,
  DioramaShotKind.pendulum => 0.6,
  DioramaShotKind.orbit => 0.55,
  DioramaShotKind.spiral => 0.5,
  DioramaShotKind.flyby => 0.5,
};

const double _alignLeadIn = 0.6;
const double _alignSettle = 0.35;
const double _alignRelease = 1.0;
const double _alignRate = 1.2;
const double _alignTurnRate = 2.6;
const double _frameKeepFraction = 0.7;
const double _orientFollowRate = 4.2;
const double _flightSmoothTime = 1.1;
const double _flightArcFrac = 0.16;

class DioramaCameraRig {
  DioramaVec _pos = const DioramaVec(0, 0.6, 9);
  DioramaVec _posVel = DioramaVec.zero;
  DioramaVec _look = const DioramaVec(0, 0, -10);
  DioramaVec _lookVel = DioramaVec.zero;
  double _align = 0;
  DioramaQuat _alignQuat = DioramaQuat.identity;
  bool _alignInit = false;
  DioramaQuat _orient = DioramaQuat.identity;
  bool _orientInit = false;

  // 飞行
  bool _flying = false;
  int _flightEpoch = 0;
  double _flightStart = 0;
  DioramaVec _flightPerp = const DioramaVec(1, 0, 0);
  int _flightSide = 1;
  double _flightLen = 1;

  bool get flying => _flying;

  /// 推进一帧并返回相机。[resolved] 为 null（换歌的瞬时空档）时保持当前位姿。
  DioramaCamera step({
    required DioramaResolvedLine? resolved,
    required double now,
    required double delta,
    required double elapsed,
    required DioramaMotionParams motion,
    required bool animate,
    required double activeLineWidth,
    required int transitionEpoch,
    required double width,
    required double height,
  }) {
    final double aspect = height <= 0 ? 1 : width / height;
    if (resolved == null) {
      return DioramaCamera(
        position: _pos,
        orientation: _orient,
        width: width,
        height: height,
      );
    }
    final DioramaSceneLine? line = resolved.line;
    final int seed = resolved.segment.seed;
    final DioramaShotKind shotKind = line == null
        ? DioramaShotKind.hold
        : dioramaShotFor(
            resolved.localIndex,
            resolved.segment.characters,
            seed,
            motion.subMode,
          );
    final DioramaTextPlacement placement = dioramaTextPlacement(
      resolved.localIndex,
      seed,
      motion.weaveScale,
    );

    final double wordProgress = line?.wordProgress(now) ?? 0;
    double progress = line == null ? 0 : 1;
    if (line != null) {
      final double span = line.end - line.start;
      progress = span > 0
          ? dioramaClamp01((now - line.start) / span)
          : (now >= line.start ? 1 : 0);
    }
    final double visibleHalf =
        dioramaFrameHalfWidth(dioramaHeroDistance, dioramaFovDeg, aspect) *
        dioramaSafeFrameFraction;
    final DioramaFrame frame = resolved.frame;
    final DioramaVec r = frame.right;
    final DioramaVec u = frame.up;
    final DioramaVec f = frame.forward;
    final double settle = line == null
        ? 1
        : resolveDioramaHoldSettle(now - line.end);

    // 静态（减弱动态效果）：中性机位、不横移、不漂移，直接落位。
    final double moveScale = animate ? motion.moveScale * settle : 0;
    final double truck = animate
        ? resolveDioramaReadHeadTruck(
                wordProgress,
                activeLineWidth,
                visibleHalf,
              ) *
              settle
        : 0;
    final DioramaVec base =
        frame.position +
        r * (placement.offsetR + truck) +
        u * placement.offsetU;

    final DioramaShotOffset shot = resolveDioramaShotOffset(
      shotKind,
      progress: progress,
      wordProgress: wordProgress,
      hero: dioramaHeroDistance,
      lift: dioramaCameraLift,
      seed: seed,
      lineIndex: resolved.localIndex,
      moveScale: moveScale,
    );
    final DioramaCameraDrift drift = animate
        ? resolveDioramaCameraDrift(now, seed, motion.driftScale)
        : const DioramaCameraDrift(swayX: 0, swayY: 0, lift: 0, dist: 0);
    final DioramaVec pose =
        base +
        r * (shot.right + drift.swayX) +
        u * (shot.up + drift.swayY + drift.lift) -
        f * (shot.back + drift.dist);

    // ── 切歌飞行：拉长跟随时间 + 衰减的弧线 / 侧倾 / 视线横扫，底下仍是追实时位姿的 SmoothDamp。
    if (animate && transitionEpoch != _flightEpoch && transitionEpoch > 0) {
      _flightEpoch = transitionEpoch;
      _flying = true;
      _flightStart = elapsed;
      _flightPerp = dioramaFlightPerp(_pos, pose);
      _flightSide = dioramaFlightSide(seed, transitionEpoch);
      _flightLen = _pos.distanceTo(pose);
    } else if (!animate) {
      _flightEpoch = transitionEpoch;
      _flying = false;
    }
    double te = 1;
    if (_flying) {
      te = (elapsed - _flightStart) / dioramaTransitionDuration;
      if (te >= 1 || te < 0) _flying = false;
    }
    final bool flying = _flying;
    final double followSmooth = flying
        ? _flightSmoothTime +
              (motion.smoothTime - _flightSmoothTime) *
                  dioramaTransitionEase(te)
        : motion.smoothTime;
    final double swayEnv = flying
        ? math.pow(math.sin(math.pi * te), 2).toDouble()
        : 0;
    final double arcMag = swayEnv * _flightLen * _flightArcFrac;
    final double sweepMag =
        swayEnv * _flightLen * dioramaTransitionAimSweep * _flightSide;
    final double bank = swayEnv * dioramaTransitionBank * _flightSide;

    final double posGap = pose.distanceTo(_pos);
    final bool snapped = !animate || (!flying && posGap > dioramaSnapDistance);
    if (snapped) {
      _pos = pose;
      _posVel = DioramaVec.zero;
    } else {
      final (double sx, double vx) = dioramaSmoothDamp(
        _pos.x,
        pose.x,
        _posVel.x,
        followSmooth,
        delta,
      );
      final (double sy, double vy) = dioramaSmoothDamp(
        _pos.y,
        pose.y,
        _posVel.y,
        followSmooth,
        delta,
      );
      final (double sz, double vz) = dioramaSmoothDamp(
        _pos.z,
        pose.z,
        _posVel.z,
        followSmooth,
        delta,
      );
      _pos = DioramaVec(sx, sy, sz);
      _posVel = DioramaVec(vx, vy, vz);
    }
    final DioramaVec camPos = DioramaVec(
      _pos.x + _flightPerp.x * arcMag,
      _pos.y + _flightPerp.y * arcMag + arcMag * 0.5,
      _pos.z + _flightPerp.z * arcMag,
    );

    // 视线：读头旁边按构图偏移（三分法），飞行时横扫。
    final double lookOff = animate ? placement.lookR * settle : 0;
    final DioramaVec lookTarget = base + r * lookOff + _flightPerp * sweepMag;
    if (snapped ||
        (!flying && lookTarget.distanceTo(_look) > dioramaSnapDistance)) {
      _look = lookTarget;
      _lookVel = DioramaVec.zero;
    } else {
      final (double lx, double vx) = dioramaSmoothDamp(
        _look.x,
        lookTarget.x,
        _lookVel.x,
        followSmooth,
        delta,
      );
      final (double ly, double vy) = dioramaSmoothDamp(
        _look.y,
        lookTarget.y,
        _lookVel.y,
        followSmooth,
        delta,
      );
      final (double lz, double vz) = dioramaSmoothDamp(
        _look.z,
        lookTarget.z,
        _lookVel.z,
        followSmooth,
        delta,
      );
      _look = DioramaVec(lx, ly, lz);
      _lookVel = DioramaVec(vx, vy, vz);
    }
    final DioramaQuat lookQuat = DioramaQuat.lookAt(
      camPos,
      _look,
      DioramaVec.worldUp,
    );

    // 读字回正：朝文字平面的朝向靠，权重 = 读字需要 × 运镜上限；目标本身也平滑追，换句时的
    // 重新回正是一段镜头运动，不是一刀切。
    final DioramaQuat alignTarget = dioramaFrameQuaternion(
      frame,
      roll: placement.roll,
      yaw: placement.yaw,
    );
    if (snapped || !_alignInit) {
      _alignQuat = alignTarget;
      _alignInit = true;
    } else {
      _alignQuat = _alignQuat.slerp(
        alignTarget,
        1 - math.exp(-_alignTurnRate * delta),
      );
    }
    double readTarget = 0;
    if (line != null) {
      final double rampIn = dioramaSmoothstep01(
        (now - (line.start - _alignLeadIn)) / (_alignLeadIn + _alignSettle),
      );
      final double rampOut =
          1 - dioramaSmoothstep01((now - line.end) / _alignRelease);
      readTarget = math.min(rampIn, rampOut) * _alignCeiling(shotKind);
    }
    if (!animate) {
      _align = readTarget;
    } else {
      _align += (readTarget - _align) * (1 - math.exp(-_alignRate * delta));
    }
    DioramaQuat target = lookQuat.slerp(_alignQuat, _align);

    // 保证读头不出画：回正把它转得太偏时往纯瞄准拉回一些。
    final DioramaVec viewDir = (_look - camPos).normalized;
    final DioramaVec camForward = target.rotate(const DioramaVec(0, 0, -1));
    final double offAxis = camForward.angleTo(viewDir);
    const double halfV = dioramaFovDeg * math.pi / 360;
    final double halfH = math.atan(math.tan(halfV) * aspect);
    final double maxOff = math.min(halfV, halfH) * _frameKeepFraction;
    if (offAxis > maxOff) {
      target = target.slerp(lookQuat, 1 - maxOff / offAxis);
    }

    if (snapped || !_orientInit) {
      _orient = target;
      _orientInit = true;
    } else {
      _orient = _orient
          .slerp(target, 1 - math.exp(-_orientFollowRate * delta))
          .normalized;
    }
    DioramaQuat finalQuat = _orient;
    if (bank != 0) {
      finalQuat =
          finalQuat * DioramaQuat.axisAngle(const DioramaVec(0, 0, 1), bank);
    }
    return DioramaCamera(
      position: camPos,
      orientation: finalQuat,
      width: width,
      height: height,
    );
  }
}
