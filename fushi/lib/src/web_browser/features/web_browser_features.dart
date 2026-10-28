import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_host_feature.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage_provider.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_video_activity.dart';
import 'package:fushi/src/web_browser/features/login_import/web_browser_login_import_feature.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';
import 'package:fushi/src/web_browser/features/reader_mode/web_reader_mode_feature.dart';
import 'package:fushi/src/web_browser/features/study/web_study_feature.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_comic_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_novel_feature.dart';

/// 浏览器功能的唯一装配点：浏览页 initState 时调一次，只保留 `available` 的。
/// 新功能 = 实现 [WebBrowserFeature] + 在这里加一行。
///
/// [lookup] 是浏览页的查词控制器（扩展宿主把网页视频字幕的查词交给它）；
/// [openExtensionSettings] 由浏览页用自己的 context 推「浏览器设置」的扩展分组。
List<WebBrowserFeature> buildWebBrowserFeatures(
  WidgetRef ref, {
  SrsCardLookupController? lookup,
  void Function()? openExtensionSettings,
}) {
  final AppModel app = ref.read(appProvider);
  final WebBrowserVideoActivity videoActivity = WebBrowserVideoActivity();
  return <WebBrowserFeature>[
    // 各功能实现在这里登记。
    WebComicFeature(ref: ref),
    WebNovelFeature(ref: ref),
    PlayInFushiFeature(
      repository: () => VideoBookRepository(app.database),
      youtubeTargetHeight: () => app.youtubeQualityTargetHeightOrNull,
    ),
    WebBrowserExtensionHostFeature(
      // 与「浏览器设置」里的扩展分组共用同一个实例（见 provider 说明）。
      storage: ref.read(webBrowserExtensionStorageProvider),
      api: (String path, Map<String, dynamic> body) =>
          app.extensionApiCore.handle(path, body),
      lookup: lookup,
      videoActivity: videoActivity,
      openSettings: openExtensionSettings,
    ),
    WebBrowserReaderModeFeature(ref: ref),
    WebBrowserLoginImportFeature(),
    WebBrowserStudyFeature(
      videoActivity: videoActivity,
      clockFactory: ({required String mediaKey, required String title}) =>
          StudyClockWebPort(
            database: app.database,
            mediaKey: mediaKey,
            title: title,
            idleTimeout: app.readingIdleTimeout,
          ),
    ),
  ].where((WebBrowserFeature f) => f.available).toList();
}
