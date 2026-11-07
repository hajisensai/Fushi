import 'dart:convert';

import 'package:fushi_audio/fushi_audio.dart';

/// 「跟随音频」的领读方向偏好值（`audiobook_link_direction`）。
///
/// * [kAudiobookLinkDirectionAudio]：音频领读（原有行为）——音频往下播，文字翻页跟上。
/// * [kAudiobookLinkDirectionText]：文字领读——音频播到当前屏最后一句的句末就停，
///   用户翻到下一屏再从那一屏续播；手动翻屏把音频带到该屏。音频自己从不翻屏。
const String kAudiobookLinkDirectionAudio = 'audio';
const String kAudiobookLinkDirectionText = 'text';

/// 判断「音频是否已在这一屏」时，屏首句起点前放宽的毫秒数：上一屏末句的句末与
/// 本屏首句的句首之间常有几十到一两百毫秒的静音，停在上一屏句末的位置要算作已在
/// 本屏开头（原地续播），而不是再 seek 一次。
const int kTextLeadsPageStartToleranceMs = 250;

/// 当前屏上的有声书句子范围：[first] = 第一句（屏首续播 / 跳转的落点），[last] =
/// 最后一句（播到它的句末就停）。两者都按「句首落在本屏」取，跨屏的长句归它开头
/// 所在的那一屏。
class TextLeadsPageBounds {
  const TextLeadsPageBounds({required this.first, required this.last});

  final AudioCue first;
  final AudioCue last;

  /// 同一屏重复上报（重排 / 换样式 / 同屏重建）时判等用，按句子身份而非对象引用
  /// （章节重载会换一份新对象的 cue 列表）。
  bool sameRangeAs(TextLeadsPageBounds? other) =>
      other != null &&
      sameTextLeadsCue(first, other.first) &&
      sameTextLeadsCue(last, other.last);
}

bool sameTextLeadsCue(AudioCue a, AudioCue b) =>
    a.audioFileIndex == b.audioFileIndex &&
    a.startMs == b.startMs &&
    a.endMs == b.endMs &&
    a.textFragmentId == b.textFragmentId;

/// reader 侧条件：选了「文字领读」且当前是 VN 模式。分页 / 连续模式没有逐屏上报，
/// 一律退回音频领读。
bool textLeadsRequestedFor({
  required String linkDirection,
  required bool vnMode,
}) => linkDirection == kAudiobookLinkDirectionText && vnMode;

/// 文字领读此刻是否生效：reader 条件成立、跟随音频开着、且不在歌词覆盖层（覆盖层
/// 期间正文被强制跟随音频）。
bool textLeadsActive({
  required bool requested,
  required bool followAudio,
  required bool lyricsOverlay,
}) => requested && followAudio && !lyricsOverlay;

/// 播放位置按「文件下标 → 文件内毫秒」排序比较。
int comparePlaybackPosition({
  required int fileA,
  required int msA,
  required int fileB,
  required int msB,
}) {
  if (fileA != fileB) return fileA.compareTo(fileB);
  return msA.compareTo(msB);
}

/// 位置（已扣掉音画延迟的 [effectiveMs]）是否已到 / 越过本屏末句的句末。
bool textLeadsPastPageEnd({
  required int fileIndex,
  required int effectiveMs,
  required AudioCue last,
}) =>
    comparePlaybackPosition(
      fileA: fileIndex,
      msA: effectiveMs,
      fileB: last.audioFileIndex,
      msB: last.endMs,
    ) >=
    0;

/// 音频位置是否落在这一屏：不早于首句句首（含 [kTextLeadsPageStartToleranceMs]
/// 余量）且还没播完末句。停在上一屏末句句末的位置因此算作「在下一屏开头」。
bool textLeadsAudioOnPage({
  required int fileIndex,
  required int effectiveMs,
  required TextLeadsPageBounds bounds,
}) {
  final bool afterStart =
      comparePlaybackPosition(
        fileA: fileIndex,
        msA: effectiveMs,
        fileB: bounds.first.audioFileIndex,
        msB: bounds.first.startMs - kTextLeadsPageStartToleranceMs,
      ) >=
      0;
  if (!afterStart) return false;
  return !textLeadsPastPageEnd(
    fileIndex: fileIndex,
    effectiveMs: effectiveMs,
    last: bounds.last,
  );
}

/// 新的一屏上报后该做什么。
enum TextLeadsPageAction {
  /// 不动（音频已在本屏且没有停在屏末等续播，或用户自己暂停着且音频已在本屏）。
  none,

  /// 音频已在本屏开头（停在上一屏句末）：原地续播。
  resumeHere,

  /// 音频不在本屏：跳到本屏首句；[TextLeadsPageDecision.play] 决定跳完是否播放。
  seekToPageStart,
}

class TextLeadsPageDecision {
  const TextLeadsPageDecision(this.action, {this.play = false});

  final TextLeadsPageAction action;
  final bool play;

  @override
  bool operator ==(Object other) =>
      other is TextLeadsPageDecision &&
      other.action == action &&
      other.play == play;

  @override
  int get hashCode => Object.hash(action, play);

  @override
  String toString() => 'TextLeadsPageDecision($action, play: $play)';
}

/// 纯决策：屏换了（用户翻屏 / 跳章落地 / 显式跳句翻屏）之后音频怎么跟。
///
/// * 音频已在本屏：停在屏末等续播的 → 原地续播；其余不动（正在播就继续播，用户
///   暂停的保持暂停）。
/// * 音频不在本屏（翻到了别的屏）：跳到本屏首句。停在屏末等续播或正在播 → 跳完
///   接着播（「翻屏自动续播」与「播放中翻屏，音频跟过来」）；用户自己暂停的 →
///   只挪位置不起播，按播放时从这一屏开始。往回翻同样适用（重听这一屏）。
TextLeadsPageDecision decideTextLeadsPageChange({
  required bool audioOnPage,
  required bool pausedAtPageEnd,
  required bool playing,
}) {
  if (audioOnPage) {
    return pausedAtPageEnd
        ? const TextLeadsPageDecision(
            TextLeadsPageAction.resumeHere,
            play: true,
          )
        : const TextLeadsPageDecision(TextLeadsPageAction.none);
  }
  return TextLeadsPageDecision(
    TextLeadsPageAction.seekToPageStart,
    play: pausedAtPageEnd || playing,
  );
}

/// 解析 VN 引擎 `onTextLeadsScreenCues` 回传的 JSON：
/// `{"type":"frag"|"sid"|"none","first":<id>,"last":<id>}`。
///
/// `frag` 按 textFragmentId（Sasayaki 原生 EPUB 的 cue），`sid` 按 sentenceIndex
/// （SRT / VTT / LRC 合成书的 `[data-cue-id]`），与 `cueForPointerPayload` 同一套
/// 身份约定。`none`（插图屏 / 本屏没有句子）、解析失败、找不到对应 cue 一律返回
/// null。
TextLeadsPageBounds? textLeadsBoundsFromPayload(
  String json,
  List<AudioCue> cues,
) {
  if (json.isEmpty || json == 'null' || cues.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final Object? type = decoded['type'];
  AudioCue? find(Object? id) {
    if (id == null) return null;
    if (type == 'frag') {
      final String fragId = '$id';
      for (final AudioCue cue in cues) {
        if (cue.textFragmentId == fragId) return cue;
      }
      return null;
    }
    if (type == 'sid') {
      final int? sid = int.tryParse('$id');
      if (sid == null) return null;
      for (final AudioCue cue in cues) {
        if (cue.sentenceIndex == sid) return cue;
      }
      return null;
    }
    return null;
  }

  final AudioCue? first = find(decoded['first']);
  final AudioCue? last = find(decoded['last']);
  if (first == null || last == null) return null;
  // 防御：两端顺序颠倒（数据异常）时按播放顺序摆正，免得「末句」早于「首句」。
  final bool reversed =
      comparePlaybackPosition(
        fileA: last.audioFileIndex,
        msA: last.endMs,
        fileB: first.audioFileIndex,
        msB: first.startMs,
      ) <
      0;
  return reversed
      ? TextLeadsPageBounds(first: last, last: first)
      : TextLeadsPageBounds(first: first, last: last);
}
