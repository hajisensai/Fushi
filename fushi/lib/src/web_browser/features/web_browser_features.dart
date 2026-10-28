import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/i18n/strings.g.dart' show LocaleSettings;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_host_feature.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_video_activity.dart';
import 'package:fushi/src/web_browser/features/login_import/web_browser_login_import_feature.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';
import 'package:fushi/src/web_browser/features/reader_mode/web_reader_mode_feature.dart';
import 'package:fushi/src/web_browser/features/study/web_study_feature.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_comic_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_novel_feature.dart';

/// 扩展存储里有 app 真源的键（读写直接走真源，不另存）。
Map<String, WebBrowserExtensionBridgedKey> webBrowserExtensionBridgedKeys() =>
    <String, WebBrowserExtensionBridgedKey>{
      // 「查词时暂停」：与 app 视频页 / 阅读器同一个偏好。
      'subtitlePauseOnLookup': (
        read: () => ReaderFushiSource.instance.pauseOnLookup,
        write: (Object? v) async {
          if (v is bool) {
            await ReaderFushiSource.instance.setPauseOnLookup(value: v);
          }
        },
      ),
      // 「离开查词即续播」：同上。
      'subtitleResumeOnLookupLeave': (
        read: () => ReaderFushiSource.instance.resumeOnLookupLeave,
        write: (Object? v) async {
          if (v is bool) {
            await ReaderFushiSource.instance.setResumeOnLookupLeave(value: v);
          }
        },
      ),
    };

/// 浏览器功能的唯一装配点：浏览页 initState 时调一次，只保留 `available` 的。
/// 新功能 = 实现 [WebBrowserFeature] + 在这里加一行。
///
/// [lookup] 是浏览页的查词控制器（扩展宿主把网页视频字幕的查词交给它）；
/// [openExtensionSettings] 由浏览页用自己的 context 推扩展设置页。
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
      storage: WebBrowserExtensionStorage(
        prefs: app.prefsRepo,
        bridged: webBrowserExtensionBridgedKeys(),
        computed: <String, Object? Function()>{
          // 扩展界面语言「跟随 Fushi」读它（扩展里由 background 从 app 响应镜像进来）。
          'appLocale': () => LocaleSettings.currentLocale.languageTag,
          // 调色板「跟随 Fushi」读它（扩展里由 background 从查词响应镜像进来）。
          'appThemeMirror': () => webBrowserExtensionThemeMirror(
            colors: app.browserExtensionThemeColors,
            dark: app.themeNotifier.isDarkMode,
          ),
        },
      ),
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
