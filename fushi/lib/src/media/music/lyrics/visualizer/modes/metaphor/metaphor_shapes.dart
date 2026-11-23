/// 隐喻的融球和装饰图形（纯函数，移植 folia `metaphor/metaphorShapes.ts`）。都按播放时间直接算
/// 位置，不积分，拖进度、暂停都对：
/// 1. 一个 cue 一份规划：网点云、大墨团和绕着它的小墨滴、贴着字的墨滴、强调色融球、圆环，都只极慢地漂。
/// 2. 对撞：两颗墨球沿一条直线相向加速，撞上的一刻炸开一圈冲击环，碎片沿螺旋线甩出去。
/// 3. 刚唱到的字放出一对粒子：朝相反方向、各往相反的一边打转。
/// 每帧写进一段实例数据（每个 10 个数：位置 2、半轴 2、转角 1、墨 / 网点 / 强调色三路的量 3、形状 1、参数 1）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_program.dart';

const int metaphorShapeStride = 10;
const int metaphorShapeCapacity = 1024;
const int metaphorDynamicReserve = 384;
const int _planLimit = 80;

const int metaphorShapeBlob = 0;
const int metaphorShapeRing = 1;
const int metaphorShapeBar = 2;

/// 圆弧：sx 是那一格的半边长（弧画在 0.9 处），sy 是线宽的倍数，param 是半张角占 π 的多少。
const int metaphorShapeArc = 3;

/// 波浪线：sx 是半长，sy 是那一格的半高，param 是半波的个数。
const int metaphorShapeWave = 4;

const double _tau = math.pi * 2;

/// 「流体」能调到的最大倍数：摆墨团时按它留白。
const double _maxFlow = 2;

class MetaphorShape {
  const MetaphorShape({
    required this.shape,
    this.x = 0,
    this.y = 0,
    this.sx = 1,
    this.sy = 1,
    this.param = 0,
    this.born = 0,
    this.rot = 0,
    this.ink = 0,
    this.tone = 0,
    this.accent = 0,
    this.ampX = 0,
    this.ampY = 0,
    this.w1 = 0,
    this.w2 = 0,
    this.p1 = 0,
    this.p2 = 0,
    this.parent = -1,
    this.orbit = 0,
    this.orbitSpeed = 0,
    this.steady = false,
    this.pulse = 0,
  });

  final int shape;
  final double x;
  final double y;

  /// 半轴：融球和圆环是半径，细线是半长与半宽。
  final double sx;
  final double sy;
  final double param;

  /// cue 开始后多久才出现。
  final double born;
  final double rot;
  final double ink;
  final double tone;
  final double accent;
  final double ampX;
  final double ampY;
  final double w1;
  final double w2;
  final double p1;
  final double p2;

  /// 绕着 shapes 里的第几个转（小墨滴）；-1 时 orbit 大于 0 就绕着自己的位置转。
  final int parent;
  final double orbit;
  final double orbitSpeed;
  final bool steady;

  /// 跟音量鼓起多少。
  final double pulse;

  bool get isLine => shape >= metaphorShapeBar;

  MetaphorShape withParent(int p) => MetaphorShape(
    shape: shape,
    x: x,
    y: y,
    sx: sx,
    sy: sy,
    param: param,
    born: born,
    rot: rot,
    ink: ink,
    tone: tone,
    accent: accent,
    ampX: ampX,
    ampY: ampY,
    w1: w1,
    w2: w2,
    p1: p1,
    p2: p2,
    parent: p,
    orbit: orbit,
    orbitSpeed: orbitSpeed,
    steady: steady,
    pulse: pulse,
  );
}

MetaphorShape _make(
  MetaphorRng rng,
  int shape, {
  double x = 0,
  double y = 0,
  double sx = 1,
  double sy = 1,
  double ink = 0,
  double tone = 0,
  double accent = 0,
  double ampX = 0,
  double ampY = 0,
  int parent = -1,
  double orbit = 0,
  double orbitSpeed = 0,
  double pulse = 0,
}) {
  // 漂一个来回要四十秒到一百秒（随机数的取用顺序和 folia 一致）
  final double w1 = 0.06 + rng() * 0.1;
  final double w2 = 0.06 + rng() * 0.1;
  final double p1 = rng() * _tau;
  final double p2 = rng() * _tau;
  return MetaphorShape(
    shape: shape,
    x: x,
    y: y,
    sx: sx,
    sy: sy,
    ink: ink,
    tone: tone,
    accent: accent,
    ampX: ampX,
    ampY: ampY,
    w1: w1,
    w2: w2,
    p1: p1,
    p2: p2,
    parent: parent,
    orbit: orbit,
    orbitSpeed: orbitSpeed,
    pulse: pulse,
  );
}

class _Stage {
  _Stage(MetaphorRect b)
    : halfW = (b.x1 - b.x0) / 2,
      halfH = (b.y1 - b.y0) / 2 {
    reach = math.max(math.max(halfW, halfH), 2);
  }

  final double halfW;
  final double halfH;
  late final double reach;
}

/// 从中心朝随机方向走到字的包围盒外面 pad 这么远，再往外 0..far。
(double, double) _outsidePoint(
  _Stage stage,
  MetaphorRng rng,
  double pad,
  double far,
) {
  final double angle = rng() * _tau;
  final double cos = math.cos(angle);
  final double sin = math.sin(angle);
  final double edge = math.min(
    (stage.halfW + pad) / math.max(0.001, cos.abs()),
    (stage.halfH + pad) / math.max(0.001, sin.abs()),
  );
  final double radius = edge + rng() * far;
  return (cos * radius, sin * radius);
}

/// 一个 cue 的图形规划。墨团都摆在字的包围盒外面；压在字上的只有强调色融球。
List<MetaphorShape> planMetaphorShapes(
  MetaphorRect bounds,
  MetaphorRng rng,
  double amount,
  bool interlude,
) {
  final List<MetaphorShape> shapes = <MetaphorShape>[];
  final _Stage stage = _Stage(bounds);
  final double halfW = stage.halfW;
  final double halfH = stage.halfH;
  final double reach = stage.reach;
  final double scale = amount * (interlude ? 1.5 : 1);
  int count(double base) =>
      (base * scale + rng() * 0.6 * math.min(1, scale)).round();
  double span(double min, double max) => min + rng() * (max - min);
  (double, double) around(double min, double max) {
    final double angle = rng() * _tau;
    final double radius = span(min, max);
    return (
      math.cos(angle) * radius * (halfW / reach + 0.6),
      math.sin(angle) * radius * (halfH / reach + 0.6),
    );
  }

  for (int index = count(4); index > 0; index--) {
    final double radius = span(0.5, 1.4) * reach;
    final (double x, double y) = around(reach * 0.5, reach * 2.4);
    final double tone = span(0.5, 1);
    final double ampX = span(0.3, 1.2);
    final double ampY = span(0.3, 1);
    shapes.add(
      _make(
        rng,
        metaphorShapeBlob,
        x: x,
        y: y,
        sx: radius,
        sy: radius,
        tone: tone,
        ampX: ampX,
        ampY: ampY,
        pulse: 0.5,
      ),
    );
  }

  final int bigBlobs = interlude ? math.min(2, count(1.2)) : count(3);
  for (int index = bigBlobs; index > 0; index--) {
    final double radius =
        (interlude ? span(0.1, 0.24) : span(0.25, 0.7)) * reach;
    final double ampX = span(0.2, 0.9);
    final double ampY = span(0.2, 0.8);
    final (double x, double y) = interlude
        ? around(reach * 0.2, reach * 1.6)
        : _outsidePoint(
            stage,
            rng,
            radius * 1.4 + 0.2 + math.max(ampX, ampY) * _maxFlow,
            reach,
          );
    final int parent = shapes.length;
    shapes.add(
      _make(
        rng,
        metaphorShapeBlob,
        x: x,
        y: y,
        sx: radius,
        sy: radius,
        ink: 1,
        tone: 0.6,
        ampX: ampX,
        ampY: ampY,
        pulse: 1,
      ),
    );
    for (int drop = 2 + (rng() * 2).floor(); drop > 0; drop--) {
      final double small = radius * span(0.12, 0.3);
      final double orbit = radius * span(0.55, 0.85);
      final double speed = (rng() < 0.5 ? -1 : 1) * span(0.08, 0.22);
      shapes.add(
        _make(
          rng,
          metaphorShapeBlob,
          sx: small,
          sy: small,
          ink: 1,
          parent: parent,
          orbit: orbit,
          orbitSpeed: speed,
          pulse: 0.4,
        ),
      );
    }
  }

  if (!interlude) {
    for (int index = count(4); index > 0; index--) {
      final double radius = span(0.18, 0.45);
      final int side = (rng() * 4).floor();
      final double along = span(-1, 1);
      final double out = span(0.35, 0.9);
      final double ampX = span(0.1, 0.45);
      final double ampY = span(0.1, 0.45);
      shapes.add(
        _make(
          rng,
          metaphorShapeBlob,
          x: side < 2 ? along * halfW : (side == 2 ? -1 : 1) * (halfW + out),
          y: side < 2 ? (side == 0 ? -1 : 1) * (halfH + out) : along * halfH,
          sx: radius,
          sy: radius,
          ink: 1,
          ampX: ampX,
          ampY: ampY,
          pulse: 0.8,
        ),
      );
    }
  }

  for (int index = count(1.6); index > 0; index--) {
    final double radius =
        span(0.9, 1.5) *
        math.min(1.6, math.max(0.45, math.min(halfW, halfH) * 0.9));
    final double x = span(-0.9, 0.9) * halfW;
    final double y = span(-0.9, 0.9) * halfH;
    final double ampX = span(0.3, 0.9) * math.min(1.5, halfW);
    final double ampY = span(0.2, 0.6) * math.min(1.5, halfH);
    shapes.add(
      _make(
        rng,
        metaphorShapeBlob,
        x: x,
        y: y,
        sx: radius,
        sy: radius,
        accent: 1,
        tone: 0.4,
        ampX: ampX,
        ampY: ampY,
        pulse: 1,
      ),
    );
  }

  for (int index = count(0.8); index > 0; index--) {
    final double radius = span(0.5, 1.5) * reach;
    final bool accent = rng() < 0.35;
    final (double x, double y) = around(0, reach * 2);
    final double ampX = span(0, 0.4);
    final double ampY = span(0, 0.4);
    shapes.add(
      _make(
        rng,
        metaphorShapeRing,
        x: x,
        y: y,
        sx: radius,
        sy: radius,
        ink: accent ? 0 : 1,
        accent: accent ? 1 : 0,
        ampX: ampX,
        ampY: ampY,
      ),
    );
  }

  return shapes.length > _planLimit ? shapes.sublist(0, _planLimit) : shapes;
}

/// 几份规划拼成一份：小墨滴的 parent 加上前面的长度。
List<MetaphorShape> joinMetaphorShapes(List<List<MetaphorShape>> groups) {
  final List<MetaphorShape> joined = <MetaphorShape>[];
  for (final List<MetaphorShape> group in groups) {
    final int base = joined.length;
    for (final MetaphorShape s in group) {
      joined.add(s.parent >= 0 && base > 0 ? s.withParent(s.parent + base) : s);
    }
  }
  return joined;
}

/// 每帧的图形实例数据（folia 写给着色器的那段 Float32Array）。
class MetaphorInstances {
  final Float64List data = Float64List(
    metaphorShapeCapacity * metaphorShapeStride,
  );
  int count = 0;

  void clear() => count = 0;

  /// 写一个图形；满了就不写。
  void put(
    int shape,
    double x,
    double y,
    double sx,
    double sy,
    double rot,
    double ink,
    double tone,
    double accent, [
    double param = 0,
  ]) {
    if (count >= metaphorShapeCapacity) return;
    final int at = count * metaphorShapeStride;
    data[at] = x;
    data[at + 1] = y;
    data[at + 2] = sx;
    data[at + 3] = sy;
    data[at + 4] = rot;
    data[at + 5] = ink;
    data[at + 6] = tone;
    data[at + 7] = accent;
    data[at + 8] = shape.toDouble();
    data[at + 9] = param;
    count++;
  }

  int shapeAt(int i) => data[i * metaphorShapeStride + 8].toInt();
  double valueAt(int i, int field) => data[i * metaphorShapeStride + field];
}

/// 把规划在 time 这一刻的样子写进实例数据。audio 是 0..1 的音量，flow 是「流体」的倍数。
/// since 是 cue 开始了多久：还没到 born 的不写。[includeLines] 为 false 时细线 / 圆弧 / 波浪线
/// 不写（它们不动，由画家另外缓存成矢量图）。
void writeMetaphorShapes(
  List<MetaphorShape> shapes,
  double time,
  double audio,
  double flow,
  MetaphorInstances out, {
  double since = double.infinity,
  int limit = metaphorShapeCapacity - metaphorDynamicReserve,
  bool includeLines = true,
}) {
  final Float64List xs = Float64List(shapes.length);
  final Float64List ys = Float64List(shapes.length);
  for (int i = 0; i < shapes.length; i++) {
    if (out.count >= limit) break;
    final MetaphorShape s = shapes[i];
    double x = s.x + s.ampX * flow * math.sin(time * s.w1 + s.p1);
    double y = s.y + s.ampY * flow * math.cos(time * s.w2 + s.p2);
    if (s.orbit > 0) {
      final double angle = time * s.orbitSpeed + s.p1;
      final double radius = s.steady
          ? s.orbit
          : s.orbit * (0.8 + 0.35 * math.sin(time * 0.3 + s.p2));
      x = (s.parent >= 0 ? xs[s.parent] : x) + math.cos(angle) * radius;
      y = (s.parent >= 0 ? ys[s.parent] : y) + math.sin(angle) * radius;
    }
    xs[i] = x;
    ys[i] = y;
    if (s.born > since) continue;
    if (!includeLines && s.isLine) continue;
    final double swell =
        1 + s.pulse * (0.06 * math.sin(time * 0.4 + s.p2) + 0.14 * audio);
    out.put(
      s.shape,
      x,
      y,
      s.sx * swell,
      s.sy * swell,
      s.rot,
      s.ink,
      s.tone,
      s.accent,
      s.param,
    );
  }
}

/// 沿螺旋线甩出去的一颗碎片。
class MetaphorFragment {
  const MetaphorFragment({
    required this.dir,
    required this.curl,
    required this.range,
    required this.size,
    required this.life,
  });

  final double dir;
  final double curl;
  final double range;
  final double size;
  final double life;
}

class MetaphorCollision {
  const MetaphorCollision({
    required this.time,
    required this.x,
    required this.y,
    required this.angle,
    required this.unit,
    required this.fragments,
  });

  /// 撞上的时刻（cue 里的时间）。
  final double time;
  final double x;
  final double y;
  final double angle;
  final double unit;
  final List<MetaphorFragment> fragments;
}

/// 两颗墨球从出发到撞上用多久。
const double metaphorCollisionApproach = 2.6;

/// 撞完以后碎片最多还活多久。
const double metaphorCollisionLife = 6.5;
const int _trailDots = 5;
const double _trailGap = 0.3;

/// 一个 cue 里的几次对撞：times 是撞上的时刻。
List<MetaphorCollision> planMetaphorCollisions(
  MetaphorRect bounds,
  MetaphorRng rng,
  List<double> times,
  double amount,
  bool interlude,
) {
  if (amount <= 0) return const <MetaphorCollision>[];
  final _Stage stage = _Stage(bounds);
  double span(double min, double max) => min + rng() * (max - min);
  return <MetaphorCollision>[
    for (final double time in times)
      _collision(stage, rng, span, time, amount, interlude),
  ];
}

MetaphorCollision _collision(
  _Stage stage,
  MetaphorRng rng,
  double Function(double, double) span,
  double time,
  double amount,
  bool interlude,
) {
  final double unit = math.max(1, stage.reach * 0.32) * span(0.8, 1.2);
  final double x;
  final double y;
  if (interlude) {
    x = span(-0.5, 0.5) * stage.halfW;
    y = span(-0.5, 0.5) * stage.halfH;
  } else {
    (x, y) = _outsidePoint(stage, rng, unit * 0.9, stage.reach * 0.5);
  }
  final int total = math.max(3, (span(5, 9) * math.min(1.5, amount)).round());
  final List<MetaphorFragment> fragments = <MetaphorFragment>[];
  for (int index = 0; index < total; index++) {
    final double size = span(0.05, 0.15);
    final double dir = rng() * _tau;
    final double curl =
        (rng() < 0.5 ? -1 : 1) * span(0.5, 1.2) * (0.16 / (size + 0.04));
    final double range = unit * span(1.2, 3.2);
    final double life = span(3.5, metaphorCollisionLife);
    fragments.add(
      MetaphorFragment(
        dir: dir,
        curl: curl,
        range: range,
        size: unit * size,
        life: life,
      ),
    );
  }
  return MetaphorCollision(
    time: time,
    x: x,
    y: y,
    angle: rng() * _tau,
    unit: unit,
    fragments: fragments,
  );
}

/// 对撞在 time 这一刻的样子。
void writeMetaphorCollisions(
  List<MetaphorCollision> collisions,
  double time,
  MetaphorInstances out,
) {
  for (final MetaphorCollision hit in collisions) {
    final double since = time - hit.time;
    if (since < -metaphorCollisionApproach || since >= metaphorCollisionLife) {
      continue;
    }
    final double cos = math.cos(hit.angle);
    final double sin = math.sin(hit.angle);
    if (since < 0) {
      // 相向加速：剩下的路程按 1 - u³ 缩短，身后拖三个越来越小的点
      for (int dot = 0; dot <= 3; dot++) {
        final double u = 1 + since / metaphorCollisionApproach - dot * 0.035;
        if (u < 0) continue;
        final double left = hit.unit * 5 * (1 - u * u * u);
        final double r = hit.unit * (dot == 0 ? 0.22 : 0.13 - dot * 0.025);
        out
          ..put(
            metaphorShapeBlob,
            hit.x + cos * left,
            hit.y + sin * left,
            r,
            r,
            0,
            1,
            0.3,
            0,
          )
          ..put(
            metaphorShapeBlob,
            hit.x - cos * left,
            hit.y - sin * left,
            r,
            r,
            0,
            1,
            0.3,
            0,
          );
      }
      continue;
    }
    final double burst = hit.unit * 0.95 * math.exp(-since * 1.6);
    if (burst > hit.unit * 0.04) {
      out.put(metaphorShapeBlob, hit.x, hit.y, burst, burst, 0, 1, 0.8, 0);
    }
    if (since < 4) {
      final double ring =
          hit.unit * (0.35 + 2.6 * (1 - math.exp(-since * 0.55)));
      out.put(
        metaphorShapeRing,
        hit.x,
        hit.y,
        ring,
        ring,
        0,
        since < 2.2 ? 1 : 0,
        1,
        0,
      );
    }
    for (final MetaphorFragment f in hit.fragments) {
      for (int dot = 0; dot <= _trailDots; dot++) {
        final double age = since - dot * _trailGap;
        if (age < 0 || age >= f.life) continue;
        final double travelled = f.range * (1 - math.exp(-age * 0.6));
        final double angle = f.dir + (f.curl * travelled) / hit.unit;
        final double fade = 1 - age / f.life;
        final double r = f.size * fade * (dot == 0 ? 1 : 0.6 - dot * 0.07);
        out.put(
          metaphorShapeBlob,
          hit.x + math.cos(angle) * travelled,
          hit.y + math.sin(angle) * travelled,
          r,
          r,
          0,
          1,
          0.25,
          0,
        );
      }
    }
  }
}

const double _pairLife = 3.6;

/// 刚唱到的字放出一对粒子。
void writeMetaphorPairs(
  List<MetaphorGlyph> glyphs,
  double time,
  MetaphorInstances out,
) {
  for (final MetaphorGlyph g in glyphs) {
    final double age = time - g.t0;
    if (age < 0 || age >= _pairLife) continue;
    final double life = age / _pairLife;
    final double travelled = g.size * (0.4 + 1.5 * (1 - math.exp(-age * 0.7)));
    final double r = g.size * (0.07 + g.seed * 0.05) * (1 - life * life);
    final double curl = 0.9 + g.seed * 1.4;
    final double ink = g.accent ? 0 : 1;
    final double accent = g.accent ? 1 : 0;
    for (final int side in const <int>[1, -1]) {
      final double angle =
          g.seed * _tau +
          (side > 0 ? 0 : math.pi) +
          (side * curl * travelled) / g.size;
      out.put(
        metaphorShapeBlob,
        g.x + math.cos(angle) * travelled,
        g.y + math.sin(angle) * travelled,
        r,
        r,
        0,
        ink,
        0.3,
        accent,
      );
    }
  }
}
