/// 漫画制卡的句子音频（设计 §3「制卡」）：这一卷登记过有声成品、清单仍是本卷当前
/// OCR 的成品、查词句子所在的 OCR 块落在某一句的块下标里时，取那一句的音频区间
/// （经 `mining_audio_clip.dart` 的 [miningCueAudioRange] 同一套留白规则）作句子音频。
///
/// 命中不了一律返回 null，调用方保持原状：句子音频不做 TTS 兜底（BUG-172 结论，见
/// `creator/mining_tts_fallback.dart` 文件头），单词音频的 TTS 兜底不受影响。
///
/// 纯函数（不碰数据库 / 文件），阅读器负责读登记与裁片。
library;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart'
    show MokuroPayload;
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';

import 'package:fushi/src/media/audiobook/mining_audio_clip.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';

/// 制卡要裁的一段成品音频：[inputPath] 是那一句的音频文件，[range] 是在该文件里的
/// 区间（[AudioPlaybackRange.audioFileIndex] = 清单行下标）。
class MangaMiningAudioClip {
  const MangaMiningAudioClip({
    required this.line,
    required this.inputPath,
    required this.range,
  });

  final MangaRenderedLine line;
  final String inputPath;
  final AudioPlaybackRange range;
}

/// 清单里第 [pageIndex] 页、块下标与 [blocks] 有交集的那一句的行下标；交集最大者
/// 优先，并列取清单里靠前的。占位静音行（没配上音）不算。没有返回 null。
int? mangaMiningAudioLineIndex(
  MangaRenderManifest manifest, {
  required int pageIndex,
  required List<int> blocks,
}) {
  if (blocks.isEmpty) return null;
  final Set<int> wanted = blocks.toSet();
  int? best;
  int bestOverlap = 0;
  for (int i = 0; i < manifest.lines.length; i++) {
    final MangaRenderedLine line = manifest.lines[i];
    if (line.page != pageIndex || line.placeholder) continue;
    final int overlap = line.blocks.where(wanted.contains).length;
    if (overlap > bestOverlap) {
      best = i;
      bestOverlap = overlap;
    }
  }
  return best;
}

/// 查词句子（第 [pageIndex] 页的 OCR 块 [blocks]）对应的成品音频片段。
///
/// 返回 null：没登记成品；清单不是本卷当前 OCR 的成品（页数不符或 OCR 签名不符——
/// OCR 重跑过，块下标已对不上，取到的会是别的台词）；没有哪一句覆盖这些块。
MangaMiningAudioClip? resolveMangaMiningAudioClip({
  required MangaAudioRegistration? registration,
  required MokuroPayload payload,
  required int pageIndex,
  required List<int> blocks,
  int headPadMs = kMiningHeadPadMs,
  int tailPadMs = kMiningTailPadMs,
}) {
  if (registration == null) return null;
  final MangaRenderManifest manifest = registration.manifest;
  if (mangaManifestVolumeMismatch(manifest, payload) != null) return null;
  final int? index = mangaMiningAudioLineIndex(
    manifest,
    pageIndex: pageIndex,
    blocks: blocks,
  );
  if (index == null) return null;
  return resolveMangaLineAudioClip(
    registration: registration,
    lineIndex: index,
    headPadMs: headPadMs,
    tailPadMs: tailPadMs,
  );
}

/// 清单第 [lineIndex] 句的成品音频片段（制卡与「导出片段视频」共用同一套留白规则：
/// [miningCueAudioRange]）。
///
/// 返回 null：没登记成品、下标越界、该句是没配上音的占位静音行（没有可导出的声音）。
/// [lineId] 非 null 时还要求登记里那一句的 id 与之相同——调用方手里的清单（播放驱动
/// 持有的那份）若已被单句补回 / 整份替换换掉，按下标取到的会是别的台词，宁可不给。
MangaMiningAudioClip? resolveMangaLineAudioClip({
  required MangaAudioRegistration? registration,
  required int lineIndex,
  String? lineId,
  int headPadMs = kMiningHeadPadMs,
  int tailPadMs = kMiningTailPadMs,
}) {
  if (registration == null) return null;
  final MangaRenderManifest manifest = registration.manifest;
  if (lineIndex < 0 || lineIndex >= manifest.lines.length) return null;
  final MangaRenderedLine line = manifest.lines[lineIndex];
  if (line.placeholder) return null;
  if (lineId != null && line.lineId != lineId) return null;
  final List<AudioCue> cues = mangaAudioCues(registration.bookKey, manifest);
  return MangaMiningAudioClip(
    line: line,
    inputPath: registration.linePath(line),
    range: miningCueAudioRange(
      cues: cues,
      cue: cues[lineIndex],
      headPadMs: headPadMs,
      tailPadMs: tailPadMs,
    ),
  );
}
