/// 一个场景单元的时间安排（移植 folia `hanabi/timeline.ts`）：每个镜头的文字入场 / 退场、升空尾迹、
/// 世界上升 rise(t)、世界旋转 spin(t) 与镜头内运镜。全部只由 t 决定。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

class TimelineShot {
  const TimelineShot({
    required this.startTime,
    required this.endTime,
    required this.firstSung,
    required this.lastSungEnd,
    required this.isBridge,
    required this.camera,
  });
  final double startTime;
  final double endTime;
  final double? firstSung;
  final double? lastSungEnd;
  final bool isBridge;
  final HanabiCamera camera;
}

class ShotTiming {
  ShotTiming({
    required this.start,
    required this.end,
    required this.worldY,
    required this.launchAt,
    required this.enterAt,
    required this.punchAt,
    required this.riseFrom,
    required this.riseTo,
    required this.drift,
    required this.spin,
    required this.spinDrift,
  });
  final double start;
  final double end;

  /// 镜头容器在世界里的高度偏移（像素，向上为负）。
  final double worldY;
  final double launchAt;
  final double enterAt;
  double exitAt = 0;
  double exitDuration = 0;
  final double punchAt;

  /// 进入这个镜头的上升窗口（第一个镜头为 null）。
  final double? riseFrom;
  final double? riseTo;
  final double drift;
  final double spin;
  final double spinDrift;
}

class CameraOffset {
  const CameraOffset(this.scale, this.rotation, this.dx, this.dy);
  final double scale;
  final double rotation;
  final double dx;
  final double dy;
}

const double kRiseBefore = 0.6;
const double kRiseAfter = 0.6;
const double kLaunchDuration = 0.45;
const double kEnterLead = 0.4;
const double _driftPerSecond = 0.03;
const double _driftMax = 0.15;
const double _punchAttack = 0.05;
const double _spinCruise = 0.2;
const double _spinCruiseTotal = 0.85;
const double _spinSwingMin = 0.6;
const double _spinSwingRange = 0.8;
const double _spinFlip = 0.2;

class SpinPlan {
  const SpinPlan(this.angles, this.drift);
  final List<double> angles;
  final List<double> drift;
}

/// 一个单元的世界旋转安排：每个镜头中点的角度与镜头内慢转的角速度。
SpinPlan planSpin(
  List<double> durations, {
  required double amount,
  required int direction,
  required HanabiRng random,
}) {
  final List<double> angles = <double>[];
  final List<double> drift = <double>[];
  int dir = direction;
  for (int index = 0; index < durations.length; index++) {
    final double duration = durations[index];
    if (index > 0) {
      final bool last = index == durations.length - 1;
      final double roll = random();
      final bool reversed = dir != direction;
      if (reversed ? (last || roll < 0.5) : (!last && roll < _spinFlip)) {
        dir = -dir;
      }
    }
    final double cruise =
        dir *
        amount *
        math.min(_spinCruise, _spinCruiseTotal / math.max(duration, 0.5));
    drift.add(cruise);
    if (index == 0) {
      angles.add(0);
      continue;
    }
    final double swing =
        dir * amount * (_spinSwingMin + _spinSwingRange * random());
    angles.add(
      angles[index - 1] +
          (drift[index - 1] * durations[index - 1] + cruise * duration) / 2 +
          swing,
    );
  }
  return SpinPlan(angles, drift);
}

class HanabiTimeline {
  HanabiTimeline._(
    this.shots,
    this._spinSteps,
    this._mids,
    this._source,
    this._motion,
  );

  final List<ShotTiming> shots;
  final List<double Function(double)?> _spinSteps;
  final List<double> _mids;
  final List<TimelineShot> _source;
  final double _motion;

  int shotAt(double time) {
    int found = 0;
    for (int i = 0; i < shots.length; i++) {
      if (shots[i].start <= time) found = i;
    }
    return found;
  }

  double _blended(double time, double Function(int index, double time) value) {
    for (int index = 1; index < shots.length; index++) {
      final double from = shots[index].riseFrom!;
      final double to = shots[index].riseTo!;
      if (time >= from && time <= to) {
        final double k = easeSwing((time - from) / math.max(to - from, 1e-3));
        final double a = value(index - 1, time);
        return a + (value(index, time) - a) * k;
      }
    }
    return value(shotAt(time), time);
  }

  double _target(int index, double time) {
    final ShotTiming t = shots[index];
    return -t.worldY + t.drift * (time - (t.start + t.end) / 2);
  }

  /// 世界容器的 y（像素）。
  double rise(double time) => shots.isEmpty ? 0 : _blended(time, _target);

  /// 世界绕画面中心转过的角度（弧度）。
  double spin(double time) {
    if (shots.isEmpty) return 0;
    if (time <= _mids[0]) {
      return shots[0].spin + shots[0].spinDrift * (time - _mids[0]);
    }
    for (int index = 1; index < shots.length; index++) {
      if (time < _mids[index]) return _spinSteps[index]!(time);
    }
    final ShotTiming last = shots.last;
    return last.spin + last.spinDrift * (time - _mids.last);
  }

  double _pushOf(int index, double time) {
    final ShotTiming t = shots[index];
    return 1 +
        _source[index].camera.push *
            smoothstep01((time - t.start) / math.max(t.end - t.start, 0.05));
  }

  double _rollOf(int index, double time) {
    final ShotTiming t = shots[index];
    return _source[index].camera.roll *
        _motion *
        math.sin((time - t.start) * 0.9 + index * 1.3);
  }

  /// 镜头内的推近、摆动与入场震动（绕画面中心），dx / dy 是像素。
  CameraOffset camera(double time, double height) {
    if (shots.isEmpty) return const CameraOffset(1, 0, 0, 0);
    double scale = _blended(time, _pushOf);
    final double rotation = _blended(time, _rollOf);
    double dx = 0;
    double dy = 0;
    for (int index = 0; index < shots.length; index++) {
      final double age = time - shots[index].punchAt;
      final double punch = _source[index].camera.punch;
      if (age < 0 || age > 0.9 || punch <= 0 || _source[index].isBridge) {
        continue;
      }
      final double amp =
          punch *
          _motion *
          math.exp(-age / 0.16) *
          smoothstep01(age / _punchAttack);
      dx += amp * 0.012 * height * math.sin(age * 70 + index);
      dy += amp * 0.016 * height * math.cos(age * 55 + index * 2);
      scale *= 1 + amp * 0.03;
    }
    return CameraOffset(scale, rotation, dx, dy);
  }
}

HanabiTimeline buildTimeline(
  List<TimelineShot> shots, {
  required double unitEnd,
  required double height,
  required double riseSpeed,
  required double motion,
  double? exitStart,
  List<double>? spinAngles,
  List<double>? spinDrift,
}) {
  final int count = shots.length;
  double durationOf(int i) =>
      math.max(shots[i].endTime - shots[i].startTime, 0.05);
  final List<double> before = <double>[
    for (int i = 0; i < count; i++)
      i == 0 ? 0 : math.min(kRiseBefore, 0.45 * durationOf(i - 1)),
  ];
  final List<double> after = <double>[
    for (int i = 0; i < count; i++)
      i == 0 ? 0 : math.min(kRiseAfter, 0.35 * durationOf(i)),
  ];
  final List<ShotTiming> timings = <ShotTiming>[];
  double worldY = 0;
  for (int index = 0; index < count; index++) {
    final TimelineShot shot = shots[index];
    if (index > 0) {
      worldY -= clampD(shot.camera.rise, 0, 1.2) * riseSpeed * height;
    }
    final double boundary = shot.startTime;
    final double sung = shot.firstSung ?? boundary;
    double enterAt = shot.isBridge
        ? boundary
        : math.min(boundary, sung) - kEnterLead;
    if (index > 0) {
      enterAt = math.max(
        enterAt,
        math.max(boundary - before[index], timings[index - 1].enterAt + 0.1),
      );
    }
    final double duration = durationOf(index);
    timings.add(
      ShotTiming(
        start: shot.startTime,
        end: shot.endTime,
        worldY: worldY,
        launchAt: enterAt - kLaunchDuration,
        enterAt: enterAt,
        punchAt: enterAt + 0.08,
        riseFrom: index == 0 ? null : boundary - before[index],
        riseTo: index == 0 ? null : boundary + after[index],
        drift:
            riseSpeed *
            height *
            math.min(_driftPerSecond, _driftMax / duration),
        spin: spinAngles != null && index < spinAngles.length
            ? spinAngles[index]
            : 0,
        spinDrift: spinDrift != null && index < spinDrift.length
            ? spinDrift[index]
            : 0,
      ),
    );
  }
  for (int index = 0; index < count; index++) {
    final ShotTiming timing = timings[index];
    final TimelineShot shot = shots[index];
    final double sungEnd = shot.lastSungEnd ?? timing.end;
    double exitAt;
    double exitDuration;
    if (index < count - 1) {
      final double boundary = timing.end;
      exitAt = clampD(sungEnd, boundary - before[index + 1], boundary - 0.15);
      exitDuration = clampD(boundary + after[index + 1] - exitAt, 0.35, 0.9);
    } else if (exitStart != null) {
      exitAt = math.min(math.max(sungEnd, exitStart), unitEnd - 0.2);
      exitDuration = clampD(unitEnd - exitAt, 0.25, 0.7);
    } else {
      exitAt = unitEnd;
      exitDuration = 0.5;
    }
    timing.exitAt = math.max(exitAt, timing.enterAt + 0.3);
    timing.exitDuration = exitDuration;
  }
  final List<double> mids = <double>[
    for (final ShotTiming t in timings) (t.start + t.end) / 2,
  ];
  final List<double Function(double)?> steps = <double Function(double)?>[
    for (int index = 0; index < count; index++)
      if (index == 0)
        null
      else
        () {
          final ShotTiming previous = timings[index - 1];
          final ShotTiming timing = timings[index];
          final double from = timing.riseFrom!;
          final double to = timing.riseTo!;
          final double ramp = math.max(to - from, 1e-3);
          final double fromMid = mids[index - 1];
          double drift(double time) {
            final double x = (time - from) / ramp;
            final double switched = x <= 0
                ? 0
                : x >= 1
                ? ramp / 2 + (time - to)
                : ramp * easeSepticIntegral(x);
            return previous.spinDrift * (time - fromMid) +
                (timing.spinDrift - previous.spinDrift) * switched;
          }

          final double swing = timing.spin - previous.spin - drift(mids[index]);
          return (double time) =>
              previous.spin +
              drift(time) +
              swing * easeSwing((time - from) / ramp);
        }(),
  ];
  return HanabiTimeline._(timings, steps, mids, shots, motion);
}
