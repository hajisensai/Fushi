// 有声书转录 cue 后处理回归向量的确定性输入（只依赖 dart:core / dart:typed_data）。
//
// 与上游 hajisensai/fushi-subtitles `packages/asr_subtitles/test/cue_post/
// cue_post_vector_inputs.dart` 同一份（逐字复制）。本仓只用 `postCases()`：
// asr_cue_post_host_vectors_test.dart 拿它核对 AudioCue / MatchResult 适配层
// （fixtures/asr_cue_post_vectors.json，带 token 数与匹配区间）。上游的两份冻结向量
// （test/fixtures/cue_post_vectors.json）同样由搬迁前 Fushi 里的实现对这里生成的输入算出：
// - `snap`：Fushi `fushi_compute` 的 `ffc_signal_cue_energy_snap` / `_refine_edges`
//   （再往前是纯 Dart 的 CueEnergySnapper），只跑吸附 / 修边；
// - `pipeline`：Fushi hajisensai/fushi#2491 的整条链（CueEnergySnapper.snap →
//   refineEdges → CueFragmentMerger.merge → CueDisplayMargins.apply）。
// 改这里的任何一个数字都会让向量作废——只能追加新用例，不能改旧用例。
library;

import 'dart:typed_data';

/// splitmix64：跨平台确定（Dart VM 的 int 是 64 位补码，乘法按 2^64 回绕）。
final class VectorRng {
  VectorRng(this._state);

  int _state;

  int nextU64() {
    _state = _state + 0x9E3779B97F4A7C15;
    int z = _state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// [0, bound)。
  int nextInt(int bound) => (nextU64() >>> 1) % bound;
}

// ── 只吸附 / 修边（Fushi signal_vector_inputs.dart 原样搬来） ─────────────────

/// 一条 cue 的最小表示。
typedef SnapCue = ({
  int startMs,
  int endMs,
  int audioFileIndex,
  List<int>? offsetsMs,
});

/// 吸附参数（生成冻结向量时还没有 cutBiasMs，测试按 0 传）。
typedef SnapParams = ({
  int frameMs,
  int maxGapMs,
  int windowMs,
  int minValleyMs,
  double distancePenalty,
  int tailMs,
  int leadMs,
  int minDurationMs,
  double floorMarginDb,
  double minThresholdDb,
  double maxThresholdDb,
  int tokenGuardMs,
  int edgeMaxShiftMs,
  int edgeMinVoiceMs,
  int edgeLeadMs,
  int edgeTailMs,
});

const SnapParams defaultSnapParams = (
  frameMs: 20,
  maxGapMs: 400,
  windowMs: 600,
  minValleyMs: 120,
  distancePenalty: 0.5,
  tailMs: 80,
  leadMs: 40,
  minDurationMs: 500,
  floorMarginDb: 16,
  minThresholdDb: -50,
  maxThresholdDb: -30,
  tokenGuardMs: 200,
  edgeMaxShiftMs: 600,
  edgeMinVoiceMs: 60,
  edgeLeadMs: 150,
  edgeTailMs: 80,
);

typedef SnapCase = ({
  String id,
  Int8List energy,
  List<SnapCue> cues,
  SnapParams params,
});

/// 整本书样的输入：[frames] 帧包络（语音 −30..−8、停顿 −72..−45、偶发未知 0），
/// cue 按语音段切、相邻 cue 有紧挨 / 小空隙 / 大空隙 / 重叠 / 跨文件几种关系。
SnapCase _bookCase(String id, int seed, int frames, SnapParams params) {
  final VectorRng rng = VectorRng(seed);
  final Int8List energy = Int8List(frames);
  // 噪声底随位置漂（局部门限分块有意义）。
  int f = 0;
  final List<(int, int)> speech = <(int, int)>[];
  while (f < frames) {
    final int on = 30 + rng.nextInt(400);
    final int start = f;
    for (int k = f; k < f + on && k < frames; k++) {
      energy[k] = -30 + rng.nextInt(23);
      // 塞音闭塞：几帧低能量。
      if (rng.nextInt(60) == 0) energy[k] = -65;
    }
    f += on;
    speech.add((start, f < frames ? f : frames));
    final int off = rng.nextInt(5) == 0
        ? 1 + rng.nextInt(4)
        : 4 + rng.nextInt(40);
    final int floorDb = -72 + ((f ~/ 5000) % 4) * 6;
    for (int k = f; k < f + off && k < frames; k++) {
      energy[k] = floorDb + rng.nextInt(10);
    }
    f += off;
  }
  for (int k = 0; k < frames ~/ 200; k++) {
    final int at = rng.nextInt(frames);
    for (int j = at; j < at + 1 + rng.nextInt(30) && j < frames; j++) {
      energy[j] = 0;
    }
  }
  final List<SnapCue> cues = <SnapCue>[];
  final int fm = params.frameMs;
  int fileIndex = 0;
  for (int s = 0; s < speech.length; s++) {
    final (int a, int b) = speech[s];
    int start = a * fm + (rng.nextInt(400) - 200);
    int end = b * fm + (rng.nextInt(400) - 200);
    // 紧挨：把一部分 cue 的终点拉到下一段起点附近（切点落在停顿中间）。
    if (s + 1 < speech.length && rng.nextInt(2) == 0) {
      final int next = speech[s + 1].$1 * fm;
      end = (end + next) ~/ 2 + rng.nextInt(120) - 60;
    }
    if (end <= start) end = start + 300 + rng.nextInt(800);
    if (rng.nextInt(97) == 0) fileIndex++;
    List<int>? offsets;
    final int kind = rng.nextInt(6);
    if (kind == 0) {
      offsets = null;
    } else if (kind == 1) {
      offsets = <int>[];
    } else {
      final int count = 1 + rng.nextInt(8);
      offsets = <int>[];
      int o = rng.nextInt(300) - 50;
      for (int t = 0; t < count; t++) {
        offsets.add(o);
        o += rng.nextInt((end - start) ~/ count + 1);
      }
    }
    cues.add((
      startMs: start,
      endMs: end,
      audioFileIndex: fileIndex,
      offsetsMs: offsets,
    ));
    // 紧挨的下一条：起点 = 本条终点 + 0..120。
    if (s + 1 < speech.length && rng.nextInt(3) == 0) {
      final int gap = rng.nextInt(5) == 0
          ? 450 + rng.nextInt(300)
          : rng.nextInt(120);
      final int ns = end + gap - (rng.nextInt(10) == 0 ? 200 : 0);
      speech[s + 1] = ((ns ~/ fm).clamp(0, frames - 1), speech[s + 1].$2);
    }
  }
  return (id: id, energy: energy, cues: cues, params: params);
}

List<SnapCase> snapCases() {
  final SnapParams coarse = (
    frameMs: 40,
    maxGapMs: 250,
    windowMs: 900,
    minValleyMs: 100,
    distancePenalty: 1.25,
    tailMs: 60,
    leadMs: 70,
    minDurationMs: 300,
    floorMarginDb: 12.5,
    minThresholdDb: -55,
    maxThresholdDb: -25,
    tokenGuardMs: 120,
    edgeMaxShiftMs: 400,
    edgeMinVoiceMs: 100,
    edgeLeadMs: 90,
    edgeTailMs: 50,
  );
  return <SnapCase>[
    (
      id: 'empty-energy',
      energy: Int8List(0),
      cues: <SnapCue>[
        (startMs: 0, endMs: 1000, audioFileIndex: 0, offsetsMs: null),
        (startMs: 1000, endMs: 3000, audioFileIndex: 0, offsetsMs: null),
      ],
      params: defaultSnapParams,
    ),
    (
      id: 'no-cues',
      energy: Int8List(100),
      cues: <SnapCue>[],
      params: defaultSnapParams,
    ),
    (
      id: 'all-unknown',
      energy: Int8List(300),
      cues: <SnapCue>[
        (startMs: 0, endMs: 2000, audioFileIndex: 0, offsetsMs: <int>[10]),
        (
          startMs: 2000,
          endMs: 5000,
          audioFileIndex: 0,
          offsetsMs: <int>[5, 900],
        ),
      ],
      params: defaultSnapParams,
    ),
    _bookCase('book-30min', 1101, 90000, defaultSnapParams),
    _bookCase('book-short', 1102, 4000, defaultSnapParams),
    _bookCase('book-coarse-params', 1103, 40000, coarse),
  ];
}

// ── 整条链（吸附 → 修边 → 合并 → 余量，默认参数） ─────────────────────────────

/// 一条带正文与匹配信息的 cue。
typedef PostCue = ({
  int startMs,
  int endMs,
  int audioFileIndex,
  List<int>? offsetsMs,
  String text,
  int sectionIndex,
  int normCharStart,
  int normCharEnd,
});

typedef PostCase = ({String id, Int8List energy, List<PostCue> cues});

const List<String> _bodies = <String>[
  '何か',
  'おかしい',
  'そうだね',
  '雪ノ下は言った',
  'だが',
  '比企谷くん',
  'ＡＢＣ',
  'それは',
  '「待って',
  'ああ',
  '𠮷野家に行く',
  '一二三四五六七八九十一二三四五六七八九十',
  '彼女は窓の外を見ていた',
  'Ｍｓ',
  'Mr',
  '三',
  'ﾊﾟｰﾃｨｰ',
];

const List<String> _endings = <String>[
  '、',
  '。',
  '──',
  '……',
  '」',
  '！',
  '?',
  '．',
  '.',
  ' ',
  '　',
  '）',
  '』',
  '',
  '、　',
];

/// [_bookCase] 的时间轴 + 文本 / 匹配：多数 cue 命中且区间首尾相接，偶有未命中、
/// 换章、区间断开；文本结尾覆盖句末 / 非句末 / 缩写 / 空白各种情形。
PostCase _postCase(String id, int seed, int frames) {
  final SnapCase base = _bookCase(id, seed, frames, defaultSnapParams);
  final VectorRng rng = VectorRng(seed * 31 + 7);
  final List<PostCue> cues = <PostCue>[];
  int section = 0;
  int norm = 0;
  for (final SnapCue c in base.cues) {
    // 一部分 cue 截短到 0.3~1.1 s，让「任一侧短于 1.2 s」常成立。
    int end = c.endMs;
    if (rng.nextInt(3) == 0) {
      end = c.startMs + 300 + rng.nextInt(800);
    }
    if (end <= c.startMs) end = c.startMs + 300;
    final String text = rng.nextInt(25) == 0
        ? ' '
        : _bodies[rng.nextInt(_bodies.length)] +
              _endings[rng.nextInt(_endings.length)];
    final int kind = rng.nextInt(20);
    int sec = section;
    int ns = norm;
    if (kind == 0) {
      sec = -1;
    } else if (kind == 1) {
      section++;
      sec = section;
      norm = 0;
      ns = 0;
    } else if (kind == 2) {
      ns = norm + 1 + rng.nextInt(5);
    }
    final int ne = sec < 0 ? -1 : ns + text.length;
    if (sec >= 0) norm = ne;
    cues.add((
      startMs: c.startMs,
      endMs: end,
      audioFileIndex: c.audioFileIndex,
      offsetsMs: c.offsetsMs,
      text: text,
      sectionIndex: sec,
      normCharStart: sec < 0 ? -1 : ns,
      normCharEnd: ne,
    ));
  }
  return (id: id, energy: base.energy, cues: cues);
}

List<PostCase> postCases() {
  PostCue c(int s, int e, String text, int ns, {List<int>? offsets}) => (
    startMs: s,
    endMs: e,
    audioFileIndex: 0,
    offsetsMs: offsets,
    text: text,
    sectionIndex: 0,
    normCharStart: ns,
    normCharEnd: ns + text.length,
  );
  // 手工：两段有声 [1000, 3000) 与 [3500, 5600)，其余静音。
  final Int8List twoLines = Int8List(450)..fillRange(0, 450, -70);
  twoLines.fillRange(50, 150, -20);
  twoLines.fillRange(175, 280, -20);
  return <PostCase>[
    (
      id: 'fragment-no-energy',
      energy: Int8List(0),
      cues: <PostCue>[
        c(0, 500, '何か、', 0, offsets: <int>[0, 200]),
        c(700, 2500, 'おかしい。', 3, offsets: <int>[30, 900]),
        c(2600, 4000, '次の文。', 8),
      ],
    ),
    (
      id: 'two-lines-with-energy',
      energy: twoLines,
      cues: <PostCue>[
        c(1000, 1600, 'それは、', 0, offsets: <int>[0, 300]),
        c(1650, 3000, 'つまり。', 4, offsets: <int>[10, 500]),
        c(3500, 5600, '彼女は窓の外を見ていた。', 8, offsets: <int>[]),
      ],
    ),
    _postCase('post-book-20min', 2201, 60000),
    _postCase('post-book-short', 2202, 5000),
  ];
}
