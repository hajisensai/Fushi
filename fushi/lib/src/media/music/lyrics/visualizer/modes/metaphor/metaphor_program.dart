/// 隐喻的分镜表（纯函数，移植 folia `metaphor/metaphorProgram.ts`）：整首歌编成一串首尾相接的
/// cue（一句歌词，或句与句之间的间奏），每个 cue 里是几个硬切的镜头。切点吸到词开唱的时刻上；
/// 机位按歌的 seed 选，都正对画面（没有偏转和俯仰）。同一首歌每次都一样，画面完全由播放时间决定。
///
/// 时间单位是秒（folia 原样），调用方把歌词显示时间的毫秒换成秒。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';

/// 0..1 的随机数源（按顺序取）。
typedef MetaphorRng = double Function();

/// 字符串 key → 稳定的随机数源（folia `createVisualizerRng`）。
MetaphorRng metaphorRng(String key) {
  final LyricVisualizerRandom r = LyricVisualizerRandom(
    lyricVisualizerSeedOf(key),
  );
  return r.next;
}

/// 机位。
enum MetaphorShotKind {
  wide,
  close,
  follow,
  macro,
  dutch,

  /// 留白远景（folia `void`）。
  empty,
  pullback,
  pushin,
}

/// 进一个 cue 的转场。
enum MetaphorTransition { cut, flood, smash }

/// 一句的构图（方阵、阶梯、主词、竖排、散置、齐行）。
enum MetaphorComposition { block, stair, hero, column, scatter, justify }

/// 一个硬切的镜头。
class MetaphorShot {
  const MetaphorShot({
    required this.start,
    required this.end,
    required this.kind,
    required this.roll,
    required this.offsetX,
    required this.offsetY,
    required this.invert,
    required this.screenAngle,
    required this.seed,
  });

  final double start;
  final double end;
  final MetaphorShotKind kind;

  /// 弧度：绕视线的滚转。
  final double roll;

  /// 目标在画面里偏离中心多少（画面高度的倍数）。
  final double offsetX;
  final double offsetY;

  /// 纸和墨对调。
  final bool invert;

  /// 这个镜头的网点角度（弧度）。
  final double screenAngle;

  /// 0..1，这个镜头自己的随机数。
  final double seed;
}

/// 一句歌词或一段间奏。
class MetaphorCue {
  MetaphorCue({
    required this.lineIndex,
    required this.start,
    required this.end,
    required this.singStart,
    required this.singEnd,
    required this.composition,
    required this.transition,
    required this.chorus,
    required this.text,
    required this.loop,
  });

  /// 节目输入里的第几句；间奏是 -1。
  final int lineIndex;
  final double start;
  final double end;
  final double singStart;
  final double singEnd;
  final MetaphorComposition composition;
  List<MetaphorShot> shots = const <MetaphorShot>[];
  final MetaphorTransition transition;
  final bool chorus;

  /// 间奏上的字（开头的曲名卡）；没有是空。
  final String text;

  /// 镜头按这么长循环（没有尽头的那个 cue）；0 是不循环。
  final double loop;
}

class MetaphorProgram {
  const MetaphorProgram(this.cues);

  final List<MetaphorCue> cues;
}

/// 编分镜表要的一句歌词（秒）。
class MetaphorProgramLine {
  const MetaphorProgramLine({
    required this.lineIndex,
    required this.text,
    required this.start,
    required this.end,
    required this.wordStarts,
    this.chorus = false,
  });

  /// 从运行时的一行换算。
  factory MetaphorProgramLine.fromRuntime(
    int index,
    LyricVisualizerLine line,
  ) => MetaphorProgramLine(
    lineIndex: index,
    text: line.text,
    start: line.startMs / 1000,
    end: line.endMs / 1000,
    wordStarts: <double>[
      for (final LyricVisualizerWord w in line.words) w.startMs / 1000,
    ],
    chorus: line.isChorus,
  );

  final int lineIndex;
  final String text;
  final double start;
  final double end;
  final List<double> wordStarts;
  final bool chorus;
}

/// 歌词出现得比开唱早这么多：先是一层网点的影子。
const double metaphorPreroll = 0.6;

/// 唱完后这句还留多久（化开）。
const double metaphorTail = 2;
const double _interludeMin = 2.4;
const double _minShot = 0.6;
const double _minCue = 0.15;
const double _loopSeconds = 48;
const double _interludeSegment = 24;
const double _interludeSplit = 36;
const double _interludeHorizon = 720;
const double _sameOnset = 0.3;
const List<double> _screenAngles = <double>[0.26, 0.52, 0.79, 1.31];

final RegExp _cjk = RegExp(r'[぀-ヿ㐀-鿿가-힯ｦ-ﾟ]', unicode: true);
final RegExp _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _spaces = RegExp(r'\s+', unicode: true);

/// 按权重挑一个（跳过 [avoid]）；权重表的顺序就是取数的顺序。
T metaphorPick<T>(MetaphorRng rng, List<(T, double)> weights, [T? avoid]) {
  List<(T, double)> pool = weights
      .where(((T, double) e) => e.$2 > 0 && e.$1 != avoid)
      .toList();
  if (pool.isEmpty) pool = weights;
  final double total = pool.fold(0, (double s, (T, double) e) => s + e.$2);
  double roll = rng() * total;
  for (final (T key, double w) in pool) {
    roll -= w;
    if (roll <= 0) return key;
  }
  return pool.last.$1;
}

const List<(MetaphorShotKind, double)> _firstShot =
    <(MetaphorShotKind, double)>[
      (MetaphorShotKind.wide, 3),
      (MetaphorShotKind.close, 2),
      (MetaphorShotKind.dutch, 1.5),
      (MetaphorShotKind.empty, 0.8),
      (MetaphorShotKind.follow, 1.5),
    ];
const List<(MetaphorShotKind, double)> _middleShot =
    <(MetaphorShotKind, double)>[
      (MetaphorShotKind.close, 3),
      (MetaphorShotKind.follow, 2),
      (MetaphorShotKind.macro, 2),
      (MetaphorShotKind.dutch, 1.5),
      (MetaphorShotKind.wide, 1),
      (MetaphorShotKind.empty, 0.6),
    ];
const List<(MetaphorShotKind, double)> _interludeShot =
    <(MetaphorShotKind, double)>[
      (MetaphorShotKind.empty, 3),
      (MetaphorShotKind.macro, 2),
      (MetaphorShotKind.pullback, 1.5),
      (MetaphorShotKind.wide, 1.5),
      (MetaphorShotKind.dutch, 1),
    ];

double _span(MetaphorRng rng, double min, double max) =>
    min + rng() * (max - min);
double _sign(MetaphorRng rng) => rng() < 0.5 ? -1 : 1;

/// 一个镜头的滚转和偏移：每种机位自己的范围。
(double, double, double) _shotPose(MetaphorShotKind kind, MetaphorRng rng) {
  switch (kind) {
    case MetaphorShotKind.wide:
      return (_span(rng, -0.05, 0.05), 0, 0);
    case MetaphorShotKind.close:
      final double roll = _span(rng, -0.07, 0.07);
      final double ox = _span(rng, -0.08, 0.08);
      return (roll, ox, _span(rng, -0.05, 0.05));
    case MetaphorShotKind.follow:
      return (_span(rng, -0.03, 0.03), 0, 0);
    case MetaphorShotKind.macro:
      final double roll = _sign(rng) * _span(rng, 0.25, 0.6);
      final double ox = _span(rng, -0.12, 0.12);
      return (roll, ox, _span(rng, -0.12, 0.12));
    case MetaphorShotKind.dutch:
      final double roll = _sign(rng) * _span(rng, 0.2, 0.4);
      return (roll, _span(rng, -0.1, 0.1), 0);
    case MetaphorShotKind.empty:
      final double roll = _span(rng, -0.04, 0.04);
      final double ox = _sign(rng) * _span(rng, 0.18, 0.3);
      return (roll, ox, _sign(rng) * _span(rng, 0.1, 0.22));
    case MetaphorShotKind.pullback:
      return (_span(rng, -0.1, 0.1), 0, 0);
    case MetaphorShotKind.pushin:
      return (_span(rng, -0.12, 0.12), 0, 0);
  }
}

class _ShotContext {
  _ShotContext(this.rng, this.negative);

  final MetaphorRng rng;
  final bool negative;
  bool chorus = false;
  int inverted = 0;
  MetaphorShotKind? lastKind;
  double lastAngle = -1;
}

MetaphorShot _makeShot(
  _ShotContext c,
  double start,
  double end,
  MetaphorShotKind kind,
) {
  final double chance = c.negative ? (c.chorus ? 0.34 : 0.2) : 0;
  // 先取随机数再判断：开关反相不改后面取到的数，机位不跟着变
  final double roll = c.rng();
  final bool invert = c.inverted < 2 && roll < chance;
  c.inverted = invert ? c.inverted + 1 : 0;
  c.lastKind = kind;
  double angle = _screenAngles[(c.rng() * _screenAngles.length).floor()];
  if (angle == c.lastAngle) {
    angle =
        _screenAngles[(_screenAngles.indexOf(angle) + 1) %
            _screenAngles.length];
  }
  c.lastAngle = angle;
  final (double r, double ox, double oy) = _shotPose(kind, c.rng);
  return MetaphorShot(
    start: start,
    end: end,
    kind: kind,
    roll: r,
    offsetX: ox,
    offsetY: oy,
    invert: invert,
    screenAngle: angle,
    seed: c.rng(),
  );
}

/// 切点：先按节奏均分，再吸到最近的词开唱时刻上。
List<double> metaphorPlanCuts(
  double start,
  double end,
  int count,
  List<double> onsets,
) {
  final List<double> cuts = <double>[];
  final double spacing = (end - start) / count;
  for (int index = 1; index < count; index++) {
    final double ideal = start + spacing * index;
    double near = double.infinity;
    for (final double onset in onsets) {
      if ((onset - ideal).abs() < (near - ideal).abs()) near = onset;
    }
    final double at = (near - ideal).abs() <= spacing * 0.4 ? near : ideal;
    final double previous = cuts.isNotEmpty ? cuts.last : start;
    if (at - previous >= _minShot && end - at >= _minShot) cuts.add(at);
  }
  return cuts;
}

List<MetaphorShot> _lineShots(
  _ShotContext c,
  MetaphorCue cue,
  MetaphorProgramLine line,
  double pace,
) {
  final double duration = cue.end - cue.start;
  final int count = math.max(
    1,
    math.min(7, ((duration * pace * (c.chorus ? 1.25 : 1)) / 2.6).round()),
  );
  final List<double> onsets = line.wordStarts
      .where((double t) => t > cue.start + _minShot && t < cue.end - _minShot)
      .toList();
  final List<double> edges = <double>[
    cue.start,
    ...metaphorPlanCuts(cue.start, cue.end, count, onsets),
    cue.end,
  ];
  final List<MetaphorShot> shots = <MetaphorShot>[];
  for (int index = 0; index < edges.length - 1; index++) {
    final double start = edges[index];
    final double end = edges[index + 1];
    final bool last = index == edges.length - 2;
    if (index == 0 && cue.transition == MetaphorTransition.smash) {
      shots.add(_makeShot(c, start, end, MetaphorShotKind.pushin));
      continue;
    }
    List<(MetaphorShotKind, double)> weights = index == 0
        ? _firstShot
        : _middleShot;
    // 一句的最后一个镜头够长时多半拉远
    if (last && index > 0 && end - start >= 1.4) {
      weights = _withWeight(weights, MetaphorShotKind.pullback, 5, add: false);
    }
    if (c.chorus) {
      weights = _withWeight(weights, MetaphorShotKind.macro, 1.5);
      weights = _withWeight(weights, MetaphorShotKind.dutch, 1);
    }
    shots.add(
      _makeShot(c, start, end, metaphorPick(c.rng, weights, c.lastKind)),
    );
  }
  return shots;
}

/// 权重表里改一项（没有就追加到末尾，和 JS 对象展开的顺序一致）。
List<(MetaphorShotKind, double)> _withWeight(
  List<(MetaphorShotKind, double)> weights,
  MetaphorShotKind kind,
  double value, {
  bool add = true,
}) {
  final List<(MetaphorShotKind, double)> out = <(MetaphorShotKind, double)>[];
  bool found = false;
  for (final (MetaphorShotKind k, double w) in weights) {
    if (k == kind) {
      found = true;
      out.add((k, add ? w + value : value));
    } else {
      out.add((k, w));
    }
  }
  if (!found) out.add((kind, value));
  return out;
}

List<MetaphorShot> _interludeShots(
  _ShotContext c,
  double start,
  double end,
  double pace,
) {
  final List<MetaphorShot> shots = <MetaphorShot>[];
  double at = start;
  while (end - at > 0.01) {
    final double length = _span(c.rng, 4.5, 8) / pace;
    final double next = end - (at + length) < 2.5 ? end : at + length;
    shots.add(
      _makeShot(c, at, next, metaphorPick(c.rng, _interludeShot, c.lastKind)),
    );
    at = next;
  }
  return shots;
}

MetaphorComposition _pickComposition(
  MetaphorRng rng,
  String text,
  MetaphorComposition? previous,
) {
  final List<String> chars = text
      .replaceAll(_spaces, '')
      .runes
      .map(String.fromCharCode)
      .toList();
  final double cjk =
      chars.where((String ch) => _cjk.hasMatch(ch)).length /
      math.max(1, chars.length);
  final double words = cjk > 0.5
      ? chars.length / 2
      : text.trim().split(_spaces).length.toDouble();
  return metaphorPick<MetaphorComposition>(rng, <(MetaphorComposition, double)>[
    (MetaphorComposition.block, 2),
    (MetaphorComposition.justify, words >= 3 ? 3 : 0),
    (MetaphorComposition.stair, chars.length >= 6 ? 2 : 0),
    (MetaphorComposition.hero, words >= 2 ? 2.5 : 0),
    (
      MetaphorComposition.column,
      cjk > 0.7 && chars.length >= 2 && chars.length <= 16 ? 2 : 0,
    ),
    (MetaphorComposition.scatter, words >= 3 ? 1.5 : 0),
  ], previous);
}

MetaphorTransition _pickTransition(
  MetaphorRng rng,
  bool enabled,
  bool intoChorus,
) {
  if (!enabled) return MetaphorTransition.cut;
  return intoChorus
      ? metaphorPick(rng, const <(MetaphorTransition, double)>[
          (MetaphorTransition.flood, 3),
          (MetaphorTransition.smash, 3),
          (MetaphorTransition.cut, 1.5),
        ])
      : metaphorPick(rng, const <(MetaphorTransition, double)>[
          (MetaphorTransition.cut, 5.5),
          (MetaphorTransition.flood, 1.5),
          (MetaphorTransition.smash, 1.2),
        ]);
}

/// 按开唱时间排，去掉和留下的上一句几乎同时开唱的、只有标点的。
List<MetaphorProgramLine> metaphorSungLines(List<MetaphorProgramLine> lines) {
  final List<MetaphorProgramLine> sorted =
      lines
          .where(
            (MetaphorProgramLine l) =>
                _letterOrNumber.hasMatch(l.text) && l.start.isFinite,
          )
          .toList()
        ..sort((MetaphorProgramLine a, MetaphorProgramLine b) {
          final int c = a.start.compareTo(b.start);
          return c != 0 ? c : a.lineIndex.compareTo(b.lineIndex);
        });
  final List<MetaphorProgramLine> kept = <MetaphorProgramLine>[];
  for (final MetaphorProgramLine l in sorted) {
    if (kept.isEmpty || l.start - kept.last.start >= _sameOnset) kept.add(l);
  }
  return kept;
}

/// 整首编成分镜表。没有歌词时整首是一段一段的间奏，曲名在第一段上。构图、转场、间奏切点、镜头
/// 各用自己的一串随机数：改切换快慢、开关反相或转场时，各句的构图不动。
MetaphorProgram compileMetaphorProgram(
  List<MetaphorProgramLine> lines, {
  required int seed,
  String? title,
  double cutPace = 1,
  bool negative = true,
  bool transitions = true,
  LyricVisualizerIntensity intensity = LyricVisualizerIntensity.normal,
}) {
  final MetaphorRng rng = metaphorRng('metaphor:$seed');
  final MetaphorRng composeRng = metaphorRng('metaphor:$seed:compose');
  final MetaphorRng transitionRng = metaphorRng('metaphor:$seed:transition');
  final MetaphorRng splitRng = metaphorRng('metaphor:$seed:split');
  // folia INTENSITY_PACE：平静 0.75 / 普通 1 / 激烈 1.3
  final double pace = cutPace * intensity.pick(0.75, 1, 1.3);
  final _ShotContext context = _ShotContext(rng, negative);
  final List<MetaphorCue> cues = <MetaphorCue>[];
  final String name = title?.trim() ?? '';

  void pushInterludeCue(
    double start,
    double end,
    String text, [
    double loop = 0,
  ]) {
    context.chorus = false;
    final double shotsEnd = loop > 0 ? start + loop : end;
    final MetaphorCue cue = MetaphorCue(
      lineIndex: -1,
      start: start,
      end: end,
      singStart: start,
      singEnd: end,
      composition: MetaphorComposition.block,
      transition: cues.isEmpty
          ? MetaphorTransition.cut
          : _pickTransition(transitionRng, transitions, false),
      chorus: false,
      text: text,
      loop: loop,
    );
    cue.shots = _interludeShots(context, start, shotsEnd, pace);
    cues.add(cue);
  }

  void pushInterlude(double start, double end, String text) {
    final bool endless = !end.isFinite;
    final double stop = endless ? start + _interludeHorizon : end;
    final double length = stop - start;
    final int count = length > _interludeSplit
        ? (length / _interludeSegment).round()
        : 1;
    double from = start;
    for (int index = 1; index <= count; index++) {
      final double to = index == count
          ? stop
          : start + (length * index) / count + (splitRng() - 0.5) * 6;
      pushInterludeCue(from, to, index == 1 ? text : '');
      from = to;
    }
    if (endless) pushInterludeCue(stop, double.infinity, '', _loopSeconds);
  }

  final List<MetaphorProgramLine> sung = metaphorSungLines(lines);
  if (sung.isEmpty) {
    pushInterlude(0, double.infinity, name);
    return MetaphorProgram(cues);
  }

  double cursor = 0;
  MetaphorComposition? composition;
  for (int order = 0; order < sung.length; order++) {
    final MetaphorProgramLine line = sung[order];
    final double begin = math.max(cursor, line.start - metaphorPreroll);
    if (begin - cursor >= _interludeMin ||
        (order == 0 && begin - cursor >= 1.2)) {
      pushInterlude(cursor, begin, order == 0 ? name : '');
      cursor = begin;
    }
    final double start = cursor;
    final MetaphorProgramLine? next = order + 1 < sung.length
        ? sung[order + 1]
        : null;
    final double singEnd = line.end.isFinite
        ? math.max(line.end, line.start + 0.2)
        : line.start + 0.2;
    final double hold = singEnd + metaphorTail;
    final double nextBegin = next != null
        ? next.start - metaphorPreroll
        : double.infinity;
    final double end = nextBegin - hold >= _interludeMin
        ? hold
        : math.max(nextBegin, start);
    if (end - start < _minCue) continue;
    final bool chorus = line.chorus;
    final MetaphorTransition transition = cues.isEmpty
        ? MetaphorTransition.cut
        : _pickTransition(
            transitionRng,
            transitions,
            chorus && !context.chorus,
          );
    context.chorus = chorus;
    composition = _pickComposition(composeRng, line.text, composition);
    final MetaphorCue cue = MetaphorCue(
      lineIndex: line.lineIndex,
      start: start,
      end: end,
      singStart: line.start,
      singEnd: singEnd,
      composition: composition,
      transition: transition,
      chorus: chorus,
      text: '',
      loop: 0,
    );
    cue.shots = _lineShots(context, cue, line, pace);
    cues.add(cue);
    cursor = end;
  }
  pushInterlude(cursor, double.infinity, '');
  return MetaphorProgram(cues);
}

/// time 落在哪个 cue 上（二分）；第一个 cue 之前算第一个。
int findMetaphorCue(MetaphorProgram program, double time) {
  final List<MetaphorCue> cues = program.cues;
  int low = 0;
  int high = cues.length - 1;
  while (low < high) {
    final int middle = (low + high + 1) >> 1;
    if (cues[middle].start <= time) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low;
}

/// cue 里的时间：循环的 cue 折回它的循环长度里。
double resolveMetaphorCueTime(MetaphorCue cue, double time) => cue.loop > 0
    ? cue.start + ((((time - cue.start) % cue.loop) + cue.loop) % cue.loop)
    : time;

/// cueTime 落在 cue 的哪个镜头上。
MetaphorShot findMetaphorShot(MetaphorCue cue, double cueTime) {
  final List<MetaphorShot> shots = cue.shots;
  for (int index = shots.length - 1; index > 0; index--) {
    if (shots[index].start <= cueTime) return shots[index];
  }
  return shots.first;
}
