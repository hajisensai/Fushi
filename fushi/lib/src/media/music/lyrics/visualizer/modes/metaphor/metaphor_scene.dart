/// 隐喻的运行时状态（folia `createMetaphorRuntime.ts` 里与 three.js 无关的那一半）：分镜表、
/// 每个 cue 一套东西（排版、融球规划、对撞、线稿和版面、字形图集），只留当前的和相邻的。
/// 换歌 / 换参数就地重编，画法在 `metaphor_painter.dart`。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_camera.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_figures.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_glyphs.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_shapes.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_textures.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_tuning.dart';

/// 图集里的一个字（歌词或注记）。
class MetaphorGlyphEntry {
  const MetaphorGlyphEntry({
    required this.key,
    required this.x,
    required this.y,
    required this.size,
    required this.rot,
    required this.t0,
    required this.note,
    required this.accent,
    required this.seed,
  });

  final String key;
  final double x;
  final double y;
  final double size;
  final double rot;

  /// 开唱（注记是冒出来）的时刻，秒。
  final double t0;
  final bool note;
  final bool accent;
  final double seed;
}

/// 一个 cue 的那套东西。
class MetaphorSet {
  MetaphorSet({
    required this.layout,
    required this.shapes,
    required this.collisions,
    required this.entries,
    required this.atlas,
  });

  final MetaphorLayout layout;
  final List<MetaphorShape> shapes;
  final List<MetaphorCollision> collisions;
  final List<MetaphorGlyphEntry> entries;
  final MetaphorAtlas? atlas;

  /// 线稿的矢量图缓存（手抖每秒 8 格地跳，一笔一笔冒出来），由画家维护。
  String? lineArtKey;
  ui.Picture? lineArt;

  /// 换一张线稿缓存（旧的释放）。
  void replaceLineArt(String key, ui.Picture picture) {
    lineArt?.dispose();
    lineArt = picture;
    lineArtKey = key;
  }

  void dispose() {
    atlas?.dispose();
    lineArt?.dispose();
    lineArt = null;
    lineArtKey = null;
  }
}

class MetaphorScene {
  MetaphorScene(LyricVisualizerContext context) : _context = context {
    _settings = MetaphorSettings.of(context.tuning);
    program = _compile();
  }

  LyricVisualizerContext _context;
  late MetaphorSettings _settings;
  late MetaphorProgram program;
  final Map<int, MetaphorSet> _sets = <int, MetaphorSet>{};
  final MetaphorGlyphSource glyphs = MetaphorGlyphSource();
  final MetaphorPoseTracker tracker = MetaphorPoseTracker();
  MetaphorTextures? _textures;
  bool _disposed = false;

  /// 摆线稿时用的宽高比。
  double _layoutAspect = 1.6;

  LyricVisualizerContext get context => _context;
  MetaphorSettings get settings => _settings;
  LyricVisualizerRuntime get runtime => _context.runtime;

  MetaphorTextures get textures => _textures ??= MetaphorTextures.create();

  MetaphorProgram _compile() => compileMetaphorProgram(
    <MetaphorProgramLine>[
      for (int i = 0; i < runtime.lines.length; i++)
        MetaphorProgramLine.fromRuntime(i, runtime.lines[i]),
    ],
    seed: _context.seed,
    title: _context.title,
    cutPace: _settings.cutPace,
    negative: _settings.negative,
    transitions: _settings.transitions,
  );

  /// 换输入：歌、种子、曲名、编进分镜的参数变了就重编；融球多少变了只重建各套。
  void update(LyricVisualizerContext next) {
    final LyricVisualizerContext previous = _context;
    final MetaphorSettings before = _settings;
    _context = next;
    _settings = MetaphorSettings.of(next.tuning);
    final bool songChanged =
        !identical(previous.runtime, next.runtime) ||
        previous.seed != next.seed ||
        previous.title != next.title;
    if (songChanged ||
        before.cutPace != _settings.cutPace ||
        before.negative != _settings.negative ||
        before.transitions != _settings.transitions) {
      program = _compile();
      clearSets();
    } else if (before.blobs != _settings.blobs) {
      clearSets();
    }
  }

  /// 画面比例变了不少（横竖互换）就按新的比例重摆线稿。
  void ensureAspect(double aspect) {
    if ((math.log(aspect / _layoutAspect)).abs() > 0.25) {
      _layoutAspect = aspect;
      clearSets();
    }
  }

  void clearSets() {
    for (final MetaphorSet s in _sets.values) {
      s.dispose();
    }
    _sets.clear();
  }

  /// 取（没有就建）一个 cue 的那套东西；只留它和前后相邻的。
  MetaphorSet ensureSet(int cueIndex) {
    MetaphorSet? set = _sets[cueIndex];
    if (set == null) {
      set = _buildSet(cueIndex);
      _sets[cueIndex] = set;
      final List<int> stale = <int>[
        for (final int i in _sets.keys)
          if ((i - cueIndex).abs() > 1) i,
      ];
      for (final int i in stale) {
        _sets.remove(i)?.dispose();
      }
    }
    return set;
  }

  bool hasSet(int cueIndex) => _sets.containsKey(cueIndex);

  MetaphorSet _buildSet(int cueIndex) {
    final MetaphorCue cue = program.cues[cueIndex];
    final MetaphorRng rng = metaphorRng('metaphor:${_context.seed}:$cueIndex');
    final LyricVisualizerLine? line = cue.lineIndex >= 0
        ? runtime.lines[cue.lineIndex]
        : null;
    final List<MetaphorToken> tokens = line != null
        ? buildMetaphorTokens(line)
        : cue.text.isNotEmpty
        ? buildMetaphorTextTokens(cue.text, cue.start - 10)
        : const <MetaphorToken>[];
    final MetaphorLayout layout = tokens.any((MetaphorToken t) => !t.space)
        ? buildMetaphorLayout(
            MetaphorLayoutInput(
              tokens: tokens,
              composition: cue.composition,
              measure: glyphs.measure,
              rng: rng,
            ),
          )
        : MetaphorLayout(
            composition: MetaphorComposition.block,
            glyphs: <MetaphorGlyph>[],
            words: <MetaphorWord>[],
            bounds: metaphorEmptyStage,
          );
    final bool interlude = cue.lineIndex < 0;
    final double amount = _settings.blobs;
    final List<MetaphorShape> blobs = planMetaphorShapes(
      layout.bounds,
      rng,
      amount,
      interlude,
    );
    final List<double> times = _collisionTimes(cue, layout, rng);
    final List<MetaphorCollision> collisions = planMetaphorCollisions(
      layout.bounds,
      rng,
      times,
      amount,
      interlude,
    );
    final MetaphorFigures backdrop = planMetaphorBackdrop(
      layout.bounds,
      rng,
      amount,
      interlude,
      index: cue.lineIndex + 1,
      time: cue.singStart,
    );
    final MetaphorFigures figures = planMetaphorFigures(
      layout.bounds,
      rng,
      amount,
      interlude,
      _layoutAspect,
    );
    final List<MetaphorShape> shapes = joinMetaphorShapes(<List<MetaphorShape>>[
      backdrop.shapes,
      blobs,
      figures.shapes,
    ]);
    final List<MetaphorNoteGlyph> notes = layoutMetaphorNotes(<MetaphorNote>[
      ...backdrop.notes,
      ...figures.notes,
    ], glyphs.measureNote);
    final List<MetaphorGlyphEntry> entries = <MetaphorGlyphEntry>[
      for (final MetaphorGlyph g in layout.glyphs)
        MetaphorGlyphEntry(
          key: g.char,
          x: g.x,
          y: g.y,
          size: g.size,
          rot: g.rot,
          t0: g.t0,
          note: false,
          accent: g.accent,
          seed: g.seed,
        ),
      for (final MetaphorNoteGlyph n in notes)
        MetaphorGlyphEntry(
          key: metaphorNotePrefix + n.char,
          x: n.x,
          y: n.y,
          size: n.size,
          rot: n.rot,
          t0: cue.start + n.born,
          note: true,
          accent: false,
          seed: rng(),
        ),
    ];
    return MetaphorSet(
      layout: layout,
      shapes: shapes,
      collisions: collisions,
      entries: entries,
      atlas: entries.isEmpty
          ? null
          : glyphs.buildAtlas(entries.map((MetaphorGlyphEntry e) => e.key)),
    );
  }

  /// 一个 cue 里哪几个时刻对撞：歌词是隔几个词挑一个词的开唱时刻，间奏是隔几秒一次。
  List<double> _collisionTimes(
    MetaphorCue cue,
    MetaphorLayout layout,
    MetaphorRng rng,
  ) {
    if (cue.lineIndex >= 0) {
      final List<double> onsets =
          layout.words.map((MetaphorWord w) => w.t0).toSet().toList()..sort();
      final int first = (rng() * math.min(3, onsets.length)).floor();
      final List<double> out = <double>[];
      for (int i = 0; i < onsets.length && out.length < 3; i++) {
        if (i >= first && (i - first) % 3 == 0) out.add(onsets[i]);
      }
      return out;
    }
    final List<double> times = <double>[];
    final double end = cue.loop > 0 ? cue.start + cue.loop : cue.end;
    for (
      double at = cue.start + metaphorCollisionApproach;
      at < end - metaphorCollisionLife && times.length < 12;
      at += 5 + rng() * 4
    ) {
      times.add(at);
    }
    return times;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clearSets();
    glyphs.clear();
    _textures?.dispose();
    _textures = null;
  }
}
