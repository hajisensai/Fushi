import 'dart:typed_data';

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// 一次扩展调用（桌面 `/dalvik` POST / Android method channel）在 Dart 侧放手的上界。
///
/// **必须大于宿主自己的 OkHttp `callTimeout`**（两端都是 2 分钟：桌面
/// `third_party/m_extension_server/overlay/server/src/main/kotlin/eu/kanade/tachiyomi/
/// network/NetworkHelper.kt`，Android `fushi/android/app/src/main/kotlin/eu/kanade/
/// tachiyomi/network/NetworkHelper.kt`）。此前桌面钉的是 45 秒——比宿主自己的预算还
/// 短，于是慢站点必然先撞 Dart 这一层：JVM 里那次请求还在跑，Dart 已经把它报成
/// `BRIDGE_TIMEOUT`，真正的失败原因（HTTP 状态码 / 解析异常 / 哪个 hoster 死了）永远
/// 到不了用户面前。取流是这条链路上最重的一步（展开 hoster、逐条解析候选，每次都是
/// 一轮真实 HTTP），45 秒对在线视频源等于「点开必失败」（BUG-2617）。
///
/// 参照物一概没有这层闸：Aniyomi 的 `EpisodeLoader` / `HosterLoader` 对扩展调用是裸
/// `await`，Mangayomi 到同一个 sidecar 的 POST 也没有 `.timeout()`——两家都只靠 OkHttp
/// 的 per-call 预算收口。本仓保留一个上界只为兜住「桥真卡死」（JVM 僵死 / 管道断了但
/// 连接没关），所以取值是「宿主上界 + 余量」而不是一个更激进的产品化超时。
const Duration kMihonBridgeRequestTimeout = Duration(seconds: 150);

abstract interface class MihonRuntime {
  Future<MihonCapabilities> getCapabilities();

  Future<MihonExtensionInspection> inspectExtension(String apkPath);

  /// Android 把 APK 原子复制到 app 私有 `.ext` 目录；桌面实现返回原路径，
  /// 由上层的跨平台安装仓库负责原子替换。
  Future<String> installPrivateExtension(String apkPath);

  Future<void> uninstallPrivateExtension(String packageName);

  Future<List<MihonSource>> listSources(
    MihonExtensionRef extension, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonFilter>> getFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonMangaPage> getPopular(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonMangaPage> getLatest(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonMangaPage> search(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonPage>> getPages(
    MihonExtensionRef extension,
    MihonSource source,
    MihonChapter chapter, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  /// Fetches a cover or other source-owned image with the extension's
  /// OkHttp client. Callers must not use a plain HTTP client because that
  /// would drop extension interceptors, cookies, and per-request headers.
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonPreference>> getPreferences(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> persisted = const <MihonPreference>[],
  });

  Future<List<MihonPreference>> setPreference(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPreference preference, {
    required List<MihonPreference> persisted,
  });

  Future<void> clearSourceData(MihonExtensionRef extension, MihonSource source);

  Future<void> invalidateExtension(String packageName);

  /// 一次失效**一批**扩展。
  ///
  /// 存在的理由是桌面端：那边失效的唯一手段是重启 Java sidecar（class loader 一旦
  /// 加载过某个 APK 就不会重读），逐个调等于批量安装 N 个扩展就重启 N 次进程——
  /// 一次几秒，装一百个光重启就是十几分钟，中途每次重启还会把正在浏览的源打断。
  /// Android 端没有这个代价，逐个调即可。
  Future<void> invalidateExtensions(Iterable<String> packageNames);

  Future<void> dispose();
}

/// Aniyomi（视频）扩展的调用面。
///
/// 与 [MihonRuntime] 的漫画方法逐一对应，只是 wire 方法名与模型不同
/// （`sourcesAnime` / `getEpisodeList` / `getVideoList` …）；扩展安装、信任、
/// 偏好、代理、Cloudflare、图片取图（[MihonRuntime.fetchSourceImage]）全部
/// 复用同一个运行时实例。独立成接口而不是往 [MihonRuntime] 上加方法，是让
/// 既有的十来个测试 fake 不必跟着实现；生产的两个实现（桌面 sidecar / Android
/// 原生）都经 [MihonBridgeRuntime] 天然具备，调用方用 `runtime is
/// AnimeMihonRuntime` 判能力。
abstract interface class AnimeMihonRuntime {
  Future<List<MihonSource>> listAnimeSources(
    MihonExtensionRef extension, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonFilter>> getAnimeFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonAnimePage> getPopularAnime(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonAnimePage> getLatestAnime(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonAnimePage> searchAnime(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonAnime> getAnimeDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonAnime anime, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonEpisode>> getEpisodes(
    MihonExtensionRef extension,
    MihonSource source,
    MihonAnime anime, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  /// 一集的全部可播候选（画质 / hoster），空列表表示源解析不出流。
  Future<List<MihonVideo>> getVideos(
    MihonExtensionRef extension,
    MihonSource source,
    MihonEpisode episode, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonPreference>> getAnimePreferences(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> persisted = const <MihonPreference>[],
  });

  Future<List<MihonPreference>> setAnimePreference(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPreference preference, {
    required List<MihonPreference> persisted,
  });
}

/// 作品在源站的网页地址（Mihon `HttpSource.getMangaUrl` / Aniyomi
/// `AnimeHttpSource.getAnimeUrl`）：详情页「在网站打开」入口用。
///
/// 独立成可选能力而不是往 [MihonRuntime] 上加方法，理由同 [AnimeMihonRuntime]：
/// 既有的测试 fake 不必跟着实现。两个生产实现都经 [MihonBridgeRuntime] 具备；
/// 调用方一律走 `resolveMihonMangaWebUrl` / `resolveMihonAnimeWebUrl`
/// （`mihon_web_url.dart`），运行时没这能力或源报错时那边回落到
/// `baseUrl + url` 拼接（Mihon 默认实现就是详情请求的 URL，多数源等价）。
abstract interface class MihonWebUrlRuntime {
  Future<String> getMangaWebUrl(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<String> getAnimeWebUrl(
    MihonExtensionRef extension,
    MihonSource source,
    MihonAnime anime, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });
}

/// Optional runtime capability used by the online reader to abort image
/// requests when a chapter is closed. Implementations must cancel the
/// underlying HTTP/OkHttp operation, not only discard its eventual result.
abstract interface class CancellableMihonRuntime {
  Future<Uint8List> fetchImageRequest(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    required String requestId,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<void> cancelImageRequests(Iterable<String> requestIds);
}

/// Interactive verification is opt-in; background source requests only report
/// a challenge and must never open an Activity themselves.
abstract interface class ChallengeMihonRuntime {
  Future<void> solveCloudflare(Uri uri, {String? userAgent});
}

/// 宿主自己持有源站登录 cookie 的运行时（桌面 sidecar，BUG-2425）。
///
/// cookie 的真值落在宿主的 [cookieJar] 里，每次调用重新注入 sidecar；在 app 内
/// 浏览器登录完必须**导出**到 jar 才对扩展生效。Android **刻意不实现**——那边
/// 系统 `CookieManager` 才是唯一所有者，宿主再存一份只会两份打架；它实现的是
/// [BrowserCookieMihonRuntime]。
///
/// UI 用 `is HostCookieMihonRuntime` / `is BrowserCookieMihonRuntime` 判断登录页
/// 该怎么收尾，而不是写 `Platform.isAndroid`：判据是「谁拥有 cookie」这个能力，
/// 不是操作系统。
abstract interface class HostCookieMihonRuntime {
  MangaCookieJar get cookieJar;
}

/// 源站 cookie 由**平台浏览器**持有、扩展直接读同一份的运行时（Android：扩展的
/// okhttp 经 `AndroidCookieJar` 读系统 `CookieManager`，app 内 WebView 写的也是它，
/// BUG-2479）。
///
/// 这类运行时同样能「在 app 里登录源站」，只是登录完**什么都不用导出**：关掉
/// 登录页那一刻扩展就已经看得到会话。与 [HostCookieMihonRuntime] 互斥。
abstract interface class BrowserCookieMihonRuntime {}

Map<String, Object?> mihonBridgeContext(
  MihonSource source, {
  String? changedPreferenceKey,
}) => <String, Object?>{
  'key': '__mangatan_bridge_context__',
  'sourceId': source.id,
  if (changedPreferenceKey != null)
    'changedPreferenceKey': changedPreferenceKey,
};

List<Map<String, Object?>> mihonBridgePreferences(
  MihonSource source,
  List<MihonPreference> preferences, {
  String? changedPreferenceKey,
}) => <Map<String, Object?>>[
  mihonBridgeContext(source, changedPreferenceKey: changedPreferenceKey),
  ...preferences.map((MihonPreference preference) => preference.toBridgeJson()),
];
