import 'dart:typed_data';

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

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
