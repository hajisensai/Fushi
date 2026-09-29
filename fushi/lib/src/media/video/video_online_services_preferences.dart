import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// App-global: switching reading profiles must not resurrect this reminder.
const String kVideoOnlineServicesSetupDismissedPref =
    PreferencesRepository.videoOnlineServicesSetupDismissedKey;

bool shouldShowVideoOnlineServicesReminder(PreferencesRepository preferences) {
  if (preferences.videoOnlineServicesSetupDismissed) {
    return false;
  }
  // 这里只看凭据是否配齐，资料语言用不到；显式传兜底而不是让参数有默认值，
  // 见 fromPreferences 的说明。
  final VideoSourceScrapeGlobalConfig config =
      VideoSourceScrapeGlobalConfig.fromPreferences(preferences,
          resolvedTmdbApiKey: '',
          uiLocaleTag: kFallbackVideoMetadataLocale);
  // 与设置页状态、协调器同一判据（BUG-2586）：自定义客户端名不合规时登录
  // 根本发不出去，不能只看账号密码填没填。
  final bool aniDbReady = config.anidbHashReady;
  final bool jimakuReady =
      preferences.jimakuEnabled && preferences.jimakuApiKey.trim().isNotEmpty;
  final OpenSubtitlesConfig subtitles =
      preferences.videoSubtitleOpenSubtitlesConfig;
  final bool openSubtitlesReady =
      subtitles.enabled && subtitles.effectiveApiKey.isNotEmpty;
  // Public / bundled access (MAL, TMDB, DanDanPlay) never creates missing setup.
  return !aniDbReady || !jimakuReady || !openSubtitlesReady;
}

Future<void> dismissVideoOnlineServicesReminder(
        PreferencesRepository preferences) =>
    preferences.dismissVideoOnlineServicesSetup();
