/// S2e 缺口补齐（spec §3）：同语言证据里识别稿没覆盖到的台词插回字幕稿。
///
/// 识别漏掉的通常是小声 / 叠着 BGM / 多人抢话的台词；身边的日语字幕（人工或 OCR）
/// 恰好有它们。插入的行带 [SubtitleDraftCue.origin]（证据轨标签），S3 照常校对。
/// 确定性、不需要 AI：AI 关闭时也补。
library;

import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';

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
