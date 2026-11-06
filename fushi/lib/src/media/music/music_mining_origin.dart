/// 音乐歌词制卡的出处写入（分期 L3「回到出处」，docs/specs/2026-10-24-cross-media-links.md §4）。
///
/// 歌词制卡入口本身由音乐模块实现；这里只给它两样东西，保证 `music` 来源的
/// 出处与书 / 视频同口径落地：
/// - [musicCardSourceLink]：写进卡片的来源链接（`fushi://source?kind=music`），
///   复习时「回到出处」按它播放原曲片段；
/// - [recordMusicMinedSentence]：收藏夹「制卡」历史行（`mined_sentences`，
///   source = `music`，bookKey = track uid，position_ms / duration_ms = 歌词行时间窗）。
///
/// 时间一律是**曲目时间轴**上的毫秒（CUE 虚拟曲目是曲内偏移，与
/// `MusicPlayerEngine.position` 同一坐标）。
library;

import 'package:fushi_anki/fushi_anki.dart' show CardSourceLink;
import 'package:fushi_audio/fushi_audio.dart' show kFavoriteSentenceSourceMusic;
import 'package:fushi_core/fushi_core.dart';

/// 一行歌词制卡的出处链接。[lineEndMs] 缺失（最后一行 / 无结束时刻的 LRC）时按
/// 起点记零长区间——链接校验要求成对的起止。uid 不可携带时返回 null（制卡照常，
/// 只是卡上没有可点的出处）。
CardSourceLink? musicCardSourceLink({
  required String trackUid,
  required int lineStartMs,
  int? lineEndMs,
  String? sourceId,
}) {
  final int start = lineStartMs < 0 ? 0 : lineStartMs;
  final int end = lineEndMs == null || lineEndMs < start ? start : lineEndMs;
  return CardSourceLink.tryMusic(
    trackUid: trackUid,
    startMs: start,
    endMs: end,
    sourceId: sourceId,
  );
}

/// 落一条音乐来源的制卡历史行。
///
/// [trackTitle] 是落库的显示名快照（收藏夹副标题 / 回到出处的标题），[artist] 进
/// `chapter_label`（收藏夹里与「第几章」同位置显示「哪首歌 · 谁唱的」）。
Future<void> recordMusicMinedSentence({
  required FushiDatabase db,
  required String trackUid,
  required String dateKey,
  required int lineStartMs,
  int? lineEndMs,
  String? trackTitle,
  String? artist,
  String expression = '',
  String reading = '',
  String glossary = '',
  String sentence = '',
  int? noteId,
}) {
  final int start = lineStartMs < 0 ? 0 : lineStartMs;
  final int? duration = lineEndMs == null || lineEndMs < start
      ? null
      : lineEndMs - start;
  final String? title = trackTitle?.trim();
  final String? credit = artist?.trim();
  return db.addMinedSentence(
    source: kFavoriteSentenceSourceMusic,
    dateKey: dateKey,
    expression: expression,
    reading: reading,
    glossary: glossary,
    sentence: sentence,
    documentTitle: title == null || title.isEmpty ? null : title,
    chapterLabel: credit == null || credit.isEmpty ? null : credit,
    bookKey: trackUid,
    positionMs: start,
    durationMs: duration,
    noteId: noteId,
  );
}
