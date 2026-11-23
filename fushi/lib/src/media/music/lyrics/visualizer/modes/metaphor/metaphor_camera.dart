/// 隐喻的镜头（纯函数，移植 folia `metaphor/metaphorCamera.ts`）：一个镜头在某一刻的机位、句与句
/// 之间转场的量（漫墨）、一句歌词出现和化开的进度。机位永远正对画面：只有平移、远近、绕视线的
/// 滚转。一个镜头里机位只极慢地蠕动；要走远的（跟字、拉远、冲镜）分几档在词开唱时刻上跳切。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_program.dart';

/// 机位。
class MetaphorPose {
  const MetaphorPose({
    required this.x,
    required this.y,
    required this.distance,
    required this.roll,
    this.fov = metaphorFov,
  });

  /// 看向的点（机位在它正前方）。
  final double x;
  final double y;

  /// 离画面多远。
  final double distance;
  final double roll;

  /// 竖直视角，度。
  final double fov;

  /// 画面半高（世界单位）。
  double get halfHeight => distance * math.tan(fov * math.pi / 360);

  MetaphorPose shifted(double dx, double dy) => MetaphorPose(
    x: x + dx,
    y: y + dy,
    distance: distance,
    roll: roll,
    fov: fov,
  );
}

/// 所有镜头同一个视角：远近只靠机位的距离。
const double metaphorFov = 30;

double _clamp01(double v) => math.min(1, math.max(0, v));
double _lerp(double a, double b, double t) => a + (b - a) * t;
double _easeOutCubic(double u) {
  final double k = 1 - u;
  return 1 - k * k * k;
}

final double _tanHalfFov = math.tan(metaphorFov * math.pi / 360);

class _Focus {
  const _Focus(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;
}

_Focus _rectFocus(MetaphorRect r) => _Focus(
  (r.x0 + r.x1) / 2,
  (r.y0 + r.y1) / 2,
  math.max(1.6, r.x1 - r.x0),
  math.max(1.2, r.y1 - r.y0),
);

/// time 这一刻正在唱（或刚唱过）的词；还没开唱是第一个。
int metaphorWordIndexAt(MetaphorLayout layout, double time) {
  int found = 0;
  double latest = double.negativeInfinity;
  for (int i = 0; i < layout.words.length; i++) {
    final MetaphorWord w = layout.words[i];
    if (w.t0 <= time && w.t0 >= latest) {
      latest = w.t0;
      found = i;
    }
  }
  return found;
}

_Focus _emptyFocus(MetaphorRect b, double seed) {
  final double w = b.x1 - b.x0;
  final double h = b.y1 - b.y0;
  return _Focus(
    b.x0 + w * (0.2 + 0.6 * seed),
    b.y0 + h * (0.2 + 0.6 * ((seed * 7.31) % 1)),
    w * 0.3,
    h * 0.3,
  );
}

_Focus _wordFocus(MetaphorLayout layout, double time, double seed) =>
    layout.words.isEmpty
    ? _emptyFocus(layout.bounds, seed)
    : _rectFocus(layout.words[metaphorWordIndexAt(layout, time)]);

MetaphorGlyph _glyphAt(MetaphorLayout layout, double time) {
  MetaphorGlyph found = layout.glyphs.first;
  for (final MetaphorGlyph g in layout.glyphs) {
    if (g.t0 <= time && g.t0 >= found.t0) found = g;
  }
  return found;
}

_Focus _glyphFocus(MetaphorLayout layout, double time, double seed) {
  if (layout.glyphs.isEmpty) return _emptyFocus(layout.bounds, seed);
  final MetaphorGlyph g = _glyphAt(layout, time);
  return _Focus(g.x, g.y, g.size * 0.9, g.size * 0.9);
}

int _macroWord(MetaphorLayout layout, MetaphorShot shot) =>
    layout.glyphs.isEmpty ? -1 : _glyphAt(layout, shot.start).word;

int _macroFollowWord(MetaphorLayout layout, MetaphorShot shot, double time) {
  final int anchor = _macroWord(layout, shot);
  if (anchor < 0) return -1;
  final int current = metaphorWordIndexAt(layout, time);
  return current != anchor && layout.words[current].t0 > layout.words[anchor].t0
      ? current
      : -1;
}

double _fitDistance(_Focus f, double margin, double aspect) =>
    (math.max(f.height / 2, f.width / (2 * math.max(0.2, aspect))) * margin) /
    _tanHalfFov;

int _stepAt(MetaphorShot shot, MetaphorLayout layout, double time, int steps) {
  final List<double> onsets =
      layout.words
          .map((MetaphorWord w) => w.t0)
          .toSet()
          .where((double t) => t > shot.start + 0.3 && t < shot.end - 0.3)
          .toList()
        ..sort();
  final List<double> times = <double>[];
  if (onsets.length >= steps) {
    for (int i = 0; i < steps; i++) {
      times.add(onsets[(i * onsets.length) ~/ steps]);
    }
  } else {
    for (int i = 1; i <= steps; i++) {
      times.add(shot.start + ((shot.end - shot.start) * i) / (steps + 1));
    }
  }
  return times.where((double at) => at <= time).length;
}

/// 极慢的漂：十几秒才晃一个来回。
double _wobble(double time, double phase) =>
    math.sin(time * 0.23 + phase) * 0.6 +
    math.sin(time * 0.37 + phase * 2.3) * 0.4;

const double _wideMargin = 1.1;
const int _pullbackSteps = 3;
const int _pushinSteps = 3;
const double _macroMargin = 0.8;
const double _closeMargin = 1.3;
const double _macroFollowRoll = 0.12;
const double _pushinBeat = 0.16;

class MetaphorPoseInput {
  const MetaphorPoseInput({
    required this.shot,
    required this.layout,
    required this.time,
    required this.aspect,
    required this.motion,
  });

  final MetaphorShot shot;
  final MetaphorLayout layout;

  /// cue 里的时间（循环的 cue 已经折回）。
  final double time;
  final double aspect;

  /// 运镜幅度，0..2。
  final double motion;

  MetaphorPoseInput at(double t, {double? motion}) => MetaphorPoseInput(
    shot: shot,
    layout: layout,
    time: t,
    aspect: aspect,
    motion: motion ?? this.motion,
  );
}

/// 一个镜头按分镜在 time 这一刻的机位（还没管正在唱的字在不在画里）。
MetaphorPose metaphorPlannedPose(MetaphorPoseInput input) {
  final MetaphorShot shot = input.shot;
  final MetaphorLayout layout = input.layout;
  final double time = input.time;
  final double aspect = input.aspect;
  final double motion = input.motion;
  final double u = _clamp01(
    (time - shot.start) / math.max(0.001, shot.end - shot.start),
  );
  final double creep = 1 - 0.035 * motion * u;
  final _Focus whole = _rectFocus(layout.bounds);
  _Focus focus = whole;
  double distance;
  double roll = shot.roll;
  switch (shot.kind) {
    case MetaphorShotKind.wide:
      distance = _fitDistance(whole, _wideMargin, aspect) * creep;
    case MetaphorShotKind.close:
      focus = _wordFocus(layout, shot.start, shot.seed);
      distance = _fitDistance(focus, _closeMargin, aspect) * creep;
    case MetaphorShotKind.follow:
      focus = _wordFocus(layout, time, shot.seed);
      distance = _fitDistance(focus, 1.45, aspect);
    case MetaphorShotKind.macro:
      final int following = _macroFollowWord(layout, shot, time);
      if (following >= 0) {
        focus = _rectFocus(layout.words[following]);
        distance = _fitDistance(focus, _closeMargin, aspect) * creep;
        roll *= _macroFollowRoll;
      } else {
        focus = _glyphFocus(layout, shot.start, shot.seed);
        distance = _fitDistance(focus, _macroMargin, aspect) * creep;
        roll += 0.03 * motion * (u - 0.5);
      }
    case MetaphorShotKind.dutch:
      distance = _fitDistance(whole, 1.1, aspect) * creep;
    case MetaphorShotKind.empty:
      distance = _fitDistance(whole, 1.85, aspect) * (2 - creep);
    case MetaphorShotKind.pullback:
      final _Focus near = _wordFocus(layout, shot.start, shot.seed);
      final double out =
          _stepAt(shot, layout, time, _pullbackSteps) / _pullbackSteps;
      focus = _Focus(
        _lerp(near.x, whole.x, out),
        _lerp(near.y, whole.y, out),
        whole.width,
        whole.height,
      );
      distance = _lerp(
        _fitDistance(near, 1.15, aspect),
        _fitDistance(whole, 1.4, aspect),
        out,
      );
    case MetaphorShotKind.pushin:
      final _Focus near = _wordFocus(layout, shot.start, shot.seed);
      final double into =
          math.min(
            _pushinSteps,
            (math.max(0, time - shot.start) / _pushinBeat).floor(),
          ) /
          _pushinSteps;
      focus = _Focus(
        _lerp(whole.x, near.x, into),
        _lerp(whole.y, near.y, into),
        near.width,
        near.height,
      );
      distance =
          _lerp(
            _fitDistance(whole, 3.2, aspect),
            _fitDistance(near, 1.3, aspect),
            into,
          ) *
          creep;
  }
  final double visible = 2 * distance * _tanHalfFov;
  final double phase = shot.seed * 40;
  final double drift = 0.008 * motion * visible;
  return MetaphorPose(
    x: focus.x - shot.offsetX * visible + _wobble(time, phase) * drift,
    y: focus.y - shot.offsetY * visible + _wobble(time, phase + 11) * drift,
    distance: distance,
    roll: roll + _wobble(time, phase + 23) * 0.004 * motion,
  );
}

const double _keepOut = 0.97;
const double _keepIn = 0.9;
const double _minShift = 0.06;
const Set<MetaphorShotKind> _lookAhead = <MetaphorShotKind>{
  MetaphorShotKind.close,
  MetaphorShotKind.pushin,
};
const double _minSung = 0.3;

MetaphorWord? _sungUnitAt(List<MetaphorWord> units, double at) {
  MetaphorWord? found;
  for (final MetaphorWord u in units) {
    if (u.t0 <= at && (found == null || u.t0 >= found.t0)) found = u;
  }
  return found != null && at < math.max(found.t1, found.t0 + _minSung)
      ? found
      : null;
}

class _Frame {
  _Frame(this.halfX, this.halfY, this.lowX, this.lowY, this.highX, this.highY);

  final double halfX;
  final double halfY;
  final double lowX;
  final double lowY;
  final double highX;
  final double highY;
}

_Frame _frame(
  MetaphorPose pose,
  MetaphorRect rect,
  double aspect,
  double inner,
) {
  final double halfHeight = pose.halfHeight;
  final double cos = math.cos(pose.roll);
  final double sin = math.sin(pose.roll);
  double lx = double.infinity;
  double ly = double.infinity;
  double hx = double.negativeInfinity;
  double hy = double.negativeInfinity;
  for (final double x in <double>[rect.x0, rect.x1]) {
    for (final double y in <double>[rect.y0, rect.y1]) {
      final double dx = x - pose.x;
      final double dy = y - pose.y;
      final double ax = dx * cos + dy * sin;
      final double ay = -dx * sin + dy * cos;
      lx = math.min(lx, ax);
      ly = math.min(ly, ay);
      hx = math.max(hx, ax);
      hy = math.max(hy, ay);
    }
  }
  return _Frame(
    halfHeight * aspect * inner,
    halfHeight * inner,
    lx,
    ly,
    hx,
    hy,
  );
}

bool _fitsWithin(
  MetaphorPose pose,
  MetaphorRect rect,
  double aspect,
  double inner,
) {
  final _Frame f = _frame(pose, rect, aspect, inner);
  return f.highX - f.lowX <= 2 * f.halfX && f.highY - f.lowY <= 2 * f.halfY;
}

MetaphorRect _placeTarget(
  MetaphorShot shot,
  List<MetaphorWord> order,
  MetaphorWord unit,
  List<MetaphorPose> poses,
  double aspect,
) {
  if (!_lookAhead.contains(shot.kind)) return unit;
  MetaphorRect target = unit;
  for (int i = order.indexOf(unit) + 1; i < order.length; i++) {
    final MetaphorRect grown = target.union(order[i]);
    if (!poses.every(
      (MetaphorPose p) => _fitsWithin(p, grown, aspect, _keepIn),
    )) {
      break;
    }
    target = grown;
  }
  return target;
}

double _axisShift(double low, double high, double half, double inner) {
  final double size = high - low;
  final double full = half / inner;
  if (size > 2 * full) {
    final double room = half * 0.5;
    final double center = (low + high) / 2;
    return center > room
        ? center - room
        : center < -room
        ? center + room
        : 0;
  }
  final double limit = math.max(half, size / 2);
  return high > limit
      ? high - limit
      : low < -limit
      ? low + limit
      : 0;
}

/// 机位要挪多少（画面坐标，转过滚转的）才能把 unit 摆进视口的 inner 那一圈。
(double, double) _fitShift(
  MetaphorPose pose,
  MetaphorRect unit,
  double aspect,
  double inner,
) {
  final _Frame f = _frame(pose, unit, aspect, inner);
  return (
    _axisShift(f.lowX, f.highX, f.halfX, inner),
    _axisShift(f.lowY, f.highY, f.halfY, inner),
  );
}

List<double> _checkpoints(MetaphorShot shot, List<MetaphorWord> units) {
  final List<double> times = units.map((MetaphorWord u) => u.t0).toList();
  if (shot.kind == MetaphorShotKind.pullback) {
    for (int step = 1; step <= _pullbackSteps; step++) {
      times.add(
        shot.start + ((shot.end - shot.start) * step) / (_pullbackSteps + 1),
      );
    }
  }
  if (shot.kind == MetaphorShotKind.pushin) {
    times.add(shot.start + _pushinSteps * _pushinBeat);
  }
  final List<double> after =
      times.toSet().where((double t) => t > shot.start).toList()..sort();
  return <double>[shot.start, ...after];
}

class _KeepTrack {
  _KeepTrack({
    required this.shot,
    required this.aspect,
    required this.motion,
    required this.units,
    required this.skip,
    required this.order,
    required this.times,
  });

  final MetaphorShot shot;
  final double aspect;
  final double motion;
  final List<MetaphorWord> units;
  final MetaphorWord? skip;
  final List<MetaphorWord> order;
  final List<double> times;
  int next = 0;
  MetaphorPose? still;
  double shiftX = 0;
  double shiftY = 0;
}

MetaphorPose _shiftPose(MetaphorPose pose, double sx, double sy) {
  if (sx == 0 && sy == 0) return pose;
  final double cos = math.cos(pose.roll);
  final double sin = math.sin(pose.roll);
  return pose.shifted(sx * cos - sy * sin, sx * sin + sy * cos);
}

bool _outside(MetaphorPose pose, MetaphorWord unit, double aspect) {
  final (double x, double y) = _fitShift(pose, unit, aspect, _keepOut);
  return x != 0 || y != 0;
}

/// 「正在唱的词跑出画面就硬切」的增量缓存：按排版各存一份进度，结果和每帧从头算一样。
class MetaphorPoseTracker {
  final Expando<_KeepTrack> _tracks = Expando<_KeepTrack>();

  _KeepTrack _trackFor(MetaphorPoseInput input) {
    final _KeepTrack? track = _tracks[input.layout];
    if (track != null &&
        identical(track.shot, input.shot) &&
        track.aspect == input.aspect &&
        track.motion == input.motion &&
        input.time >=
            (track.next > 0 ? track.times[track.next - 1] : input.shot.start)) {
      return track;
    }
    final List<MetaphorWord> units = input.layout.words;
    final int anchor = input.shot.kind == MetaphorShotKind.macro
        ? _macroWord(input.layout, input.shot)
        : -1;
    final _KeepTrack fresh = _KeepTrack(
      shot: input.shot,
      aspect: input.aspect,
      motion: input.motion,
      units: units,
      skip: anchor >= 0 ? units[anchor] : null,
      order: List<MetaphorWord>.of(units)
        ..sort((MetaphorWord a, MetaphorWord b) => a.t0.compareTo(b.t0)),
      times: _checkpoints(input.shot, units),
    );
    _tracks[input.layout] = fresh;
    return fresh;
  }

  void _advance(_KeepTrack track, MetaphorPoseInput input) {
    final MetaphorShot shot = input.shot;
    final double aspect = input.aspect;
    final double at = track.times[track.next];
    track.next += 1;
    final MetaphorPose still = metaphorPlannedPose(input.at(at, motion: 0));
    final MetaphorPose? previous = track.still;
    track.still = still;
    if (previous != null &&
        (still.x != previous.x ||
            still.y != previous.y ||
            still.distance != previous.distance)) {
      track.shiftX = 0;
      track.shiftY = 0;
    }
    final MetaphorWord? unit = _sungUnitAt(track.units, at);
    if (unit == null || identical(unit, track.skip)) return;
    final MetaphorPose planned = metaphorPlannedPose(input.at(at));
    final double nextTime = track.next < track.times.length
        ? track.times[track.next]
        : shot.end;
    final double until =
        math.min(
          math.min(nextTime, math.max(unit.t1, unit.t0 + _minSung)),
          shot.end,
        ) -
        1e-3;
    final MetaphorPose later = until > at
        ? metaphorPlannedPose(input.at(until))
        : planned;
    if (!_outside(
          _shiftPose(planned, track.shiftX, track.shiftY),
          unit,
          aspect,
        ) &&
        !_outside(
          _shiftPose(later, track.shiftX, track.shiftY),
          unit,
          aspect,
        )) {
      return;
    }
    (double, double) need = _fitShift(
      planned,
      _placeTarget(shot, track.order, unit, <MetaphorPose>[
        planned,
        later,
      ], aspect),
      aspect,
      _keepIn,
    );
    if (_outside(_shiftPose(later, need.$1, need.$2), unit, aspect)) {
      need = _fitShift(later, unit, aspect, _keepIn);
    }
    final double visible = 2 * planned.halfHeight * math.min(1, aspect);
    final double dx = need.$1 - track.shiftX;
    final double dy = need.$2 - track.shiftY;
    if (math.sqrt(dx * dx + dy * dy) < _minShift * visible) return;
    track.shiftX = need.$1;
    track.shiftY = need.$2;
  }

  /// 一个镜头在 time 这一刻的机位：照分镜，只在正在唱的词跑出画面时硬切过去。
  MetaphorPose resolve(MetaphorPoseInput input) {
    final MetaphorPose pose = metaphorPlannedPose(input);
    if (input.time < input.shot.start ||
        (input.layout.words.isEmpty && input.layout.glyphs.isEmpty)) {
      return pose;
    }
    final _KeepTrack track = _trackFor(input);
    while (track.next < track.times.length &&
        track.times[track.next] <= input.time) {
      _advance(track, input);
    }
    return _shiftPose(pose, track.shiftX, track.shiftY);
  }
}

/// 静态模式：每句一个锁死的全景。
MetaphorPose resolveMetaphorStillPose(MetaphorLayout layout, double aspect) {
  final _Focus whole = _rectFocus(layout.bounds);
  return MetaphorPose(
    x: whole.x,
    y: whole.y,
    distance: _fitDistance(whole, _wideMargin, aspect),
    roll: 0,
  );
}

const double _floodIn = 0.7;
const double _floodOut = 0.9;

/// 漫墨在 time 这一刻的量：进当前 cue 的那一半，和出到下一个 cue 的那一半。
double resolveMetaphorFlood(
  MetaphorProgram program,
  int cueIndex,
  double time,
) {
  double flood = 0;
  final MetaphorCue cue = program.cues[cueIndex];
  final double since = time - cue.start;
  if (since >= 0 &&
      cue.transition == MetaphorTransition.flood &&
      since < _floodOut) {
    flood = 1.15 * (1 - _easeOutCubic(since / _floodOut));
  }
  if (cueIndex + 1 < program.cues.length) {
    final MetaphorCue next = program.cues[cueIndex + 1];
    final double until = next.start - time;
    if (next.transition == MetaphorTransition.flood && until < _floodIn) {
      final double k = 1 - until / _floodIn;
      flood = math.max(flood, 1.15 * k * k);
    }
  }
  return flood;
}

/// 一句歌词的影子出现到几成（开唱前的预告）。
double resolveMetaphorReveal(MetaphorCue cue, double time) =>
    _clamp01((time - cue.start) / 0.5 + (cue.lineIndex < 0 ? 1 : 0));

/// 一句歌词化开到几成：只有唱完后还留着一段尾巴的才化，紧跟下一句的直接硬切。
double resolveMetaphorMelt(MetaphorCue cue, double time) {
  if (cue.lineIndex < 0 || cue.end - cue.singEnd < metaphorTail * 0.6) return 0;
  final double from = math.max(cue.singEnd + 0.3, cue.end - 1.5);
  return _clamp01((time - from) / math.max(0.05, cue.end - from));
}
