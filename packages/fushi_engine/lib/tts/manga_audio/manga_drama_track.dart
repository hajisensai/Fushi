/// 广播剧 / 动画音轨当漫画有声成品（设计 §9 末段、实施顺序第 7 步）：没有现成文本
/// 时间表的真人音频，先 ASR，再用**有声书匹配器**（`EpubCueMatcher`，PDF 有声书按页
/// section 的同一套）把转录 cue 对到漫画的页上：一页 = 匹配器的一个 section。
///
/// 规则（逐条对应计划 `docs/specs/2026-11-18-manga-drama-track-plan.md`）：
/// - **section 的正文**：每页由若干「单元」（演出稿里会发声的行，或没有可用演出稿时的
///   OCR 块）按阅读顺序首尾相接；单元文本先用匹配器同一套归一化
///   （[AudioTextNormalizer]）归一化再拼，归一化幂等，所以匹配器给的归一化偏移就是
///   这里拼接坐标里的偏移，能精确换回单元 → 块下标。
/// - **短句不参与匹配**：归一化后不足 [kMangaDramaMinChars]（6）字的单元不进 section
///   正文，不足 6 字的转录 cue 命中也作废——太容易撞上无关的气泡。
/// - **页只往后走**：转录按时间顺序，命中页比当前页靠前的 cue 作废（不让页面往回跳）。
/// - **匹配不上的 cue 只播放不高亮**：它仍是成品里的一段音频（块列表为空），挂在当前
///   页上；音频按时间**铺满**整条音轨（cue 之间的音乐 / 效果音并进前一段），不丢声音。
/// - 同一文件里相邻、页与块都相同的段合成一段（少切文件，高亮也不闪）。
///
/// 成品与合成 / 有声书片段是同一套：[MangaRenderManifest] + `Audiobooks` / `AudioCues`
/// （每段一个文件、一条 cue），清单标 [MangaRenderManifest.continuous]——停顿已经在
/// 音频里，时间表不再插入页停留与句间停顿。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart'
    show
        AudioCue,
        AudioTextNormalizer,
        CueMatch,
        EpubCueMatcher,
        EpubSection,
        ProbeResult;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show resolveMangaLineText;
import 'package:fushi_engine/tts/manga_audio/manga_audiobook_match.dart'
    show MangaAudiobookNormalizer;
import 'package:fushi_engine/tts/render/tts_render_queue.dart'
    show TtsRenderCancelToken;

/// 归一化后不足这么多字的单元 / cue 不参与匹配（与有声书音源同一条线）。
const int kMangaDramaMinChars = 6;

/// 成品里每段的行身份前缀（不是演出稿的行，补回 / 换种子找不到它们，按「没有这句」处理）。
const String kMangaDramaLinePrefix = 'drama-';

/// 匹配的最小单元：一页上的一句（演出稿行）或一个 OCR 块。
class MangaDramaUnit {
  const MangaDramaUnit({
    required this.page,
    required this.blocks,
    required this.text,
  });

  final int page;

  /// 命中时要高亮的块下标（朗读顺序）。
  final List<int> blocks;
  final String text;
}

/// 演出稿里会发声的行 → 单元（文本按 OCR / 修正 / 手填解析，与合成同一个函数）。页越界
/// 的行跳过。
List<MangaDramaUnit> mangaDramaUnitsFromScript(
  MangaAudioScript script,
  MokuroPayload payload,
) => <MangaDramaUnit>[
  for (final MangaScriptLine line in script.audibleLines)
    if (line.page >= 0 && line.page < payload.images.length)
      MangaDramaUnit(
        page: line.page,
        blocks: line.blocks,
        text: resolveMangaLineText(line, payload.images[line.page].blocks),
      ),
];

/// 没有可用演出稿时：每个 OCR 块一个单元（块内各行直接相连），按 OCR 给的块序。
List<MangaDramaUnit> mangaDramaUnitsFromOcr(MokuroPayload payload) =>
    <MangaDramaUnit>[
      for (int page = 0; page < payload.images.length; page++)
        for (int b = 0; b < payload.images[page].blocks.length; b++)
          MangaDramaUnit(
            page: page,
            blocks: <int>[b],
            text: payload.images[page].blocks[b].lines.join(),
          ),
    ];

/// 一个参与匹配的单元在所属页 section 归一化正文里的区间 `[start, end)`。
class MangaDramaSpan {
  const MangaDramaSpan({
    required this.unit,
    required this.start,
    required this.end,
  });

  /// [MangaDramaSections.units] 的下标。
  final int unit;
  final int start;
  final int end;

  int get length => end - start;
}

/// 匹配器的输入：每页一个 section，以及换回单元用的区间表。
class MangaDramaSections {
  const MangaDramaSections({
    required this.sections,
    required this.units,
    required this.spans,
    required this.sectionStarts,
    required this.matchableUnits,
    required this.shortUnits,
  });

  /// 第 i 个 = 第 i 页（0 起），正文是归一化后的单元拼接。
  final List<EpubSection> sections;
  final List<MangaDramaUnit> units;

  /// 每页参与匹配的单元区间（页内坐标，按正文顺序）。
  final List<List<MangaDramaSpan>> spans;

  /// 各页正文在全卷拼接里的起点（长度 = 页数 + 1，末项 = 全卷长度）。
  final List<int> sectionStarts;

  /// 进了 section 正文的单元数。
  final int matchableUnits;

  /// 因为太短没进正文的单元数。
  final int shortUnits;

  int get pageCount => sections.length;
}

List<String> _defaultNormalize(List<String> texts) => texts.isEmpty
    ? const <String>[]
    : AudioTextNormalizer.normalizeBatch(texts);

/// 按页切 section。[units] 按阅读顺序（页非降序）；页越界的单元丢弃。
MangaDramaSections buildMangaDramaSections({
  required List<MangaDramaUnit> units,
  required int pageCount,
  int minChars = kMangaDramaMinChars,
  MangaAudiobookNormalizer normalize = _defaultNormalize,
}) {
  final List<String> norm = normalize(<String>[
    for (final MangaDramaUnit u in units) u.text,
  ]);
  final List<StringBuffer> texts = <StringBuffer>[
    for (int i = 0; i < pageCount; i++) StringBuffer(),
  ];
  final List<List<MangaDramaSpan>> spans = <List<MangaDramaSpan>>[
    for (int i = 0; i < pageCount; i++) <MangaDramaSpan>[],
  ];
  int matchable = 0;
  int short = 0;
  for (int i = 0; i < units.length; i++) {
    final int page = units[i].page;
    if (page < 0 || page >= pageCount) continue;
    final String t = norm[i];
    if (t.length < minChars) {
      short++;
      continue;
    }
    final StringBuffer buf = texts[page];
    spans[page].add(
      MangaDramaSpan(unit: i, start: buf.length, end: buf.length + t.length),
    );
    buf.write(t);
    matchable++;
  }
  final List<int> starts = <int>[0];
  for (final StringBuffer b in texts) {
    starts.add(starts.last + b.length);
  }
  return MangaDramaSections(
    sections: <EpubSection>[
      for (int i = 0; i < pageCount; i++)
        EpubSection(
          index: i,
          href: mangaPageHref(i),
          text: texts[i].toString(),
        ),
    ],
    units: units,
    spans: spans,
    sectionStarts: starts,
    matchableUnits: matchable,
    shortUnits: short,
  );
}

/// 一条转录 cue（第 [fileIndex] 个音频文件内的时间）。
class MangaDramaCue {
  const MangaDramaCue({
    required this.fileIndex,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int fileIndex;
  final int startMs;
  final int endMs;
  final String text;
}

/// 成品里的一段音频：第 [fileIndex] 个源文件的 `[startMs, endMs)`（[endMs] 为 null =
/// 到文件末尾）。[blocks] 为空 = 只播放不高亮。
class MangaDramaSegment {
  const MangaDramaSegment({
    required this.fileIndex,
    required this.startMs,
    required this.endMs,
    required this.page,
    required this.blocks,
    required this.text,
  });

  final int fileIndex;
  final int startMs;
  final int? endMs;
  final int page;
  final List<int> blocks;
  final String text;

  bool get highlighted => blocks.isNotEmpty;

  @override
  String toString() =>
      'MangaDramaSegment(f$fileIndex $startMs-${endMs ?? 'end'} p$page '
      '$blocks)';
}

/// 匹配统计（发起后给用户看）。
class MangaDramaStats {
  const MangaDramaStats({
    required this.cues,
    required this.matchedCues,
    required this.shortCues,
    required this.backwardCues,
    required this.matchableUnits,
    required this.shortUnits,
    required this.coveredUnits,
    required this.segments,
    required this.highlightedSegments,
  });

  /// 转录 cue 总数。
  final int cues;

  /// 对上页面并有块可高亮的 cue 数。
  final int matchedCues;

  /// 不足 6 字、不参与匹配的 cue 数。
  final int shortCues;

  /// 匹配器给了位置、但页比当前页靠前而作废的 cue 数。
  final int backwardCues;

  /// 参与匹配的单元数 / 太短的单元数 / 至少被一条 cue 高亮过的单元数。
  final int matchableUnits;
  final int shortUnits;
  final int coveredUnits;

  /// 成品段数（合并后）与其中有高亮的段数。
  final int segments;
  final int highlightedSegments;

  /// 参与匹配的单元里被音频覆盖的比例（0..1）。
  double get unitCoverage =>
      matchableUnits == 0 ? 0 : coveredUnits / matchableUnits;
}

class MangaDramaTrack {
  MangaDramaTrack({
    required List<MangaDramaSegment> segments,
    required this.stats,
  }) : segments = List<MangaDramaSegment>.unmodifiable(segments);

  /// 按文件、时间顺序；页非降序。
  final List<MangaDramaSegment> segments;
  final MangaDramaStats stats;
}

/// 一条命中 cue 的归一化区间（全卷坐标）→ 页与块。区间落在哪页的单元上最多就取哪页；
/// 该页上覆盖到单元至少 1/3、或占了区间一半的单元才算（防止相邻气泡被一两个字的
/// 漂移带进来）。一个都不够格返回 null。
({int page, List<int> blocks, Set<int> units})? _resolveRange(
  MangaDramaSections s,
  int globalStart,
  int globalEnd,
) {
  final int rangeLen = globalEnd - globalStart;
  if (rangeLen <= 0) return null;
  int bestPage = -1;
  int bestOverlap = 0;
  for (int page = 0; page < s.pageCount; page++) {
    final int base = s.sectionStarts[page];
    final int end = s.sectionStarts[page + 1];
    if (end <= globalStart) continue;
    if (base >= globalEnd) break;
    int overlap = 0;
    for (final MangaDramaSpan span in s.spans[page]) {
      overlap += _overlap(
        base + span.start,
        base + span.end,
        globalStart,
        globalEnd,
      );
    }
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      bestPage = page;
    }
  }
  if (bestPage < 0) return null;
  final int base = s.sectionStarts[bestPage];
  final List<int> blocks = <int>[];
  final Set<int> units = <int>{};
  for (final MangaDramaSpan span in s.spans[bestPage]) {
    final int o = _overlap(
      base + span.start,
      base + span.end,
      globalStart,
      globalEnd,
    );
    if (o <= 0) continue;
    if (o * 3 < span.length && o * 2 < rangeLen) continue;
    units.add(span.unit);
    for (final int b in s.units[span.unit].blocks) {
      if (!blocks.contains(b)) blocks.add(b);
    }
  }
  if (blocks.isEmpty) return null;
  return (page: bestPage, blocks: blocks, units: units);
}

int _overlap(int a0, int a1, int b0, int b1) {
  final int lo = a0 > b0 ? a0 : b0;
  final int hi = a1 < b1 ? a1 : b1;
  return hi > lo ? hi - lo : 0;
}

/// 匹配结果 → 成品分段（纯函数）。
///
/// [cues] 按文件、时间顺序；[matches] 与 [cues] 一一对应（`CueMatch.sectionIndex` =
/// 页，偏移相对该页正文、终点可越过页尾）；[cueNormLengths] 是各 cue 归一化后的长度
/// （短 cue 规则用）。长度对不上属于调用方的程序错误，抛 [ArgumentError]。
MangaDramaTrack buildMangaDramaTrack({
  required MangaDramaSections sections,
  required List<MangaDramaCue> cues,
  required List<CueMatch> matches,
  required List<int> cueNormLengths,
  int minChars = kMangaDramaMinChars,
}) {
  if (matches.length != cues.length || cueNormLengths.length != cues.length) {
    throw ArgumentError('matches / cueNormLengths must align with cues');
  }
  final List<MangaDramaSegment> raw = <MangaDramaSegment>[];
  final Set<int> covered = <int>{};
  int currentPage = 0;
  int matched = 0;
  int short = 0;
  int backward = 0;
  for (int i = 0; i < cues.length; i++) {
    final MangaDramaCue cue = cues[i];
    final CueMatch m = matches[i];
    ({int page, List<int> blocks, Set<int> units})? hit;
    if (m.matched) {
      if (cueNormLengths[i] < minChars) {
        short++;
      } else if (m.sectionIndex < sections.pageCount) {
        final int base = sections.sectionStarts[m.sectionIndex];
        hit = _resolveRange(
          sections,
          base + m.normCharStart,
          base + m.normCharEnd,
        );
        if (hit != null && hit.page < currentPage) {
          backward++;
          hit = null;
        }
      }
    } else if (cueNormLengths[i] < minChars) {
      short++;
    }
    if (hit != null) {
      matched++;
      currentPage = hit.page;
      covered.addAll(hit.units);
    }
    // 铺满音轨：本段从本条 cue 起（文件第一条从 0 起，片头音乐也播），到同一文件下一条
    // cue 的起点（最后一条到文件末尾）。
    final bool firstInFile = i == 0 || cues[i - 1].fileIndex != cue.fileIndex;
    final bool lastInFile =
        i + 1 >= cues.length || cues[i + 1].fileIndex != cue.fileIndex;
    final int start = firstInFile
        ? 0
        : (raw.isNotEmpty && raw.last.fileIndex == cue.fileIndex
              ? raw.last.endMs!
              : cue.startMs);
    int? end = lastInFile ? null : cues[i + 1].startMs;
    if (end != null && end <= start) {
      // 时间戳不递增（同起点 / 重叠的 cue）：这一条没有自己的时长，并进下一段。
      end = start;
    }
    raw.add(
      MangaDramaSegment(
        fileIndex: cue.fileIndex,
        startMs: start,
        endMs: end,
        page: hit?.page ?? currentPage,
        blocks: hit?.blocks ?? const <int>[],
        text: cue.text,
      ),
    );
  }
  final List<MangaDramaSegment> merged = _mergeSegments(raw);
  return MangaDramaTrack(
    segments: merged,
    stats: MangaDramaStats(
      cues: cues.length,
      matchedCues: matched,
      shortCues: short,
      backwardCues: backward,
      matchableUnits: sections.matchableUnits,
      shortUnits: sections.shortUnits,
      coveredUnits: covered.length,
      segments: merged.length,
      highlightedSegments: merged
          .where((MangaDramaSegment s) => s.highlighted)
          .length,
    ),
  );
}

bool _sameBlocks(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 合并：零时长段并进下一段（取下一段的页与块）；同一文件里相邻、页与块都相同的段
/// 合成一段。
List<MangaDramaSegment> _mergeSegments(List<MangaDramaSegment> raw) {
  final List<MangaDramaSegment> out = <MangaDramaSegment>[];
  MangaDramaSegment? pendingZero;
  for (final MangaDramaSegment s0 in raw) {
    MangaDramaSegment s = s0;
    if (pendingZero != null && pendingZero.fileIndex == s.fileIndex) {
      s = MangaDramaSegment(
        fileIndex: s.fileIndex,
        startMs: pendingZero.startMs,
        endMs: s.endMs,
        page: s.page,
        blocks: s.blocks,
        text: '${pendingZero.text}${s.text}',
      );
    }
    pendingZero = null;
    if (s.endMs != null && s.endMs! <= s.startMs) {
      pendingZero = s;
      continue;
    }
    final MangaDramaSegment? last = out.isEmpty ? null : out.last;
    if (last != null &&
        last.fileIndex == s.fileIndex &&
        last.page == s.page &&
        _sameBlocks(last.blocks, s.blocks)) {
      out[out.length - 1] = MangaDramaSegment(
        fileIndex: s.fileIndex,
        startMs: last.startMs,
        endMs: s.endMs,
        page: s.page,
        blocks: s.blocks,
        text: '${last.text}${s.text}',
      );
      continue;
    }
    out.add(s);
  }
  // 末尾残留的零时长段（理论上不会：文件最后一段 endMs 为 null）：丢掉，它没有声音。
  return out;
}

/// 匹配口：section 正文 + cue 文本 → 与 cue 一一对应的 [CueMatch]。生产用
/// [matchMangaDramaInBackground]（有声书匹配器，后台 isolate）。
typedef MangaDramaMatcher =
    Future<List<CueMatch>> Function(
      List<EpubSection> sections,
      List<String> cueTexts,
    );

List<AudioCue> _matcherCues(List<String> cueTexts) => <AudioCue>[
  for (int i = 0; i < cueTexts.length; i++)
    AudioCue()
      ..bookKey = ''
      ..chapterHref = ''
      ..sentenceIndex = i
      ..textFragmentId = ''
      ..text = cueTexts[i]
      ..startMs = 0
      ..endMs = 0
      ..audioFileIndex = 0,
];

List<CueMatch> _alignedMatches(int count, List<CueMatch>? matches) =>
    matches != null && matches.length == count
    ? matches
    : List<CueMatch>.filled(count, CueMatch.unmatched);

/// 生产匹配：有声书匹配器的多档窗口探测（与有声书导入同一入口），后台 isolate 里跑。
Future<List<CueMatch>> matchMangaDramaInBackground(
  List<EpubSection> sections,
  List<String> cueTexts,
) async {
  if (cueTexts.isEmpty) return const <CueMatch>[];
  final ProbeResult result = await EpubCueMatcher.probeInIsolate(
    sections: sections,
    cues: _matcherCues(cueTexts),
  );
  return _alignedMatches(cueTexts.length, result.bestResult?.matches);
}

/// 同步匹配（测试 / 小数据）：同一个匹配器，不开 isolate。
List<CueMatch> matchMangaDramaSync(
  List<EpubSection> sections,
  List<String> cueTexts,
) {
  if (cueTexts.isEmpty) return const <CueMatch>[];
  return _alignedMatches(
    cueTexts.length,
    EpubCueMatcher.match(
      sections: sections,
      cues: _matcherCues(cueTexts),
    ).matches,
  );
}

/// 转录口：一个音频文件 → 它的 cue（[MangaDramaCue.fileIndex] = [fileIndex]）。生产是
/// 应用层装配的设备端 ASR（`createAsrTranscriptionService`）；取消抛
/// `TtsRenderCancelled`。
typedef MangaDramaTranscriber =
    Future<List<MangaDramaCue>> Function(
      String audioPath,
      int fileIndex,
      TtsRenderCancelToken cancel,
    );

/// 剪辑口：从 [sourcePath] 剪 `[startMs, endMs)`（[endMs] 为 null = 到末尾）写到
/// [outputPath]，返回写出的时长（毫秒）。失败抛异常（整次失败：成品不能缺段）。
abstract interface class MangaDramaCutter {
  Future<int> cut({
    required String sourcePath,
    required int startMs,
    required int? endMs,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  });
}

enum MangaDramaPhase { transcribing, matching, cutting }

typedef MangaDramaProgress =
    void Function(MangaDramaPhase phase, int done, int total);

/// 一次制作的结果。
class MangaDramaOutcome {
  const MangaDramaOutcome({required this.manifest, required this.track});

  final MangaRenderManifest manifest;
  final MangaDramaTrack track;
}

/// 转录全部 cue 都为空（静音 / 识别不出）时抛：没有可登记的东西。
class MangaDramaEmptyTranscript implements Exception {
  const MangaDramaEmptyTranscript();

  @override
  String toString() => 'MangaDramaEmptyTranscript';
}

/// 成品段的文件名（清单目录下）。
String mangaDramaSegmentFileName(int index) =>
    'drama_${index.toString().padLeft(5, '0')}.m4a';

/// 整条流水线：逐个文件转录 → 按页 section 匹配 → 按段剪音频 → 写清单（不登记库：
/// 登记由应用层在停掉播放之后做）。清单目录里不再被引用的旧段文件会被清掉。
///
/// [audioPaths] 按播放顺序（广播剧多轨时第 1 轨在前）。[ocrSignature] 记进清单，播放 /
/// 导入核对 OCR 用。
Future<MangaDramaOutcome> runMangaDramaTrack({
  required List<MangaDramaUnit> units,
  required int pageCount,
  required String? ocrSignature,
  required List<String> audioPaths,
  required MangaDramaTranscriber transcribe,
  required MangaDramaCutter cutter,
  required File manifestFile,
  required TtsRenderCancelToken cancel,
  MangaDramaMatcher match = matchMangaDramaInBackground,
  MangaDramaProgress? onProgress,
  MangaAudiobookNormalizer normalize = _defaultNormalize,
  int minChars = kMangaDramaMinChars,
}) async {
  final List<MangaDramaCue> cues = <MangaDramaCue>[];
  for (int f = 0; f < audioPaths.length; f++) {
    cancel.throwIfCancelled();
    onProgress?.call(MangaDramaPhase.transcribing, f, audioPaths.length);
    final List<MangaDramaCue> got = await transcribe(audioPaths[f], f, cancel);
    final List<MangaDramaCue> sorted =
        <MangaDramaCue>[
          for (final MangaDramaCue c in got)
            if (c.text.trim().isNotEmpty)
              MangaDramaCue(
                fileIndex: f,
                startMs: c.startMs,
                endMs: c.endMs,
                text: c.text,
              ),
        ]..sort(
          (MangaDramaCue a, MangaDramaCue b) => a.startMs.compareTo(b.startMs),
        );
    cues.addAll(sorted);
  }
  onProgress?.call(
    MangaDramaPhase.transcribing,
    audioPaths.length,
    audioPaths.length,
  );
  if (cues.isEmpty) throw const MangaDramaEmptyTranscript();

  cancel.throwIfCancelled();
  onProgress?.call(MangaDramaPhase.matching, 0, 1);
  final MangaDramaSections sections = buildMangaDramaSections(
    units: units,
    pageCount: pageCount,
    minChars: minChars,
    normalize: normalize,
  );
  final List<String> cueTexts = <String>[
    for (final MangaDramaCue c in cues) c.text,
  ];
  final List<int> cueLengths = <int>[
    for (final String n in normalize(cueTexts)) n.length,
  ];
  final List<CueMatch> matches = sections.matchableUnits == 0
      ? List<CueMatch>.filled(cues.length, CueMatch.unmatched)
      : await match(sections.sections, cueTexts);
  final MangaDramaTrack track = buildMangaDramaTrack(
    sections: sections,
    cues: cues,
    matches: _alignedMatches(cues.length, matches),
    cueNormLengths: cueLengths,
    minChars: minChars,
  );
  onProgress?.call(MangaDramaPhase.matching, 1, 1);

  final Directory dir = manifestFile.parent;
  await dir.create(recursive: true);
  final List<MangaRenderedLine> lines = <MangaRenderedLine>[];
  for (int i = 0; i < track.segments.length; i++) {
    cancel.throwIfCancelled();
    onProgress?.call(MangaDramaPhase.cutting, i, track.segments.length);
    final MangaDramaSegment s = track.segments[i];
    final String name = mangaDramaSegmentFileName(i);
    final File target = File(p.join(dir.path, name));
    final File part = File('${target.path}.part');
    if (await part.exists()) await part.delete();
    try {
      final int ms = await cutter.cut(
        sourcePath: audioPaths[s.fileIndex],
        startMs: s.startMs,
        endMs: s.endMs,
        outputPath: part.path,
        cancel: cancel,
      );
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      lines.add(
        MangaRenderedLine(
          lineId: '$kMangaDramaLinePrefix$i',
          page: s.page,
          blocks: s.blocks,
          speaker: '',
          kind: CastLineKind.spoken,
          beatMs: 0,
          file: name,
          durationMs: ms < 0 ? 0 : ms,
          text: s.text,
        ),
      );
    } finally {
      if (await part.exists()) await part.delete();
    }
  }
  onProgress?.call(
    MangaDramaPhase.cutting,
    track.segments.length,
    track.segments.length,
  );
  final MangaRenderManifest manifest = MangaRenderManifest(
    pageCount: pageCount,
    lines: lines,
    engineSignature: ocrSignature,
    continuous: true,
  );
  await manifest.save(manifestFile);
  final Set<String> keep = <String>{
    p.basename(manifestFile.path),
    for (final MangaRenderedLine l in lines) l.file,
  };
  for (final FileSystemEntity e in dir.listSync()) {
    if (e is File && !keep.contains(p.basename(e.path))) {
      try {
        await e.delete();
      } on FileSystemException {
        // 正在被别的进程占用的旧段：留着，下次再清；不影响新成品。
      }
    }
  }
  return MangaDramaOutcome(manifest: manifest, track: track);
}
