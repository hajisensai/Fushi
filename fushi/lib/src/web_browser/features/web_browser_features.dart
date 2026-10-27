import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/web_browser/features/login_import/web_browser_login_import_feature.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';
import 'package:fushi/src/web_browser/features/reader_mode/web_reader_mode_feature.dart';
import 'package:fushi/src/web_browser/features/study/web_study_feature.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/features/youtube_subtitles/youtube_subtitles_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_comic_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_novel_feature.dart';

/// 浏览器功能的唯一装配点：浏览页 initState 时调一次，只保留 `available` 的。
/// 新功能 = 实现 [WebBrowserFeature] + 在这里加一行。
List<WebBrowserFeature> buildWebBrowserFeatures(WidgetRef ref) =>
    <WebBrowserFeature>[
      // 各功能实现在这里登记。
      WebComicFeature(ref: ref),
      WebNovelFeature(ref: ref),
      PlayInFushiFeature(
        repository: () => VideoBookRepository(ref.read(appProvider).database),
        youtubeTargetHeight: () =>
            ref.read(appProvider).youtubeQualityTargetHeightOrNull,
      ),
      YoutubeSubtitlesFeature(prefs: ref.read(appProvider).prefsRepo),
      WebBrowserReaderModeFeature(ref: ref),
      WebBrowserLoginImportFeature(),
      WebBrowserStudyFeature(
        clockFactory: ({required String mediaKey, required String title}) =>
            StudyClockWebPort(
              database: ref.read(appProvider).database,
              mediaKey: mediaKey,
              title: title,
              idleTimeout: ref.read(appProvider).readingIdleTimeout,
            ),
      ),
    ].where((WebBrowserFeature f) => f.available).toList();
