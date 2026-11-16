/// S2e 缺口补齐（spec §3）：同语言证据里识别稿没覆盖到的台词插回字幕稿。
///
/// 识别漏掉的通常是小声 / 叠着 BGM / 多人抢话的台词；身边的日语字幕（人工或 OCR）
/// 恰好有它们。插入的行带 [SubtitleDraftCue.origin]（证据轨标签），S3 照常校对。
/// 确定性、不需要 AI：AI 关闭时也补。
library;

import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_song_lyrics.dart'
    show lyricsBigramDice;

/// 证据行被识别稿覆盖的比例低于它，才算识别漏掉的行。
const double kSubtitleEvidenceGapMaxCoverage = 0.2;

/// 太短的证据行（OCR 抖出的碎片、单个感叹）不补。
const int kSubtitleEvidenceGapMinMs = 400;

/// 把 [index] 的同语言台词证据里没被 [drafts] 覆盖的行插进去，按开始时间返回新稿。
/// 人工字幕轨先补，OCR 轨只补人工轨也没覆盖的。
List<SubtitleDraftCue> fillSubtitleGapsFromEvidence(
  List<SubtitleDraftCue> drafts,
  SubtitleEvidenceIndex index,
) {
  if (index.same.isEmpty) return drafts;
  final List<SubtitleDraftCue> out = List<SubtitleDraftCue>.of(drafts);
  final List<(int, int)> covered = <(int, int)>[
    for (final SubtitleDraftCue c in drafts) (c.startMs, c.endMs),
  ];
  for (final SubtitleEvidenceTrack track in index.same) {
    final List<(int, int)> added = <(int, int)>[];
    for (final SubtitleEvidenceCue cue in track.cues) {
      if (cue.role != SubtitleEvidenceRole.dialogue) continue;
      final int length = cue.endMs - cue.startMs;
      if (length < kSubtitleEvidenceGapMinMs) continue;
      final String text = normalizeEvidenceLineText(cue.text);
      if (text.isEmpty) continue;
      int overlap = 0;
      for (final (int s, int e) in covered) {
        overlap += subtitleOverlapMs(cue.startMs, cue.endMs, s, e);
      }
      if (overlap > length * kSubtitleEvidenceGapMaxCoverage) continue;
      out.add(
        SubtitleDraftCue(
          startMs: cue.startMs,
          endMs: cue.endMs,
          text: text,
          origin: track.label,
        ),
      );
      added.add((cue.startMs, cue.endMs));
    }
    // 下一条轨（OCR）不重复补这条轨已补的时段。
    covered.addAll(added);
  }
  out.sort((SubtitleDraftCue a, SubtitleDraftCue b) {
    final int c = a.startMs.compareTo(b.startMs);
    return c != 0 ? c : a.endMs.compareTo(b.endMs);
  });
  return out;
}

/// 证据行 → 一行字幕正文：软换行并成一行（中日文用全角空格隔开——日文字幕换行处多是
/// 两个短语的分界，直接拼会粘成一句；其余语言用半角空格），去掉每行首尾空白。
String normalizeEvidenceLineText(String text) {
  final List<String> parts = <String>[
    for (final String line in text.split(RegExp(r'\r?\n|\\N')))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (parts.isEmpty) return '';
  final bool cjk = RegExp(r'[぀-ヿ㐀-鿿]').hasMatch(parts.join());
  return parts.join(cjk ? '　' : ' ');
}

/// OCR 证据换掉识别行的字面相似度下限（字符二元组 Dice）：同一句台词差一两个同音字
/// （「島に行こう」/「堂に行こう」0.75）在它之上；只是时间挨着的别的句子在它之下。
const double kSubtitleOcrCorrectionMinSimilarity = 0.5;

/// 一行 OCR 证据与识别行互相覆盖的比例下限：两边都至少这么多重叠，才算同一句（硬字幕
/// 证据按识别行取帧，天然 100%；图形字幕轨的分行与识别稿不同，一行压两句的不换）。
const double kSubtitleOcrCorrectionMinCoverage = 0.6;

/// 不开 AI 时的确定性纠错（拍板台 `d-fO4eGxKx`）：识别行与同时段同语言 **OCR** 证据
/// （画面上的硬字幕 / 图形字幕，即观众看到的片方写法）是同一句、只差几个字时，用 OCR
/// 的写法换掉识别行——同音字错误（「島」/「堂」）不再进字幕和卡片。
///
/// - 只认 OCR 证据：人工文字字幕可能来自别的版本、删了口癖，交给 S3 校对判断。
/// - 补齐插入的行（带 [SubtitleDraftCue.origin]）本来就是证据原文，不动。
/// - 换掉的行丢掉词级时间（[SubtitleDraftCue.tokenTiming]）与候选：它们描述的是旧文字。
/// - 开着 AI 时不调用：S3 同时看得到识别稿与证据（与画面），比字面规则判得准。
List<SubtitleDraftCue> correctSubtitleDraftsFromOcrEvidence(
  List<SubtitleDraftCue> drafts,
  SubtitleEvidenceIndex index,
) {
  final List<SubtitleEvidenceTrack> tracks = <SubtitleEvidenceTrack>[
    for (final SubtitleEvidenceTrack t in index.same)
      if (t.kind == SubtitleEvidenceKind.ocr) t,
  ];
  if (tracks.isEmpty) return drafts;
  return <SubtitleDraftCue>[
    for (final SubtitleDraftCue cue in drafts)
      if ((cue.origin == null ? _ocrReplacement(cue, tracks) : null)
          case final String text)
        SubtitleDraftCue(
          startMs: cue.startMs,
          endMs: cue.endMs,
          text: text,
          speaker: cue.speaker,
        )
      else
        cue,
  ];
}

/// [cue] 该换成的 OCR 写法；不该换返回 null。
String? _ocrReplacement(
  SubtitleDraftCue cue,
  List<SubtitleEvidenceTrack> tracks,
) {
  final int length = cue.endMs - cue.startMs;
  final String original = cue.text.trim();
  if (length <= 0 || original.isEmpty) return null;
  for (final SubtitleEvidenceTrack track in tracks) {
    final List<SubtitleEvidenceCue> same = <SubtitleEvidenceCue>[
      for (final SubtitleEvidenceCue e in track.cues)
        if (e.role == SubtitleEvidenceRole.dialogue &&
            e.endMs > e.startMs &&
            subtitleOverlapMs(cue.startMs, cue.endMs, e.startMs, e.endMs) >=
                kSubtitleOcrCorrectionMinCoverage * length &&
            subtitleOverlapMs(cue.startMs, cue.endMs, e.startMs, e.endMs) >=
                kSubtitleOcrCorrectionMinCoverage * (e.endMs - e.startMs))
          e,
    ];
    if (same.length != 1) continue;
    final String text = normalizeEvidenceLineText(same.single.text);
    if (text.isEmpty || text == original) return null;
    if (lyricsBigramDice(original, text) <
        kSubtitleOcrCorrectionMinSimilarity) {
      continue;
    }
    return text;
  }
  return null;
}
