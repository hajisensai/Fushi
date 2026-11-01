/// 视频字幕文本覆盖层（反馈 gleDreKAvo / dpAsMkUjKT）：用户在字幕列表里手改单条
/// 字幕后，改后文本按「视频 + 字幕源」存进 Drift 表 `video_subtitle_text_overrides`，
/// 字幕每次装进播放器（换源 / 重载 / libmpv 回流）都按 `(startMs, 原文)` 重新套一遍。
///
/// 只换 cue 的文本，不碰字幕文件 / 内封轨 / 在线轨本身；改后副本把原 cue 挂在
/// [AudioCue.uneditedCue] 上，还原 = 换回原 cue（样式 markup 原样回来）。
library;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 一个「视频 + 字幕源」下的全部手改：`(startMs, 原文) → 改后文本`。
class SubtitleTextOverrides {
  const SubtitleTextOverrides._(this._edited);

  /// [edited] 的键是 `(startMs, 原文)`。
  factory SubtitleTextOverrides(Map<(int, String), String> edited) =>
      edited.isEmpty
      ? empty
      : SubtitleTextOverrides._(
          Map<(int, String), String>.unmodifiable(edited),
        );

  /// 由数据库行构造。
  factory SubtitleTextOverrides.fromRows(
    Iterable<VideoSubtitleTextOverrideRow> rows,
  ) => SubtitleTextOverrides(<(int, String), String>{
    for (final VideoSubtitleTextOverrideRow row in rows)
      (row.startMs, row.originalText): row.editedText,
  });

  static const SubtitleTextOverrides empty = SubtitleTextOverrides._(
    <(int, String), String>{},
  );

  final Map<(int, String), String> _edited;

  bool get isEmpty => _edited.isEmpty;
  int get length => _edited.length;

  /// 命中的改后文本；没改过返回 null。
  String? editedTextFor(int startMs, String originalText) =>
      _edited[(startMs, originalText)];
}

/// 把 [overrides] 套到一条 cue 上。幂等：已是改后副本的 cue 按它的原文重新判定，
/// 覆盖被删（还原）时换回原 cue。没有任何变化时返回 [cue] 本身。
AudioCue applySubtitleTextOverride(
  AudioCue cue,
  SubtitleTextOverrides overrides,
) {
  final AudioCue unedited = cue.uneditedCue ?? cue;
  final String? edited = overrides.editedTextFor(
    unedited.startMs,
    unedited.text,
  );
  if (edited == null || edited == unedited.text) return unedited;
  if (!identical(unedited, cue) && cue.text == edited) return cue;
  return _editedCopy(unedited, edited);
}

/// 把 [overrides] 套到整份 cue 列表上；一条都没变时返回 [cues] 本身（调用方据此
/// 判断要不要通知重绘）。只换文本、不动起止时间，列表顺序与下标不变。
List<AudioCue> applySubtitleTextOverrides(
  List<AudioCue> cues,
  SubtitleTextOverrides overrides,
) {
  List<AudioCue>? out;
  for (int i = 0; i < cues.length; i++) {
    final AudioCue next = applySubtitleTextOverride(cues[i], overrides);
    if (identical(next, cues[i])) continue;
    out ??= List<AudioCue>.of(cues);
    out[i] = next;
  }
  return out ?? cues;
}

AudioCue _editedCopy(AudioCue unedited, String edited) {
  final AudioCue copy = AudioCue()
    ..id = unedited.id
    ..bookKey = unedited.bookKey
    ..chapterHref = unedited.chapterHref
    ..sentenceIndex = unedited.sentenceIndex
    ..textFragmentId = unedited.textFragmentId
    ..text = edited
    ..startMs = unedited.startMs
    ..endMs = unedited.endMs
    ..audioFileIndex = unedited.audioFileIndex
    ..markup = _markupForEditedText(unedited.markup, edited)
    // 逐 token 时间是原文 token 的，对改后文本不成立。
    ..tokenTiming = null
    ..uneditedCue = unedited;
  return copy;
}

/// 改后文本的 markup：保留整句几何与 cue 级样式（位置 / 锚点 / ASS Style / 淡入淡出
/// / 旋转 / 缩放 / 运动 / 层 / 裁剪），丢掉按原文 grapheme 下标定位的行内样式区间、
/// 硬换行下标与矢量绘图——下标对改后文本不再成立。
SubtitleMarkup? _markupForEditedText(SubtitleMarkup? markup, String edited) {
  if (markup == null) return null;
  return SubtitleMarkup(
    plainText: edited,
    spans: const <SubtitleSpan>[],
    anchor: markup.anchor,
    posFraction: markup.posFraction,
    cueStyle: markup.cueStyle,
    playResY: markup.playResY,
    playResX: markup.playResX,
    fade: markup.fade,
    rotationDeg: markup.rotationDeg,
    scale: markup.scale,
    move: markup.move,
    layer: markup.layer,
    clip: markup.clip,
    transitions: markup.transitions,
    rotationXDeg: markup.rotationXDeg,
    rotationYDeg: markup.rotationYDeg,
    shearX: markup.shearX,
    shearY: markup.shearY,
  );
}

/// 覆盖层的视频键：`bookUid`，播放列表第 2 集起 `bookUid#<集下标>`（与远端字幕偏好
/// 键 `(uid, episodeIndex)` 同口径）。
String subtitleTextOverrideVideoKey(String uid, int episodeIndex) =>
    episodeIndex <= 0 ? uid : '$uid#$episodeIndex';

/// 覆盖层的字幕源键：字幕源指针（`subtitleSource` 四态编码 / YouTube 轨键 / 在线轨键）
/// 的归一化。
///
/// - 外挂字幕文件（绝对路径）→ `file:<文件名>`：不存绝对路径，换数据根 / 迁移设备不
///   影响命中；ASR 每次产物文件名带时间戳，重新识别得到的是另一个源，旧改动不会误套
///   到新识别结果上。
/// - 其余（`embedded:<n>`、在线 / YouTube 轨键等）原样。
/// - null / 空（没有显式选择的默认字幕）→ 空串。
String subtitleTextOverrideSourceKey(String? source) {
  if (source == null) return '';
  final String trimmed = source.trim();
  if (trimmed.isEmpty) return '';
  if (p.windows.isAbsolute(trimmed) || p.posix.isAbsolute(trimmed)) {
    return 'file:${p.windows.basename(p.posix.basename(trimmed))}';
  }
  return trimmed;
}
