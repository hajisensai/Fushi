/// S2e 缺口补齐（spec §3）：同语言证据里识别稿没覆盖到的台词插回字幕稿。
///
/// 识别漏掉的通常是小声 / 叠着 BGM / 多人抢话的台词；身边的日语字幕（人工或 OCR）
/// 恰好有它们。插入的行带 [SubtitleDraftCue.origin]（证据轨标签），S3 照常校对。
/// 确定性、不需要 AI：AI 关闭时也补。
library;

import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_burned_in_evidence.dart'
    show kSubtitleBurnedInTrackLabel;
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

/// OCR 证据换掉识别行的字面相似度下限（字符二元组 Dice，去标点 / 空白后比）：同一句
/// 台词差一两个同音字（「島に行こう」/「堂に行こう」0.75）在它之上；只是时间挨着的别的
/// 句子在它之下。
const double kSubtitleOcrCorrectionMinSimilarity = 0.5;

/// 一行 OCR 证据与识别行互相覆盖的比例下限：两边都至少这么多重叠，才算同一句（硬字幕
/// 证据按识别行取帧，天然 100%）。
const double kSubtitleOcrCorrectionMinCoverage = 0.6;

/// 不开 AI 时的确定性纠错（拍板台 `d-fO4eGxKx`）：识别行与同时段的**画面硬字幕** OCR
/// 证据（[kSubtitleBurnedInTrackLabel]，观众看到的片方写法）是同一句、字（汉字 / 假名 /
/// 字母数字）有几个不一样时，把不一样的字换成画面写法——同音字错误（「島」/「堂」）
/// 不再进字幕和卡片。
///
/// - 只认画面硬字幕：人工文字字幕、内封图形字幕（PGS / VobSub）都可能来自别的版本、
///   删了口癖，交给 S3 校对判断。
/// - **只换字、不换标点**：两边只差标点 / 空白（硬字幕通常不带句号、两行直接拼接）不算
///   不同；换的时候保留识别稿的标点与空白，句末「。」照旧供显示拆分用。
/// - 保留词级时间（[SubtitleDraftCue.tokenTiming]）与候选：下游逐字时间按字对齐、对不上
///   的字插值（与 S3 改字同一口径）。
/// - 补齐插入的行（带 [SubtitleDraftCue.origin]）本来就是证据原文，不动。
/// - 开着 AI 时不调用：S3 同时看得到识别稿与证据（与画面），比字面规则判得准。
List<SubtitleDraftCue> correctSubtitleDraftsFromOcrEvidence(
  List<SubtitleDraftCue> drafts,
  SubtitleEvidenceIndex index,
) {
  final List<SubtitleEvidenceTrack> tracks = <SubtitleEvidenceTrack>[
    for (final SubtitleEvidenceTrack t in index.same)
      if (isBurnedInSubtitleEvidenceTrack(t)) t,
  ];
  if (tracks.isEmpty) return drafts;
  return <SubtitleDraftCue>[
    for (final SubtitleDraftCue cue in drafts)
      if ((cue.origin == null ? _ocrReplacement(cue, tracks) : null)
          case final String text)
        cue.copyWith(text: text)
      else
        cue,
  ];
}

/// [track] 是不是画面硬字幕 OCR 轨（`subtitle_burned_in_evidence.dart` 产出）。
bool isBurnedInSubtitleEvidenceTrack(SubtitleEvidenceTrack track) =>
    track.kind == SubtitleEvidenceKind.ocr &&
    track.label == kSubtitleBurnedInTrackLabel;

/// [cue] 该换成的文字；不该换返回 null。
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
    final String ocr = same.single.text;
    if (lyricsBigramDice(original, ocr) < kSubtitleOcrCorrectionMinSimilarity) {
      continue;
    }
    final String? merged = mergeSubtitleOcrSpelling(cue.text, ocr);
    return merged == null || merged == cue.text ? null : merged;
  }
  return null;
}

/// **纯函数**：把 [ocr] 的写法并进识别行 [asr]——只比「字」（[isSubtitleSpellingRune]，
/// 全角半角、大小写不分），两边的字一样返回 null；否则按最长公共子序列对齐，识别稿里
/// 对不上的字换成 OCR 对应位置的字，识别稿的标点 / 空白原样留在原处（OCR 的标点不要）。
String? mergeSubtitleOcrSpelling(String asr, String ocr) {
  final List<int> a = asr.runes.toList(growable: false);
  final List<int> posA = <int>[
    for (int i = 0; i < a.length; i++)
      if (isSubtitleSpellingRune(a[i])) i,
  ];
  final List<int> keyA = <int>[
    for (final int i in posA) foldSubtitleSpellingRune(a[i]),
  ];
  final List<int> b = <int>[
    for (final int r in ocr.runes)
      if (isSubtitleSpellingRune(r)) r,
  ];
  final List<int> keyB = <int>[
    for (final int r in b) foldSubtitleSpellingRune(r),
  ];
  if (keyA.isEmpty || keyB.isEmpty) return null;
  if (_sameRunes(keyA, keyB)) return null;

  // 后缀 LCS 表：lcs[i * (m + 1) + j] = keyA[i..] 与 keyB[j..] 的 LCS 长度。
  final int n = keyA.length;
  final int m = keyB.length;
  final List<int> lcs = List<int>.filled((n + 1) * (m + 1), 0);
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      lcs[i * (m + 1) + j] = keyA[i] == keyB[j]
          ? lcs[(i + 1) * (m + 1) + j + 1] + 1
          : (lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1]
                ? lcs[(i + 1) * (m + 1) + j]
                : lcs[i * (m + 1) + j + 1]);
    }
  }
  final List<(int, int)> anchors = <(int, int)>[];
  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (keyA[i] == keyB[j]) {
      anchors.add((i, j));
      i++;
      j++;
    } else if (lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  anchors.add((n, m)); // 哨兵：末尾那段。

  final StringBuffer out = StringBuffer();
  int prevA = -1; // 上一个锚点在 keyA 里的下标
  int prevB = -1;
  int prevPos = -1; // 上一个锚点在 a 里的位置
  for (final (int ai, int bj) in anchors) {
    final int pos = ai < n ? posA[ai] : a.length;
    final String insert = String.fromCharCodes(b.sublist(prevB + 1, bj));
    // 这段里识别稿的字（prevA+1..ai-1）整体换成 insert；标点 / 空白留原位。
    final bool hasReplaced = ai - prevA > 1;
    final List<int> region = a.sublist(prevPos + 1, pos);
    if (hasReplaced) {
      final int first = posA[prevA + 1] - (prevPos + 1);
      out.write(String.fromCharCodes(region.sublist(0, first)));
      out.write(insert);
      for (int k = first; k < region.length; k++) {
        if (!isSubtitleSpellingRune(region[k])) out.writeCharCode(region[k]);
      }
    } else if (prevPos < 0) {
      // 行首只多出 OCR 的字：跟在开头的标点（「…）后面。
      out.write(String.fromCharCodes(region));
      out.write(insert);
    } else {
      // 只多出 OCR 的字：接在上一个字后面、标点前面。
      out.write(insert);
      out.write(String.fromCharCodes(region));
    }
    if (ai < n) out.writeCharCode(a[pos]);
    prevA = ai;
    prevB = bj;
    prevPos = pos;
  }
  return out.toString();
}

bool _sameRunes(List<int> x, List<int> y) {
  if (x.length != y.length) return false;
  for (int i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}
