/// 逐字动画（移植 folia `hanabi/text/animations.ts`）：17 种入场、9 种被唱到的强调、7 种退场，
/// 都是 (进度, 上下文) → 姿态的纯函数；位移以字号为单位。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

class GlyphPose {
  double dx = 0;
  double dy = 0;
  double scaleX = 1;
  double scaleY = 1;
  double rotation = 0;
  double alpha = 1;
  double skew = 0;

  /// ≥ 0 时显示乱码字（下标）。
  int scramble = -1;
  double rgbSplit = 0;
  double blur = 0;
  double split = 0;
  bool backside = false;
  double reveal = 1;

  void reset() {
    dx = 0;
    dy = 0;
    scaleX = 1;
    scaleY = 1;
    rotation = 0;
    alpha = 1;
    skew = 0;
    scramble = -1;
    rgbSplit = 0;
    blur = 0;
    split = 0;
    backside = false;
    reveal = 1;
  }

  void copyFrom(GlyphPose o) {
    dx = o.dx;
    dy = o.dy;
    scaleX = o.scaleX;
    scaleY = o.scaleY;
    rotation = o.rotation;
    alpha = o.alpha;
    skew = o.skew;
    scramble = o.scramble;
    rgbSplit = o.rgbSplit;
    blur = o.blur;
    split = o.split;
    backside = o.backside;
    reveal = o.reveal;
  }
}

class SingPose {
  double dx = 0;
  double dy = 0;
  double scale = 1;
  double scaleX = 1;
  double scaleY = 1;
  double rotation = 0;
  double flash = 0;
  double glow = 0;
  double color = 0;

  void reset() {
    dx = 0;
    dy = 0;
    scale = 1;
    scaleX = 1;
    scaleY = 1;
    rotation = 0;
    flash = 0;
    glow = 0;
    color = 0;
  }
}

class FxContext {
  FxContext({
    required this.rand,
    required this.toCenterX,
    required this.toCenterY,
    required this.dirX,
    required this.dirY,
    required this.motion,
    this.slideDistance = 7,
  });
  final List<double> rand;
  final double toCenterX;
  final double toCenterY;
  final double dirX;
  final double dirY;
  double time = 0;
  final double motion;
  final double slideDistance;
}

const Map<EnterFx, double> kEnterDuration = <EnterFx, double>{
  EnterFx.pop: 0.45,
  EnterFx.drop: 0.62,
  EnterFx.rise: 0.6,
  EnterFx.spin: 0.62,
  EnterFx.wipe: 0.42,
  EnterFx.type: 0.12,
  EnterFx.scramble: 0.75,
  EnterFx.stretch: 0.55,
  EnterFx.elastic: 0.85,
  EnterFx.split: 0.5,
  EnterFx.spiral: 0.85,
  EnterFx.flip: 0.55,
  EnterFx.glitch: 0.6,
  EnterFx.stamp: 0.5,
  EnterFx.wave: 0.75,
  EnterFx.zoom: 0.6,
  EnterFx.burst: 0.75,
};

/// 入场里「落定」的位置（色块在这一刻跟着出现）。
const Map<EnterFx, double> kEnterArrival = <EnterFx, double>{
  EnterFx.pop: 0,
  EnterFx.drop: 0.4,
  EnterFx.rise: 0.3,
  EnterFx.spin: 0.2,
  EnterFx.wipe: 0,
  EnterFx.type: 0,
  EnterFx.scramble: 0,
  EnterFx.stretch: 0.1,
  EnterFx.elastic: 0.1,
  EnterFx.split: 0.3,
  EnterFx.spiral: 0.45,
  EnterFx.flip: 0.15,
  EnterFx.glitch: 0,
  EnterFx.stamp: 0.35,
  EnterFx.wave: 0.3,
  EnterFx.zoom: 0.25,
  EnterFx.burst: 0.3,
};

const double kStampImpact = 0.5;

// 动画里的 easeOutBack 不钳输入（进度本来就在 0..1）。
double _outBack(double t, [double s = 1.70158]) =>
    1 + (s + 1) * math.pow(t - 1, 3) + s * math.pow(t - 1, 2);
double _inBack(double t, [double s = 1.70158]) =>
    (s + 1) * t * t * t - s * t * t;
double _outCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();
double _outExpo(double t) => t >= 1 ? 1 : 1 - math.pow(2, -10 * t).toDouble();
double _dampedCos(double q, double freq, double decay) =>
    math.exp(-decay * q) * math.cos(freq * q) * (1 - q);
double _dampedSin(double q, double freq, double decay) =>
    math.exp(-decay * q) * math.sin(freq * q) * (1 - q);

void _applyMotion(GlyphPose pose, double motion) {
  if (motion == 1) return;
  pose.dx *= motion;
  pose.dy *= motion;
  pose.rotation *= motion;
  pose.skew *= motion;
  pose.rgbSplit *= motion;
  pose.scaleX = 1 + (pose.scaleX - 1) * motion;
  pose.scaleY = 1 + (pose.scaleY - 1) * motion;
}

void _scaled(GlyphPose pose, double s) {
  pose.scaleX = s;
  pose.scaleY = s;
}

void enterPose(EnterFx fx, double p, FxContext ctx, GlyphPose pose) {
  pose.reset();
  if (p >= 1) return;
  final double q = clamp01(p);
  final double r0 = ctx.rand[0];
  final double r1 = ctx.rand[1];
  final double r2 = ctx.rand[2];
  switch (fx) {
    case EnterFx.pop:
      final double s = _outBack(q, 2.4);
      pose.scaleY = s * (1 + 0.14 * _dampedSin(q, 14, 3));
      pose.scaleX = s * (1 - 0.1 * _dampedSin(q, 14, 3));
      pose.rotation = (r0 - 0.5) * 0.7 * (1 - _outCubic(q));
      pose.dy = 0.25 * (1 - _outCubic(q));
      pose.alpha = clamp01(q * 6);
    case EnterFx.drop:
      if (q < 0.48) {
        final double f = q / 0.48;
        pose.dy = -2.4 * (1 - f * f);
        pose.scaleY = 1 + 0.3 * f;
        pose.scaleX = 1 - 0.12 * f;
      } else {
        final double f = (q - 0.48) / 0.52;
        pose.dy =
            -0.32 *
            math.sin(f * math.pi * 2).abs() *
            math.exp(-3 * f) *
            (1 - f);
        pose.scaleY = 1 - 0.3 * _dampedCos(f, 16, 4);
        pose.scaleX = 1 + 0.22 * _dampedCos(f, 16, 4);
      }
      pose.alpha = clamp01(q * 7);
    case EnterFx.rise:
      final double f = clamp01(q / 0.58);
      final double e = _outCubic(f);
      pose.dy = 1.7 * (1 - e);
      if (q < 0.58) {
        pose.scaleY = 1 + 0.55 * (1 - e);
        pose.scaleX = 1 - 0.28 * (1 - e);
      } else {
        final double g = (q - 0.58) / 0.42;
        pose.scaleY = 1 - 0.2 * _dampedSin(g, 11, 2.5);
        pose.scaleX = 1 + 0.16 * _dampedSin(g, 11, 2.5);
        pose.dy += 0.08 * _dampedSin(g, 11, 2.5);
      }
      pose.alpha = clamp01(q * 4);
    case EnterFx.spin:
      final double e = _outBack(q, 1.9);
      pose.rotation = -2.6 * (1 - e) * (r0 < 0.5 ? 1 : -1);
      _scaled(pose, 0.15 + 0.85 * e);
      pose.dx = -0.7 * (1 - _outCubic(q)) * ctx.dirX;
      pose.dy =
          -0.7 * (1 - _outCubic(q)) * ctx.dirY -
          0.3 * math.sin(math.pi * q) * (1 - q);
      pose.alpha = clamp01(q * 4);
    case EnterFx.wipe:
      final double e = _outCubic(q);
      pose.reveal = _outCubic(clamp01(q / 0.8));
      pose.dx = -0.35 * (1 - e) * ctx.dirX;
      pose.dy = -0.35 * (1 - e) * ctx.dirY;
      pose.skew = -0.3 * (1 - e);
      pose.alpha = clamp01(q * 8);
    case EnterFx.type:
      pose.alpha = q > 0 ? 1 : 0;
      _scaled(pose, 1 + 0.3 * math.pow(1 - clamp01(q / 0.6), 2));
    case EnterFx.scramble:
      pose.alpha = clamp01(q * 8);
      if (q < 0.72) {
        final int frame = (ctx.time * 22).floor();
        pose.scramble = (intHash01(frame, (r0 * 1e6).floor()) * 1e6).floor();
        pose.dy = (intHash01(frame + 7, (r1 * 1e6).floor()) - 0.5) * 0.12;
        pose.alpha *= 0.75 + 0.25 * intHash01(frame + 13, 1);
      } else {
        _scaled(pose, 1 + 0.16 * math.pow(1 - (q - 0.72) / 0.28, 2));
      }
    case EnterFx.stretch:
      final double k = math.pow(1 - q, 3).toDouble();
      pose.scaleX = 1 + 2 * k - 0.16 * _dampedSin(q, 13, 3);
      pose.scaleY = 1 - 0.72 * k + 0.12 * _dampedSin(q, 13, 3);
      pose.dx = -1.4 * k * ctx.dirX;
      pose.dy = -1.4 * k * ctx.dirY;
      pose.alpha = clamp01(q * 5);
    case EnterFx.elastic:
      final double angle = r0 * math.pi * 2;
      final double spring =
          math.exp(-4.2 * q) * math.cos(q * math.pi * 4.5) * (1 - q);
      pose.dx = math.cos(angle) * 1.6 * spring;
      pose.dy = math.sin(angle) * 1.6 * spring;
      pose.rotation = (r1 - 0.5) * 0.8 * spring;
      pose.scaleX = 1 + 0.18 * spring.abs();
      pose.scaleY = 1 - 0.12 * spring.abs();
      pose.alpha = clamp01(q * 5);
    case EnterFx.split:
      pose.split = 1 - _outExpo(clamp01(q / 0.8));
      if (q > 0.8) {
        final double g = (q - 0.8) / 0.2;
        pose.scaleX = 1 + 0.1 * _dampedSin(g, 10, 2);
        pose.scaleY = 1 - 0.08 * _dampedSin(g, 10, 2);
      }
      pose.alpha = clamp01(q * 5);
    case EnterFx.spiral:
      final double e = _outCubic(q);
      final double radius = 3.4 * (1 - e);
      final double angle = r0 * math.pi * 2 + math.pi * 2.5 * (1 - e);
      pose.dx = math.cos(angle) * radius;
      pose.dy = math.sin(angle) * radius * 0.8;
      pose.rotation = -math.pi * 2 * (1 - e) * (r1 < 0.5 ? 1 : -1);
      _scaled(pose, 0.25 + 0.75 * _outBack(q, 1.5));
      pose.alpha = clamp01(q * 3);
    case EnterFx.flip:
      final double phi = math.pi * 2.5 * (1 - _outCubic(q));
      pose.scaleX = math.cos(phi);
      pose.backside = pose.scaleX < 0;
      pose.scaleY = 1 + 0.08 * math.sin(phi);
      pose.dy = -0.3 * math.sin(math.pi * q) * (1 - q);
      pose.alpha = clamp01(q * 6);
    case EnterFx.glitch:
      if (q < 0.8) {
        final int frame = (ctx.time * 24).floor();
        final int seed = (r0 * 1e6).floor();
        final double intensity = 1 - q / 0.8;
        final double h1 = intHash01(frame, seed);
        final double h2 = intHash01(frame, seed + 1);
        final double h3 = intHash01(frame, seed + 2);
        final double h4 = intHash01(frame, seed + 3);
        pose.dx = h2 > 0.35 ? (h1 - 0.5) * 0.9 * intensity : 0;
        pose.rgbSplit = (0.05 + 0.13 * h3) * intensity;
        pose.skew = h4 > 0.7 ? (h1 - 0.5) * 0.9 * intensity : 0;
        pose.scaleX = h2 > 0.82 ? 1 + 0.4 * intensity : 1;
        pose.alpha =
            clamp01(q * 10) * (intHash01(frame, seed + 4) > 0.18 ? 1 : 0.25);
      }
    case EnterFx.stamp:
      if (q < kStampImpact) {
        final double f = q / kStampImpact;
        _scaled(pose, 2.6 - 1.6 * f * f);
        pose.rotation = (r0 - 0.5) * 0.35 * (1 - f);
        pose.alpha = clamp01(f * 2.2);
      } else {
        final double f = (q - kStampImpact) / (1 - kStampImpact);
        pose.scaleX = 1 + 0.22 * _dampedCos(f, 17, 4);
        pose.scaleY = 1 - 0.22 * _dampedCos(f, 17, 4);
      }
    case EnterFx.wave:
      final double k = math.pow(1 - q, 1.5).toDouble();
      pose.dy = 1.1 * k * math.cos(q * math.pi * 3);
      pose.rotation = 0.4 * k * math.sin(q * math.pi * 3);
      pose.scaleY = 1 + 0.18 * k * math.sin(q * math.pi * 3 + 0.6);
      pose.alpha = clamp01(q * 4);
    case EnterFx.zoom:
      final double e = _outExpo(q);
      final double k = 1.8 * (1 - e);
      _scaled(pose, 1 + k * 1.5);
      pose.dx = -ctx.toCenterX * k;
      pose.dy = -ctx.toCenterY * k;
      pose.blur = math.pow(1 - q, 1.4).toDouble();
      pose.alpha = clamp01(q * 3.5);
    case EnterFx.burst:
      final double e = _outBack(q, 1.8);
      pose.dx = ctx.toCenterX * (1 - e);
      pose.dy = ctx.toCenterY * (1 - e);
      _scaled(pose, 0.2 + 0.8 * _outBack(clamp01(q * 1.3), 1.6));
      pose.rotation = (r2 - 0.5) * 4 * (1 - _outCubic(q));
      pose.alpha = clamp01(q * 6);
  }
  _applyMotion(pose, ctx.motion);
}

void exitPose(ExitFx fx, double p, FxContext ctx, GlyphPose pose) {
  pose.reset();
  if (p <= 0) return;
  final double q = clamp01(p);
  final double r0 = ctx.rand[0];
  final double r1 = ctx.rand[1];
  final double r2 = ctx.rand[2];
  switch (fx) {
    case ExitFx.ascend:
      final double e = q * q * q;
      final double dip = q < 0.22 ? math.sin((q / 0.22) * math.pi) * 0.12 : 0;
      pose.dy = dip - 2.8 * e;
      pose.dx = (r0 - 0.5) * 0.7 * e;
      pose.rotation = (r1 - 0.5) * 0.5 * e;
      pose.scaleY = 1 + 0.45 * e;
      pose.scaleX = 1 - 0.22 * e;
      pose.alpha = 1 - q * q;
    case ExitFx.scatter:
      double ox = -ctx.toCenterX + (r0 - 0.5) * 2;
      double oy = -ctx.toCenterY + (r1 - 0.5) * 2;
      final double len = math.sqrt(ox * ox + oy * oy);
      final double l = len == 0 ? 1 : len;
      ox /= l;
      oy /= l;
      final double e = _outCubic(q);
      final double dist = 2.4 + r2 * 1.8;
      pose.dx = ox * dist * e;
      pose.dy = oy * dist * e;
      pose.rotation = (r1 - 0.5) * 3.2 * e;
      _scaled(pose, 1 - 0.65 * e);
      pose.alpha = 1 - math.pow(q, 1.6).toDouble();
    case ExitFx.shrink:
      final double s = q < 0.2
          ? 1 + 0.16 * math.sin((q / 0.2) * math.pi / 2)
          : 1.16 * (1 - _inBack((q - 0.2) / 0.8, 1.4));
      _scaled(pose, math.max(0, s));
      pose.rotation = (r0 - 0.5) * 0.9 * q;
      pose.alpha = q > 0.8 ? (1 - q) / 0.2 : 1;
    case ExitFx.slide:
      final double e = _inBack(q, 1.6);
      final double dist = ctx.slideDistance;
      pose.dx = ctx.dirX * dist * e;
      pose.dy = ctx.dirY * dist * e;
      pose.scaleX = 1 + 0.45 * q * q * ctx.dirX.abs();
      pose.scaleY = 1 + 0.45 * q * q * ctx.dirY.abs();
      pose.skew = -0.45 * q * q * (ctx.dirX == 0 ? 1 : ctx.dirX.sign);
      pose.alpha = 1 - math.pow(clamp01((q - 0.45) / 0.55), 1.5).toDouble();
    case ExitFx.dissolve:
      final int frame = (ctx.time * 20).floor();
      final double flicker = intHash01(frame, (r0 * 1e6).floor());
      pose.alpha = math.pow(1 - q, 1.3) * (1 - 0.45 * q * flicker);
      _scaled(pose, 1 + 0.14 * easeOutQuad(q));
      pose.dy = -0.35 * easeOutQuad(q);
      pose.blur = q;
    case ExitFx.fall:
      final double e = q * q;
      pose.dy = 3 * e;
      pose.dx = 0.28 * math.sin(q * math.pi * 2 + r0 * 6) * q;
      pose.rotation = (r1 - 0.5) * 1.2 * e;
      pose.scaleY = 1 + 0.4 * e;
      pose.scaleX = 1 - 0.25 * e;
      pose.alpha = 1 - math.pow(q, 1.6).toDouble();
    case ExitFx.blink:
      final bool on =
          q < 0.14 ||
          (q >= 0.24 && q < 0.4) ||
          (q >= 0.5 && q < 0.6) ||
          (q >= 0.7 && q < 0.76) ||
          (q >= 0.82 && q < 0.85);
      pose.alpha = on && q < 1 ? 1 : 0;
      _scaled(pose, 1 + (on ? 0.05 * q : 0));
  }
  if (q >= 1) pose.alpha = 0;
  _applyMotion(pose, ctx.motion);
}

void singPose(
  SingFx fx,
  double u,
  double duration,
  double rand,
  double motion,
  SingPose pose,
) {
  pose.reset();
  if (u < 0 || fx == SingFx.none) return;
  final double hold = math.max(duration, 0.12);
  final double envelope = clamp01(u / 0.08) * (1 - clamp01((u - hold) / 0.35));
  switch (fx) {
    case SingFx.none:
      break;
    case SingFx.bounce:
      const double tt = 0.3;
      if (u < tt) {
        pose.dy = -0.26 * math.sin((u / tt) * math.pi);
      } else if (u < tt + 0.16) {
        pose.dy = -0.06 * math.sin(((u - tt) / 0.16) * math.pi);
      }
      final double land = u - tt;
      if (land >= 0 && land < 0.3) {
        final double f = land / 0.3;
        pose.scaleY = 1 - 0.14 * _dampedCos(f, 14, 3);
        pose.scaleX = 1 + 0.1 * _dampedCos(f, 14, 3);
      } else if (u < tt) {
        pose.scaleY = 1 + 0.08 * math.sin((u / tt) * math.pi);
      }
    case SingFx.flash:
      pose.flash = math.exp(-u / 0.16);
      pose.scale = 1 + 0.2 * math.exp(-u / 0.1) * clamp01(u / 0.03);
    case SingFx.swell:
      pose.scale =
          1 +
          0.24 *
              _outBack(clamp01(u / 0.18), 2) *
              (1 - clamp01((u - hold) / 0.35));
    case SingFx.shake:
      final double decay = math.exp(-math.max(0, u - hold) / 0.08);
      final double k = clamp01(u / 0.04) * decay * (u < hold + 0.4 ? 1 : 0);
      pose.dx = 0.06 * math.sin(u * 61 + rand * 9) * k;
      pose.dy = 0.04 * math.sin(u * 47 + rand * 5) * k;
      pose.rotation = 0.08 * math.sin(u * 53 + rand * 7) * k;
    case SingFx.jump:
      const double tt = 0.42;
      if (u < tt) {
        final double f = u / tt;
        pose.dy = -0.5 * math.sin(f * math.pi);
        pose.rotation =
            (rand < 0.5 ? 1 : -1) * 0.22 * math.sin(f * math.pi * 2) * (1 - f);
        pose.scaleY = 1 + 0.2 * math.sin(f * math.pi) * (1 - f);
        pose.scaleX = 1 - 0.12 * math.sin(f * math.pi) * (1 - f);
      } else if (u < tt + 0.35) {
        final double f = (u - tt) / 0.35;
        pose.scaleY = 1 - 0.2 * _dampedCos(f, 13, 3);
        pose.scaleX = 1 + 0.16 * _dampedCos(f, 13, 3);
      }
    case SingFx.glow:
      pose.glow = envelope;
      pose.flash = 0.35 * envelope;
      pose.scale = 1 + 0.07 * envelope;
    case SingFx.underline:
      pose.dy = -0.05 * envelope;
    case SingFx.color:
      pose.color = clamp01(u / 0.1);
      pose.scale = 1 + 0.14 * math.exp(-u / 0.12) * clamp01(u / 0.03);
  }
  if (motion != 1) {
    pose.dx *= motion;
    pose.dy *= motion;
    pose.rotation *= motion;
    pose.scale = 1 + (pose.scale - 1) * motion;
    pose.scaleX = 1 + (pose.scaleX - 1) * motion;
    pose.scaleY = 1 + (pose.scaleY - 1) * motion;
  }
}

void combinePoses(GlyphPose a, GlyphPose b, GlyphPose out) {
  out.dx = a.dx + b.dx;
  out.dy = a.dy + b.dy;
  out.scaleX = a.scaleX * b.scaleX;
  out.scaleY = a.scaleY * b.scaleY;
  out.rotation = a.rotation + b.rotation;
  out.alpha = a.alpha * b.alpha;
  out.skew = a.skew + b.skew;
  out.scramble = a.scramble >= 0 ? a.scramble : b.scramble;
  out.rgbSplit = a.rgbSplit + b.rgbSplit;
  out.blur = math.max(a.blur, b.blur);
  out.split = math.max(a.split, b.split);
  out.backside = a.backside || b.backside;
  out.reveal = math.min(a.reveal, b.reveal);
}

/// 入场顺序：乱码 / 故障打乱，放大 / 炸开从中间往两边，其余按字序。
List<double> enterOrder(EnterFx fx, int count, HanabiRng rand) {
  final List<int> order = <int>[for (int i = 0; i < count; i++) i];
  if (fx == EnterFx.scramble || fx == EnterFx.glitch) {
    for (int i = count - 1; i > 0; i--) {
      final int j = (rand() * (i + 1)).floor();
      final int tmp = order[i];
      order[i] = order[j];
      order[j] = tmp;
    }
    final List<double> rank = List<double>.filled(count, 0);
    for (int k = 0; k < count; k++) {
      rank[order[k]] = k.toDouble();
    }
    return rank;
  }
  if (fx == EnterFx.zoom || fx == EnterFx.burst) {
    final double mid = (count - 1) / 2;
    return <double>[
      for (final int i in order) ((i - mid).abs() * 2).round() / 2,
    ];
  }
  return <double>[for (final int i in order) i.toDouble()];
}

const Map<EnterFx, double> _staggerFactor = <EnterFx, double>{
  EnterFx.burst: 0.35,
  EnterFx.zoom: 0.6,
  EnterFx.stamp: 1.35,
  EnterFx.type: 1,
};

class EnterSchedule {
  const EnterSchedule(this.start, this.duration, this.landed);
  final List<double> start;
  final double duration;
  final List<double> landed;
}

/// 逐字入场的时刻：最后一个字入场完成不晚于 deadline（第一个字被唱到），放不下时压缩间隔再压缩时长。
EnterSchedule scheduleEnter(
  EnterFx fx,
  List<double> ranks,
  double enterAt,
  double stagger,
  double deadline,
) {
  final double maxRank = ranks.fold(0.0, math.max);
  double step = math.max(0, stagger) * (_staggerFactor[fx] ?? 1);
  double duration = kEnterDuration[fx]!;
  final double available = deadline - enterAt;
  if (step * maxRank + duration > available) {
    step = maxRank > 0
        ? math.max(0, math.min(step, (available - duration) / maxRank))
        : 0;
    if (step * maxRank + duration > available) {
      final double ratio = math.max(0, available) / (step * maxRank + duration);
      step *= ratio;
      duration = math.max(0.1, duration * ratio);
      if (step * maxRank + duration > available) {
        step = maxRank > 0 ? math.max(0, (available - duration) / maxRank) : 0;
      }
    }
  }
  final List<double> start = <double>[
    for (final double r in ranks) r < 0 ? double.nan : enterAt + r * step,
  ];
  return EnterSchedule(start, duration, <double>[
    for (final double s in start) s + duration,
  ]);
}

class ExitSchedule {
  const ExitSchedule(this.start, this.end);
  final List<double> start;
  final List<double> end;
}

ExitSchedule scheduleExit(
  List<double> ranks,
  double exitAt,
  double exitDuration,
) {
  final double maxRank = ranks.fold(0.0, math.max);
  final double total = math.max(0.001, exitDuration);
  final double step = maxRank > 0 ? math.min(0.05, (total * 0.4) / maxRank) : 0;
  final double each = total - step * maxRank;
  final List<double> start = <double>[
    for (final double r in ranks) r < 0 ? double.nan : exitAt + r * step,
  ];
  return ExitSchedule(start, <double>[for (final double s in start) s + each]);
}

/// 盖章入场的画面震动（像素）。
(double, double) stampShake(
  double time,
  List<double> impacts,
  double amplitude,
) {
  double x = 0;
  double y = 0;
  for (int i = 0; i < impacts.length; i++) {
    final double tau = time - impacts[i];
    if (tau < 0 || tau > 0.45) continue;
    final double k = amplitude * math.exp(-tau / 0.085);
    x += k * math.sin(tau * 96 + i * 1.7);
    y += k * 0.8 * math.sin(tau * 77 + i * 2.3 + 1);
  }
  return (x, y);
}
