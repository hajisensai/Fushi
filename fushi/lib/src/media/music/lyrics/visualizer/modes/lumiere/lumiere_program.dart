/// 绘光的节目单：段落 → 镜头 → 光位 → 转场（folia `lumiere/program.ts` + `lumiereProgram.ts`
/// + `paragraphStructure.ts` + `lumiereTransitions.ts` + `lumiereSeamless.ts`）。纯函数，时间单位为秒。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';

/// Fushi 的歌词行没有 songPart / isChorus，所以 chorus 只在纯数据层保留，编译时不会产出。
enum ParagraphKind { breath, verse, lift, chorus, breakKind, outro }

enum LumiereTransitionKind { lightsOut, flareCut, focusPull }

/// 一行在节目单里的最小信息（秒）。
class LumiereLine {
  const LumiereLine({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
    required this.wordCount,
  });

  factory LumiereLine.of(LyricVisualizerLine line) => LumiereLine(
    index: line.index,
    start: line.startMs / 1000,
    end: line.endMs / 1000,
    text: line.text,
    wordCount: _wordLike(line),
  );

  final int index;
  final double start;
  final double end;
  final String text;
  final int wordCount;
}

int _wordLike(LyricVisualizerLine line) {
  if (line.words.isNotEmpty) {
    return line.words
        .where((LyricVisualizerWord w) => w.text.trim().isNotEmpty)
        .length;
  }
  int count = 0;
  for (final LyricVisualizerGlyph g in line.glyphs) {
    if (!g.isSpace) count++;
  }
  return count;
}

class StructureLine {
  const StructureLine(this.line, this.renderEnd);
  final LumiereLine line;
  final double renderEnd;
}

class LumiereShot {
  const LumiereShot({
    required this.id,
    required this.kind,
    required this.lineIndices,
    required this.start,
    required this.end,
    required this.lyricEnd,
    required this.isBridge,
  });
  final String id;
  final String kind;
  final List<int> lineIndices;
  final double start;
  final double end;
  final double lyricEnd;
  final bool isBridge;
}

class LumiereTransitionOut {
  const LumiereTransitionOut(this.kind, this.start, this.end);
  final LumiereTransitionKind kind;
  final double start;
  final double end;
}

class LumiereSection {
  const LumiereSection(this.start, this.end, this.kind);
  final double start;
  final double end;
  final ParagraphKind kind;
}

class LumiereParagraph {
  const LumiereParagraph({
    required this.index,
    required this.kind,
    required this.start,
    required this.end,
    required this.lyricEnd,
    required this.lineIndices,
    required this.shots,
    required this.transitionOut,
    required this.opening,
    this.sections,
  });
  final int index;
  final ParagraphKind kind;
  final double start;
  final double end;
  final double lyricEnd;
  final List<int> lineIndices;
  final List<LumiereShot> shots;
  final LumiereTransitionOut? transitionOut;
  final bool opening;
  final List<LumiereSection>? sections;
}

class LumiereProgram {
  const LumiereProgram({
    required this.seed,
    required this.instrumental,
    required this.gapThreshold,
    required this.duration,
    required this.lyricEnd,
    required this.paragraphs,
  });
  final String seed;
  final bool instrumental;
  final double gapThreshold;
  final double duration;
  final double? lyricEnd;
  final List<LumiereParagraph> paragraphs;

  int paragraphIndexAt(double time) {
    for (int i = paragraphs.length - 1; i >= 0; i--) {
      if (time >= paragraphs[i].start) return i;
    }
    return 0;
  }
}

// ---------------------------------------------------------------------------
// 段落结构
// ---------------------------------------------------------------------------

const double kGapMultiplier = 2.5;
const double kGapMin = 1.25;
const double kGapMax = 3.5;
const int kParagraphMaxLines = 6;
const double kParagraphMaxDuration = 18;

double _median(List<double> values) {
  if (values.isEmpty) return 0.5;
  final List<double> s = List<double>.of(values)..sort();
  final int m = s.length ~/ 2;
  return s.length.isEven ? (s[m - 1] + s[m]) / 2 : s[m];
}

List<StructureLine> buildStructureLines(List<LumiereLine> lines) =>
    <StructureLine>[
      for (int i = 0; i < lines.length; i++)
        StructureLine(
          lines[i],
          math.max(
            lines[i].start,
            math.min(
              lines[i].end,
              i + 1 < lines.length ? lines[i + 1].start : double.infinity,
            ),
          ),
        ),
    ];

double resolveParagraphGapThreshold(List<LumiereLine> lines) {
  final List<double> gaps = <double>[
    for (int i = 1; i < lines.length; i++)
      lines[i].start - math.min(lines[i - 1].end, lines[i].start),
  ].where((double g) => g > 0).toList();
  return (_median(gaps) * kGapMultiplier).clamp(kGapMin, kGapMax);
}

List<List<StructureLine>> _splitOversized(List<StructureLine> draft) {
  final List<List<StructureLine>> output = <List<StructureLine>>[];
  List<StructureLine> remaining = draft;
  int guard = 0;
  while (remaining.length > kParagraphMaxLines ||
      (remaining.length > 1 &&
          remaining.last.renderEnd - remaining.first.line.start >
              kParagraphMaxDuration)) {
    if (guard++ > 1000) break;
    int? best;
    double bestGap = -double.infinity;
    for (int i = 2; i < remaining.length - 1; i++) {
      final double gap = remaining[i].line.start - remaining[i - 1].renderEnd;
      if (gap > bestGap) {
        bestGap = gap;
        best = i;
      }
    }
    final int split = math.max(1, best ?? math.min(4, remaining.length - 1));
    output.addAll(_splitOversized(remaining.sublist(0, split)));
    remaining = remaining.sublist(split);
  }
  output.add(remaining);
  return output;
}

List<List<StructureLine>> draftParagraphs(
  List<StructureLine> lines,
  double threshold,
) {
  final List<List<StructureLine>> drafts = <List<StructureLine>>[];
  List<StructureLine> current = <StructureLine>[];
  for (int i = 0; i < lines.length; i++) {
    if (i > 0 &&
        lines[i].line.start - lines[i - 1].renderEnd >= threshold &&
        current.isNotEmpty) {
      drafts.addAll(_splitOversized(current));
      current = <StructureLine>[];
    }
    current.add(lines[i]);
  }
  if (current.isNotEmpty) drafts.addAll(_splitOversized(current));
  return drafts;
}

final RegExp _excited = RegExp('[!?！？…]');

ParagraphKind classifyParagraph(
  List<StructureLine> lines,
  int index,
  int total,
) {
  if (index == total - 1) return ParagraphKind.outro;
  final double duration = lines.last.renderEnd - lines.first.line.start;
  final int segments = lines.fold(
    0,
    (int sum, StructureLine l) => sum + l.line.wordCount,
  );
  final int punctuation = lines.fold(
    0,
    (int sum, StructureLine l) => sum + _excited.allMatches(l.line.text).length,
  );
  if (duration <= 3.5 || segments <= 3) return ParagraphKind.breath;
  if (punctuation >= 2 || segments / math.max(duration, 1) > 2.5) {
    return ParagraphKind.lift;
  }
  return ParagraphKind.verse;
}

// ---------------------------------------------------------------------------
// 镜头与选光位
// ---------------------------------------------------------------------------

const double kMaxShotDuration = 7;
const int kMaxLinesPerShot = 2;
const double kLongLine = 3.6;
const double kBridgeGap = 4;
const int _recent = 3;
const List<String> _bridgeFamilies = <String>['motes', 'astral', 'zenith'];
const double kReopenGap = 2.5;
const double _instrumentalDuration = 480;
const double _instrumentalParagraph = 32;
const double _bridgeShot = 10;
const double _bridgeSplit = 16;

List<LumiereMood>? _moodsOf(ParagraphKind kind) => switch (kind) {
  ParagraphKind.chorus || ParagraphKind.lift => const <LumiereMood>[
    LumiereMood.loud,
    LumiereMood.neutral,
  ],
  ParagraphKind.verse || ParagraphKind.breath => const <LumiereMood>[
    LumiereMood.quiet,
    LumiereMood.neutral,
  ],
  ParagraphKind.outro => const <LumiereMood>[LumiereMood.quiet],
  ParagraphKind.breakKind => null,
};

List<List<StructureLine>> groupLines(List<StructureLine> lines) {
  final List<List<StructureLine>> groups = <List<StructureLine>>[];
  for (final StructureLine line in lines) {
    final double duration = line.renderEnd - line.line.start;
    final List<StructureLine>? last = groups.isEmpty ? null : groups.last;
    final double lastStart = last?.first.line.start ?? 0;
    final bool lastLong =
        last == null ||
        (last.length == 1 && last.first.renderEnd - lastStart >= kLongLine);
    if (last != null &&
        !lastLong &&
        duration < kLongLine &&
        last.length < kMaxLinesPerShot &&
        line.renderEnd - lastStart <= kMaxShotDuration) {
      last.add(line);
    } else {
      groups.add(<StructureLine>[line]);
    }
  }
  return groups;
}

class PlannedShot {
  const PlannedShot(
    this.lines,
    this.start,
    this.end,
    this.lyricEnd,
    this.isBridge,
  );
  final List<StructureLine> lines;
  final double start;
  final double end;
  final double lyricEnd;
  final bool isBridge;
}

List<PlannedShot> planShots(
  List<StructureLine> lines,
  double paragraphStart,
  double paragraphEnd,
) {
  final List<List<StructureLine>> groups = groupLines(lines);
  final List<PlannedShot> shots = <PlannedShot>[];
  for (int i = 0; i < groups.length; i++) {
    final List<StructureLine> g = groups[i];
    final double start = i == 0
        ? math.min(paragraphStart, g.first.line.start)
        : g.first.line.start;
    final double lyricEnd = g
        .map((StructureLine l) => l.renderEnd)
        .reduce(math.max);
    final double nextStart = i + 1 < groups.length
        ? groups[i + 1].first.line.start
        : paragraphEnd;
    if (nextStart - lyricEnd >= kBridgeGap) {
      final double end = lyricEnd + 0.6;
      shots.add(PlannedShot(g, start, end, lyricEnd, false));
      shots.add(
        PlannedShot(const <StructureLine>[], end, nextStart, nextStart, true),
      );
    } else {
      shots.add(
        PlannedShot(
          g,
          start,
          math.max(nextStart, lyricEnd),
          math.min(lyricEnd, nextStart),
          false,
        ),
      );
    }
  }
  if (groups.isEmpty && paragraphEnd > paragraphStart) {
    shots.add(
      PlannedShot(
        const <StructureLine>[],
        paragraphStart,
        paragraphEnd,
        paragraphEnd,
        true,
      ),
    );
  }
  return shots;
}

List<PlannedShot> _splitLongBridges(List<PlannedShot> shots) => <PlannedShot>[
  for (final PlannedShot shot in shots)
    if (!shot.isBridge || shot.end - shot.start <= _bridgeSplit)
      shot
    else
      ...() {
        final double length = shot.end - shot.start;
        final int count = math.max(2, (length / _bridgeShot).round());
        return <PlannedShot>[
          for (int i = 0; i < count; i++)
            PlannedShot(
              const <StructureLine>[],
              shot.start + length * i / count,
              i == count - 1 ? shot.end : shot.start + length * (i + 1) / count,
              i == count - 1 ? shot.end : shot.start + length * (i + 1) / count,
              true,
            ),
        ];
      }(),
];

class LumiereChain {
  List<String> recent = <String>[];
  String? family;

  void advance(String kind) {
    recent = <String>[...recent, kind];
    if (recent.length > _recent) {
      recent = recent.sublist(recent.length - _recent);
    }
    family = profileOf(kind).family;
  }
}

String castShot({
  required String seed,
  required int paragraphIndex,
  required int shotIndex,
  required ParagraphKind kind,
  required bool isBridge,
  required LumiereChain chain,
}) {
  List<String> candidates = lumiereKinds;
  void narrow(bool Function(String kind) keep, [int atLeast = 1]) {
    final List<String> next = candidates.where(keep).toList();
    if (next.length >= atLeast) candidates = next;
  }

  final List<LumiereMood>? moods = _moodsOf(kind);
  if (isBridge) {
    narrow(
      (String k) =>
          _bridgeFamilies.contains(profileOf(k).family) &&
          profileOf(k).mood != LumiereMood.loud,
    );
  }
  if (moods != null) narrow((String k) => moods.contains(profileOf(k).mood));
  narrow((String k) => !chain.recent.contains(k));
  final String? family = chain.family;
  if (family != null) narrow((String k) => profileOf(k).family != family, 3);
  final LumiereRng random = lumiereRng('$seed:$paragraphIndex:$shotIndex:cast');
  return candidates[(random() * candidates.length).floor().clamp(
    0,
    candidates.length - 1,
  )];
}

// ---------------------------------------------------------------------------
// 转场
// ---------------------------------------------------------------------------

class LumiereTransitionFrame {
  const LumiereTransitionFrame(this.alpha, this.scale, this.blur);
  static const LumiereTransitionFrame identity = LumiereTransitionFrame(
    1,
    1,
    0,
  );
  final double alpha;
  final double scale;

  /// 模糊强度（逻辑像素）。
  final double blur;
}

double transitionDuration(LumiereTransitionKind kind, double gap) =>
    kind == LumiereTransitionKind.focusPull
    ? math.min(0.6, math.max(0.35, gap > 0 ? gap * 0.5 : 0.45))
    : math.min(1.1, math.max(0.5, gap > 0 ? gap * 0.6 : 0.8));

double transitionEnterDuration(
  LumiereTransitionKind kind,
  double start,
  double end,
) {
  final (double lo, double hi) = kind == LumiereTransitionKind.focusPull
      ? (0.3, 0.6)
      : (0.4, 0.9);
  return math.max(lo, math.min(hi, end - start));
}

/// exit：0 → 1 走向边界；enter：0 → 1 离开边界。
LumiereTransitionFrame transitionFrame(
  LumiereTransitionKind kind, {
  required bool exit,
  required double progress,
}) {
  final double near = exit ? smooth(progress) : 1 - smooth(progress);
  return switch (kind) {
    LumiereTransitionKind.lightsOut => LumiereTransitionFrame(1 - near, 1, 0),
    LumiereTransitionKind.flareCut => LumiereTransitionFrame(
      1 - 0.35 * near * near,
      1 + 0.03 * near,
      7 * near * near,
    ),
    LumiereTransitionKind.focusPull => LumiereTransitionFrame(
      1,
      1 + 0.015 * near,
      12 * near,
    ),
  };
}

const Map<LumiereTransitionKind, String> _transitionNames =
    <LumiereTransitionKind, String>{
      LumiereTransitionKind.lightsOut: 'lights-out',
      LumiereTransitionKind.flareCut: 'flare-cut',
      LumiereTransitionKind.focusPull: 'focus-pull',
    };

/// 不与上一次相同，按 (seed, 段落序号) 的 31 进制散列确定（与 folia 的 `(h*31+c)|0` 一致）。
LumiereTransitionKind chooseTransition(
  String seed,
  int paragraphIndex,
  LumiereTransitionKind? previous,
) {
  final List<LumiereTransitionKind> choices = LumiereTransitionKind.values
      .where((LumiereTransitionKind k) => k != previous)
      .toList();
  int hash = 0;
  for (final int c in '$seed:$paragraphIndex:transition'.codeUnits) {
    hash = (hash * 31 + c).toSigned(32);
  }
  return choices[hash.abs() % choices.length];
}

String transitionName(LumiereTransitionKind kind) => _transitionNames[kind]!;

// ---------------------------------------------------------------------------
// 编译
// ---------------------------------------------------------------------------

class _Plan {
  const _Plan(this.lines, this.kind, this.start, this.end, this.lyricEnd);
  final List<StructureLine> lines;
  final ParagraphKind kind;
  final double start;
  final double end;
  final double lyricEnd;
}

/// 编译整首歌。duration 为歌曲时长（秒，未知给 null）；seamless 把整首并成一个单元（轨迹过渡）。
LumiereProgram compileLumiereProgram(
  List<LumiereLine> lines,
  String seed, {
  double? duration,
  bool seamless = true,
}) {
  final bool instrumental = lines.isEmpty;
  final List<_Plan> plans = <_Plan>[];
  double gapThreshold = 0;
  double programEnd;
  double? lyricEnd;
  if (!instrumental) {
    final List<StructureLine> structure = buildStructureLines(lines);
    gapThreshold = resolveParagraphGapThreshold(lines);
    final List<List<StructureLine>> drafts = draftParagraphs(
      structure,
      gapThreshold,
    );
    lyricEnd = structure.map((StructureLine l) => l.renderEnd).reduce(math.max);
    programEnd = math.max(lyricEnd, duration ?? 0);
    final double firstStart = structure.first.line.start;
    final bool intro = firstStart >= kBridgeGap;
    if (intro) {
      plans.add(
        _Plan(
          const <StructureLine>[],
          ParagraphKind.breakKind,
          0,
          firstStart,
          firstStart,
        ),
      );
    }
    for (int i = 0; i < drafts.length; i++) {
      final List<StructureLine> d = drafts[i];
      plans.add(
        _Plan(
          d,
          classifyParagraph(d, i, drafts.length),
          i == 0 && !intro ? math.min(0, firstStart) : d.first.line.start,
          i + 1 < drafts.length ? drafts[i + 1].first.line.start : programEnd,
          d.last.renderEnd,
        ),
      );
    }
  } else {
    programEnd = math.max(
      1,
      duration != null && duration > 0 ? duration : _instrumentalDuration,
    );
    final int count = math.max(
      1,
      (programEnd / _instrumentalParagraph).round(),
    );
    for (int i = 0; i < count; i++) {
      final double s = programEnd * i / count;
      final double e = i == count - 1
          ? programEnd
          : programEnd * (i + 1) / count;
      plans.add(
        _Plan(const <StructureLine>[], ParagraphKind.breakKind, s, e, e),
      );
    }
  }

  final LumiereChain chain = LumiereChain();
  LumiereTransitionKind? previousTransition;
  final List<LumiereParagraph> paragraphs = <LumiereParagraph>[];
  for (int index = 0; index < plans.length; index++) {
    final _Plan plan = plans[index];
    final List<PlannedShot> planned = _splitLongBridges(
      planShots(plan.lines, plan.start, plan.end),
    );
    final List<LumiereShot> shots = <LumiereShot>[];
    for (int s = 0; s < planned.length; s++) {
      final PlannedShot shot = planned[s];
      final String kind = castShot(
        seed: seed,
        paragraphIndex: index,
        shotIndex: s,
        kind: plan.kind,
        isBridge: shot.isBridge,
        chain: chain,
      );
      chain.advance(kind);
      shots.add(
        LumiereShot(
          id: 'p$index-lu$s',
          kind: kind,
          lineIndices: <int>[
            for (final StructureLine l in shot.lines) l.line.index,
          ],
          start: shot.start,
          end: shot.end,
          lyricEnd: shot.lyricEnd,
          isBridge: shot.isBridge,
        ),
      );
    }
    LumiereTransitionOut? out;
    if (index + 1 < plans.length) {
      final LumiereTransitionKind kind = chooseTransition(
        seed,
        index,
        previousTransition,
      );
      previousTransition = kind;
      final double gap = plans[index + 1].start - plan.lyricEnd;
      out = LumiereTransitionOut(
        kind,
        math.max(plan.start, plan.end - transitionDuration(kind, gap)),
        plan.end,
      );
    }
    final bool opening =
        index == 0 || plan.start - plans[index - 1].lyricEnd >= kReopenGap;
    paragraphs.add(
      LumiereParagraph(
        index: index,
        kind: plan.kind,
        start: plan.start,
        end: plan.end,
        lyricEnd: plan.lyricEnd,
        lineIndices: <int>[
          for (final StructureLine l in plan.lines) l.line.index,
        ],
        shots: shots,
        transitionOut: out,
        opening: opening,
      ),
    );
  }

  return LumiereProgram(
    seed: seed,
    instrumental: instrumental,
    gapThreshold: gapThreshold,
    duration: programEnd,
    lyricEnd: lyricEnd,
    paragraphs: seamless ? mergeParagraphs(paragraphs) : paragraphs,
  );
}

/// 轨迹过渡：首尾相接的段落并成一个单元（少于两段原样返回）。
List<LumiereParagraph> mergeParagraphs(List<LumiereParagraph> paragraphs) {
  if (paragraphs.length < 2) return paragraphs;
  return <LumiereParagraph>[
    LumiereParagraph(
      index: 0,
      kind: paragraphs.first.kind,
      start: paragraphs.first.start,
      end: paragraphs.last.end,
      lyricEnd: paragraphs.last.lyricEnd,
      lineIndices: <int>[
        for (final LumiereParagraph p in paragraphs) ...p.lineIndices,
      ],
      shots: <LumiereShot>[
        for (final LumiereParagraph p in paragraphs) ...p.shots,
      ],
      transitionOut: null,
      opening: paragraphs.first.opening,
      sections: <LumiereSection>[
        for (final LumiereParagraph p in paragraphs)
          LumiereSection(p.start, p.end, p.kind),
      ],
    ),
  ];
}
