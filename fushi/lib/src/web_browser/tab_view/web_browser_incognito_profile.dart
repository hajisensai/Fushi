import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebViewSettings;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    show AndroidWebViewProfile;

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Android 无痕标签页的独立 WebView Profile（androidx.webkit `MULTI_PROFILE`）。
///
/// 插件自带的 `incognito: true` 在 Android 上只是把**全局** CookieManager 清空——
/// 既不隔离，又会清掉普通标签页 / 漫画源的登录态。这里改成：一次无痕会话（从第一个
/// 无痕标签页打开到最后一个关闭）共用一个具名 Profile（独立 cookie / 存储 / 缓存）；
/// 下一次无痕会话换新名字，旧会话的数据不可能漏进来。
///
/// 会话结束时原生侧（`WebViewProfileManager.java`）等该 Profile 最后一个 WebView
/// 真正销毁后处理它：本进程加载过的 Profile 系统 WebView 不允许删（Chromium 实例化
/// 后永不卸载，`deleteProfile` 抛「in-use」，真机实测），所以当场清空 cookie / 网页
/// 存储，Profile 目录（含 HTTP 缓存）在下次启动探测时由 [ensureProbed] 删掉。
/// 这里只管「会话何时结束」。
///
/// 其它平台无痕由各自引擎的非持久存储完成，不经这里（[needsNamedProfile] 为 false）。
abstract interface class WebBrowserProfileBackend {
  Future<bool> isSupported();
  Future<bool> deleteProfile(String name);
  Future<List<String>> deleteUnusedProfiles(String prefix);
  Future<String?> cookieHeader(String profile, Uri url);
}

class AndroidWebBrowserProfileBackend implements WebBrowserProfileBackend {
  const AndroidWebBrowserProfileBackend();

  @override
  Future<bool> isSupported() => AndroidWebViewProfile.isSupported();

  @override
  Future<bool> deleteProfile(String name) =>
      AndroidWebViewProfile.deleteProfile(name);

  @override
  Future<List<String>> deleteUnusedProfiles(String prefix) =>
      AndroidWebViewProfile.deleteUnusedProfiles(prefix);

  @override
  Future<String?> cookieHeader(String profile, Uri url) =>
      AndroidWebViewProfile.getCookie(profile, url.toString());
}

class WebBrowserIncognitoProfiles {
  WebBrowserIncognitoProfiles({
    required WebBrowserProfileBackend backend,
    TargetPlatform Function()? platform,
    DateTime Function()? clock,
  }) : _backend = backend,
       _platform = platform ?? (() => defaultTargetPlatform),
       _clock = clock ?? DateTime.now;

  static WebBrowserIncognitoProfiles instance = WebBrowserIncognitoProfiles(
    backend: const AndroidWebBrowserProfileBackend(),
  );

  /// 本 app 建的无痕 Profile 名前缀（启动后清理崩溃遗留只认这个前缀）。
  static const String profilePrefix = 'fushi_incognito_';

  final WebBrowserProfileBackend _backend;
  final TargetPlatform Function() _platform;
  final DateTime Function() _clock;

  bool? _supported;
  Future<bool>? _probe;
  String? _session;
  int _serial = 0;

  /// 本平台的无痕要不要靠具名 Profile（只有 Android）。
  bool get needsNamedProfile => _platform() == TargetPlatform.android;

  /// 探测结果；还没探测完为 null。
  bool? get multiProfileSupported => _supported;

  /// 查一次系统 WebView 支不支持 `MULTI_PROFILE`（结果缓存）；支持时顺带删掉以前
  /// 进程留下的无痕 Profile（会话结束时本进程删不掉、只清空了数据；进程被杀时会话
  /// 根本没结束）。
  Future<bool> ensureProbed() {
    if (!needsNamedProfile) return Future<bool>.value(false);
    return _probe ??= _runProbe();
  }

  Future<bool> _runProbe() async {
    bool supported;
    try {
      supported = await _backend.isSupported();
    } on MissingPluginException {
      // 没有原生实现（单测 / 非 Android 引擎）：就是不支持，不算错误。
      supported = false;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserIncognitoProfiles.isSupported',
        error,
        stack,
      );
      supported = false;
    }
    if (supported && _session == null) {
      try {
        await _backend.deleteUnusedProfiles(profilePrefix);
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'WebBrowserIncognitoProfiles.deleteUnusedProfiles',
          error,
          stack,
        );
      }
    }
    _supported = supported;
    return supported;
  }

  /// 当前无痕会话的 Profile 名；没有会话就开一个新的。
  String sessionProfileName() => _session ??=
      '$profilePrefix${_clock().microsecondsSinceEpoch.toRadixString(36)}'
      '_${_serial++}';

  String? get currentSessionProfileName => _session;

  /// 最后一个无痕标签页关闭（或浏览页销毁）：结束本次会话的 Profile（见类注释：
  /// 本进程用过的当场清空数据、下次启动删目录）。还活着的 WebView 由原生侧等它们
  /// 销毁后再处理。
  Future<void> endSession() async {
    final String? name = _session;
    _session = null;
    if (name == null) return;
    try {
      await _backend.deleteProfile(name);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserIncognitoProfiles.deleteProfile',
        error,
        stack,
      );
    }
  }

  /// 无痕页下载要带的 Cookie 头：取本会话 Profile 自己的 cookie 罐（全局
  /// CookieManager 看不到无痕页的 cookie）。
  Future<String?> cookieHeader(Uri url) async {
    final String? name = _session;
    if (name == null) return null;
    try {
      final String? header = await _backend.cookieHeader(name, url);
      return header == null || header.isEmpty ? null : header;
    } on Object {
      return null;
    }
  }
}

/// 给标签页的 WebView 设置接上无痕：Android 把视图放进本次无痕会话的具名 Profile，
/// 插件 `incognito` 一律关（它会清全局 cookie）；其它平台照旧交给插件 `incognito`。
void applyWebBrowserIncognito(
  InAppWebViewSettings settings, {
  required bool incognito,
  WebBrowserIncognitoProfiles? profiles,
}) {
  final WebBrowserIncognitoProfiles p =
      profiles ?? WebBrowserIncognitoProfiles.instance;
  if (!p.needsNamedProfile) {
    settings.incognito = incognito;
    return;
  }
  settings.incognito = false;
  AndroidWebViewProfile.setProfileName(
    settings,
    incognito ? p.sessionProfileName() : null,
  );
}
