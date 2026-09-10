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
  final VideoSourceScrapeGlobalConfig config =
      VideoSourceScrapeGlobalConfig.fromPreferences(preferences,
          resolvedTmdbApiKey: '');
  final bool aniDbReady = config.hashEnabled &&
      config.anidbUsername.isNotEmpty &&
      config.anidbPassword.isNotEmpty;
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
