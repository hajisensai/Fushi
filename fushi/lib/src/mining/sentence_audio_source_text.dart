import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/mining/sentence_audio_source.dart';

/// 「指定音轨」在设置里列出的条数（第 1..N 条）。设置页没有正在播的视频，列不出真实
/// 音轨；多数片源不超过这么多条，越界的在制卡时回退并提示。加上「当前播放音轨」与
/// 「中置声道」两项后正好落在行内下拉的上限内（`kSettingsPickerInlineLimit` = 8）。
const int kSentenceAudioSourceListedTracks = 6;

/// 设置页 / 操作目录列出的全部来源（顺序即显示顺序）。
List<SentenceAudioSourcePick> sentenceAudioSourceSettingChoices() =>
    <SentenceAudioSourcePick>[
      SentenceAudioSourcePick.currentTrack,
      SentenceAudioSourcePick.frontCenter,
      for (int i = 0; i < kSentenceAudioSourceListedTracks; i++)
        SentenceAudioSourcePick.track(i),
    ];

/// 高级制卡对话框列出的来源：当前播放音轨、中置声道，加上这个视频**真有**的每条音轨
/// （[trackCount] 条；只有一条时「指定音轨」没有意义，不列）。
List<SentenceAudioSourcePick> sentenceAudioSourceDialogChoices(
  int trackCount,
) => <SentenceAudioSourcePick>[
  SentenceAudioSourcePick.currentTrack,
  SentenceAudioSourcePick.frontCenter,
  if (trackCount > 1)
    for (int i = 0; i < trackCount; i++) SentenceAudioSourcePick.track(i),
];

/// 来源的显示名（音轨 1-based）。
String sentenceAudioSourceLabel(SentenceAudioSourcePick pick) =>
    switch (pick.kind) {
      SentenceAudioSourceKind.currentTrack =>
        t.video_mining_audio_source_current,
      SentenceAudioSourceKind.frontCenter =>
        t.video_mining_audio_source_front_center,
      SentenceAudioSourceKind.selectedTrack =>
        t.video_mining_audio_source_track(n: pick.trackOrdinal + 1),
    };

/// 回退提示文案（[pick] 是用户选的来源，「没有第 N 条音轨」要用到它）。
String sentenceAudioFallbackMessage(
  SentenceAudioFallbackReason reason,
  SentenceAudioSourcePick pick,
) => switch (reason) {
  SentenceAudioFallbackReason.trackMissing =>
    t.video_mining_audio_source_fallback_track_missing(
      n: pick.trackOrdinal + 1,
    ),
  SentenceAudioFallbackReason.noFrontCenter =>
    t.video_mining_audio_source_fallback_no_center,
  SentenceAudioFallbackReason.frontCenterUnknown =>
    t.video_mining_audio_source_fallback_center_unknown,
  SentenceAudioFallbackReason.frontCenterFailed =>
    t.video_mining_audio_source_fallback_center_failed,
};
