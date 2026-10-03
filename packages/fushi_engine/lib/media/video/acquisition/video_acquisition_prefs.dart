/// 「AI 下视频」的偏好键与默认值读侧。
///
/// app 的 `PreferencesRepository` 与无头服务端的 `ServerPrefs` 都是 [PrefStore]，读
/// 同一张 `preferences` 表的同一组键：会话开场的默认画质 / 片源 / 码率 / 字幕语言
/// 与「跳过特典」只在这里拼一次。**键值冻结**（存量持久化名）。
library;

import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';

/// 默认画质：`''` 未设置 / `ask` / 固定档。
const String kAiVideoDownloadQualityPref = 'ai_video_download_quality';

/// 片源偏好：`''` / `best` / `bluray` / `web`。
const String kAiVideoDownloadSourcePref = 'ai_video_download_source';

/// 码率偏好：`''` / `high` / `low`。
const String kAiVideoDownloadBitratePref = 'ai_video_download_bitrate';

/// 字幕语言：`''` / `ask` / `original` / 语言码 / `none`。
const String kAiVideoDownloadSubtitleLanguagePref =
    'ai_video_download_subtitle_language';

/// 下载进受管视频来源时跳过特典。
const String kVideoDownloadSkipExtrasPref = 'video_download_skip_extras';

String _string(PrefStore prefs, String key) =>
    prefs.getPref(key, defaultValue: '') as String;

/// 开一场会话时的默认值。[defaultSourceId] 为 0 / null = 没选默认目标来源；
/// [locale] 是**说话那个人**的界面语言。
VideoAcquisitionDefaults readVideoAcquisitionDefaults(
  PrefStore prefs, {
  required List<MediaSourceRow> sources,
  required int? defaultSourceId,
  required String locale,
}) => VideoAcquisitionDefaults(
  qualityPref: _string(prefs, kAiVideoDownloadQualityPref),
  sourcePref: VideoAcquisitionSourcePref.parse(
    _string(prefs, kAiVideoDownloadSourcePref),
  ),
  bitratePref: VideoAcquisitionBitratePref.parse(
    _string(prefs, kAiVideoDownloadBitratePref),
  ),
  subtitleLanguagePref: _string(prefs, kAiVideoDownloadSubtitleLanguagePref),
  sources: <VideoAcquisitionSource>[
    for (final MediaSourceRow source in sources)
      VideoAcquisitionSource(id: source.id, label: source.label),
  ],
  defaultSourceId: (defaultSourceId ?? 0) == 0 ? null : defaultSourceId,
  locale: locale,
  skipExtras:
      prefs.getPref(kVideoDownloadSkipExtrasPref, defaultValue: false) as bool,
);

/// 「以后默认」勾选写回的偏好键。
String videoAcquisitionPreferenceKey(VideoAcquisitionPreference preference) =>
    switch (preference) {
      VideoAcquisitionPreference.quality => kAiVideoDownloadQualityPref,
      VideoAcquisitionPreference.subtitleLanguage =>
        kAiVideoDownloadSubtitleLanguagePref,
    };
