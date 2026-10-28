import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/i18n/strings.g.dart' show LocaleSettings;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';

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

/// 应用内浏览器扩展存储的进程内唯一实例。浏览页的扩展宿主（推给页内脚本）与「浏览器
/// 设置」里的扩展分组读写的都是它：任何一方写入，另一方经
/// [WebBrowserExtensionStorage.changes] / 监听即刻看到（宿主再推给打开着的标签页）。
final Provider<WebBrowserExtensionStorage> webBrowserExtensionStorageProvider =
    Provider<WebBrowserExtensionStorage>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      final WebBrowserExtensionStorage storage = WebBrowserExtensionStorage(
        prefs: app.prefsRepo,
        bridged: webBrowserExtensionBridgedKeys(),
        computed: <String, Object? Function()>{
          // 扩展界面语言「跟随 Fushi」读它（扩展里由 background 从 app 响应镜像进来）。
          'appLocale': () => LocaleSettings.currentLocale.languageTag,
          // 界面风格跟随 Fushi 主设置、不单独设：app 的两套设计系统都是实色面
          // （Apple 也钉了实色，见 glassMaterialTier），对应扩展的 M3E。
          'extensionStyle': () => 'm3e',
          // 调色板「跟随 Fushi」读它（扩展里由 background 从查词响应镜像进来）。
          'appThemeMirror': () => webBrowserExtensionThemeMirror(
            colors: app.browserExtensionThemeColors,
            dark: app.themeNotifier.isDarkMode,
          ),
        },
      );
      ref.onDispose(storage.dispose);
      return storage;
    });
