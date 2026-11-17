/// 漫画有声成品的播放编排（纯函数）：把 [MangaRenderManifest] 的「每句一段音频 +
/// 时间表」展开成播放器能顺序播放的条目序列。
///
/// 静音不烘焙进成品音频（设计 §2），所以页停留、`lead`、句间停顿都在这里变成独立的
/// 静音条目，与句子音频交错排进同一个播放列表。播放器的全书毫秒因此**就是**边看边听
/// 时间表的毫秒，位置流直接按 [MangaAudioPlaybackPlan.itemIndexAt] 解析当前句 / 当前页。
///
/// 纯听（阅读器不可见）不另建一张表：纯听时间表恰好等于边看边听时间表去掉「页时间」
/// 条目（[MangaAudioItemKind.lead] / [MangaAudioItemKind.pad] /
/// [MangaAudioItemKind.hold]），播放端进入这类条目时直接跳到下一条
/// （[MangaAudioPlaybackPlan.listenOnlySkipTarget]）。句间停顿（含翻页加值）两种形态
/// 都保留。这条等价关系由测试钉住。
///
/// 持久化的播放进度一律用「只数句子音频」的口径（与库里 `AudioCues` 的文件下标同源，
/// 见 `manga_audio_library.dart`），换算在 [MangaAudioPlaybackPlan.toLinePositionMs] /
/// [MangaAudioPlaybackPlan.fromLinePositionMs]：静音条目不进进度，补回一句改了时长也
/// 只影响这一句之后的毫秒，与通用有声书的换 cue 换算口径一致。
library;

import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';

/// 播放条目的种类。
enum MangaAudioItemKind {
  /// 一句的音频（占位句是一段静音文件，照样高亮）。
  line,

  /// 翻到有台词页后、第一句之前先看画面。
  lead,

  /// 句后停顿（转场基础值 + 一拍，含翻页加值）。纯听也保留。
  gap,

  /// 有台词页不足最短停留时在页尾补的静音。
  pad,

  /// 无台词页的整页停留。
  hold;

  /// 只属于「看图」的时间：纯听形态下压到 0（跳过）。
  bool get isPageTime =>
      this == MangaAudioItemKind.lead ||
      this == MangaAudioItemKind.pad ||
      this == MangaAudioItemKind.hold;
}

/// 一个播放条目：`[startMs, startMs + durationMs)`，全部条目首尾相接。
class MangaAudioItem {
  const MangaAudioItem({
    required this.kind,
    required this.page,
    required this.startMs,
    required this.durationMs,
    this.lineIndex = -1,
  });

  final MangaAudioItemKind kind;
  final int page;
  final int startMs;
  final int durationMs;

  /// [kind] 为 [MangaAudioItemKind.line] 时是 [MangaRenderManifest.lines] 的下标，
  /// 其余为 -1。
  final int lineIndex;

  int get endMs => startMs + durationMs;
  bool get isLine => kind == MangaAudioItemKind.line;

  @override
  String toString() =>
      'MangaAudioItem(${kind.name} p$page $startMs+$durationMs'
      '${isLine ? ' L$lineIndex' : ''})';
}

class MangaAudioPlaybackPlan {
  MangaAudioPlaybackPlan._({
    required this.manifest,
    required this.items,
    required this.segments,
    required this.totalMs,
    required List<int> lineItemIndex,
  }) : _lineItemIndex = lineItemIndex;

  /// 按边看边听时间表展开。[pacing] 是看图节奏倍率（只缩放页停留与 `lead`）。
  /// 时长为 0 的条目不进列表（播放器不能放 0 长度的文件）；句子音频即使 0 长度也保留，
  /// 让每一句都有自己的条目与 cue。
  factory MangaAudioPlaybackPlan.build(
    MangaRenderManifest manifest, {
    double pacing = 1.0,
    MangaTimingParams params = const MangaTimingParams(),
  }) {
    final MangaTimeline timeline = manifest.timeline(
      pacing: pacing,
      params: params,
    );
    final List<MangaAudioItem> items = <MangaAudioItem>[];
    final List<int> lineItemIndex = List<int>.filled(manifest.lines.length, -1);
    int pos = 0;
    void add(MangaAudioItemKind kind, int page, int ms, {int line = -1}) {
      if (ms <= 0 && kind != MangaAudioItemKind.line) return;
      if (kind == MangaAudioItemKind.line) lineItemIndex[line] = items.length;
      items.add(
        MangaAudioItem(
          kind: kind,
          page: page,
          startMs: pos,
          durationMs: ms < 0 ? 0 : ms,
          lineIndex: line,
        ),
      );
      pos += ms < 0 ? 0 : ms;
    }

    int line = 0;
    for (final MangaPageSegment segment in timeline.segments) {
      if (!segment.spoken) {
        add(MangaAudioItemKind.hold, segment.page, segment.durationMs);
        continue;
      }
      final int firstStart = timeline.lines[line].startMs;
      add(MangaAudioItemKind.lead, segment.page, firstStart - segment.startMs);
      int cursor = firstStart;
      while (line < manifest.lines.length &&
          manifest.lines[line].page == segment.page) {
        final MangaLineTiming timing = timeline.lines[line];
        add(
          MangaAudioItemKind.line,
          segment.page,
          timing.endMs - timing.startMs,
          line: line,
        );
        add(MangaAudioItemKind.gap, segment.page, timing.gapAfterMs);
        cursor = timing.endMs + timing.gapAfterMs;
        line++;
      }
      add(MangaAudioItemKind.pad, segment.page, segment.endMs - cursor);
    }
    assert(pos == timeline.totalMs, 'items must tile the timeline');
    return MangaAudioPlaybackPlan._(
      manifest: manifest,
      items: List<MangaAudioItem>.unmodifiable(items),
      segments: timeline.segments,
      totalMs: timeline.totalMs,
      lineItemIndex: List<int>.unmodifiable(lineItemIndex),
    );
  }

  final MangaRenderManifest manifest;
  final List<MangaAudioItem> items;

  /// 边看边听形态的页段（每页一段，首尾相接）。
  final List<MangaPageSegment> segments;
  final int totalMs;
  final List<int> _lineItemIndex;

  int get lineCount => _lineItemIndex.length;

  /// [lineIndex] 这句在 [items] 里的下标。
  int itemIndexOfLine(int lineIndex) => _lineItemIndex[lineIndex];

  /// [ms] 所在的条目下标（越界钳到首尾）；没有任何条目时 -1。
  int itemIndexAt(int ms) {
    if (items.isEmpty) return -1;
    if (ms <= 0) return 0;
    int lo = 0;
    int hi = items.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (items[mid].startMs <= ms) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    // 0 长度的句子条目与下一条同起点：落在它们上时取最后一个（真正在播的那条）。
    return lo;
  }

  /// [ms] 处正在播的句子；在静音条目里返回 null。
  int? lineIndexAt(int ms) {
    final int i = itemIndexAt(ms);
    if (i < 0) return null;
    final MangaAudioItem item = items[i];
    return item.isLine ? item.lineIndex : null;
  }

  /// [ms] 处所在的页（页段语义：句后停顿与页尾补静音都算这一页）。
  int pageAt(int ms) {
    final int i = itemIndexAt(ms);
    return i < 0 ? 0 : items[i].page;
  }

  int lineStartMs(int lineIndex) => items[_lineItemIndex[lineIndex]].startMs;

  /// 第 [page] 页页段的起点（翻到该页、`lead` 之前）。越界钳到首尾。
  int pageStartMs(int page) {
    if (segments.isEmpty) return 0;
    if (page <= segments.first.page) return segments.first.startMs;
    if (page > segments.last.page) return segments.last.startMs;
    return segments[page - segments.first.page].startMs;
  }

  /// 纯听形态下进入第 [itemIndex] 个条目时要跳到的位置：页时间条目（含连着的几个）
  /// 一并跳过，落到下一个句子 / 句间停顿的起点；末尾全是页时间时落到 [totalMs]。
  /// 不是页时间条目返回 null（照常播）。
  int? listenOnlySkipTarget(int itemIndex) {
    if (itemIndex < 0 || itemIndex >= items.length) return null;
    if (!items[itemIndex].kind.isPageTime) return null;
    int j = itemIndex;
    while (j < items.length && items[j].kind.isPageTime) {
      j++;
    }
    return j < items.length ? items[j].startMs : totalMs;
  }

  /// 下一句的起点（[ms] 在句中或句后停顿里都算「当前句之后」）；没有下一句返回 null。
  int? nextLineStartMs(int ms) {
    final int from = itemIndexAt(ms);
    for (int i = from + 1; i < items.length; i++) {
      if (items[i].isLine) return items[i].startMs;
    }
    return null;
  }

  /// 「上一句」：在一句开头 1.5 秒之后按，回到这句开头；否则到前一句开头。
  int previousLineStartMs(int ms, {int restartWindowMs = 1500}) {
    final int from = itemIndexAt(ms);
    if (from < 0) return 0;
    int current = -1;
    for (int i = from; i >= 0; i--) {
      if (items[i].isLine) {
        current = i;
        break;
      }
    }
    if (current >= 0 && ms - items[current].startMs > restartWindowMs) {
      return items[current].startMs;
    }
    for (int i = current - 1; i >= 0; i--) {
      if (items[i].isLine) return items[i].startMs;
    }
    return current >= 0 ? items[current].startMs : 0;
  }

  // ── 持久化口径换算 ────────────────────────────────────────────────────

  /// 播放毫秒 → 「只数句子音频」的毫秒（库里 cue 的全书毫秒口径）。落在静音条目里
  /// 时取下一句的开头（续播从下一句开始，而不是从一段静音中间）。
  int toLinePositionMs(int planMs) {
    final int i = itemIndexAt(planMs);
    if (i < 0) return 0;
    int base = 0;
    for (int k = 0; k < i; k++) {
      if (items[k].isLine) base += items[k].durationMs;
    }
    final MangaAudioItem item = items[i];
    if (!item.isLine) return base;
    return base + (planMs - item.startMs).clamp(0, item.durationMs);
  }

  /// [toLinePositionMs] 的逆：「只数句子音频」的毫秒 → 播放毫秒。
  int fromLinePositionMs(int lineMs) {
    if (lineMs <= 0 || _lineItemIndex.isEmpty) return 0;
    int remaining = lineMs;
    for (final int i in _lineItemIndex) {
      final MangaAudioItem item = items[i];
      if (remaining < item.durationMs) return item.startMs + remaining;
      remaining -= item.durationMs;
    }
    return totalMs;
  }

  // ── 播放器输入 ──────────────────────────────────────────────────────

  /// 与 [items] 一一对应的 cue（`audioFileIndex` = 条目下标）。句子条目的 cue 与库里
  /// 那条同形（页 href、块下标、文本），静音条目的 cue 文本为空、不带块——它们只为
  /// 让播放器从 cue 推出每个文件的时长（全书毫秒按它编码），并告诉位置流「这段在哪页」。
  List<AudioCue> cues(String bookKey) {
    final List<AudioCue> out = <AudioCue>[];
    for (int i = 0; i < items.length; i++) {
      final MangaAudioItem item = items[i];
      final MangaRenderedLine? line = item.isLine
          ? manifest.lines[item.lineIndex]
          : null;
      out.add(
        AudioCue()
          ..bookKey = bookKey
          ..chapterHref = mangaPageHref(item.page)
          ..sentenceIndex = i
          ..textFragmentId = line == null
              ? ''
              : mangaBlocksFragment(line.blocks)
          ..text = line?.text ?? ''
          ..startMs = 0
          ..endMs = item.durationMs
          ..audioFileIndex = i,
      );
    }
    return out;
  }

  /// 各条目的文件路径：句子取 [linePath]，静音取 [silencePath]（按时长去重的静音文件）。
  List<String> filePaths({
    required String Function(MangaRenderedLine line) linePath,
    required String Function(int durationMs) silencePath,
  }) => <String>[
    for (final MangaAudioItem item in items)
      item.isLine
          ? linePath(manifest.lines[item.lineIndex])
          : silencePath(item.durationMs),
  ];

  /// 需要准备的静音时长（去重）。
  Set<int> get silenceDurations => <int>{
    for (final MangaAudioItem item in items)
      if (!item.isLine) item.durationMs,
  };

  /// 播放布局身份：同一份清单 + 同一节奏倍率得到同一串。会话复用判据用它——
  /// 布局变了（补回一句、改了倍率）就必须重新加载播放列表。
  String get layoutId {
    int h = items.length;
    for (final MangaAudioItem item in items) {
      h = Object.hash(h, item.kind, item.page, item.durationMs, item.lineIndex);
    }
    for (final MangaRenderedLine line in manifest.lines) {
      h = Object.hash(h, line.file);
    }
    return 'manga:${h.toUnsigned(32).toRadixString(16)}';
  }
}
