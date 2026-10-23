import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_bridge.dart'
    show kWebVideoYoutubeHosts;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/features/youtube_subtitles/youtube_subtitles_scripts.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/utils.dart';

/// 开关的持久化键（设备本地偏好，不进备份 / 同步）。
const String kWebBrowserYoutubeSubtitlesPref = 'web_browser_youtube_subtitles';
const bool kWebBrowserYoutubeSubtitlesDefault = true;

/// [uri] 是不是 YouTube 页面（与 youtube-bridge 的主机清单同一规则）。
bool isWebBrowserYoutubePage(Uri? uri) {
  if (uri == null) return false;
  String host = uri.host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty) return false;
  return kWebVideoYoutubeHosts.any(
    (String h) => host == h || host.endsWith('.$h'),
  );
}

/// 网页内 YouTube 字幕查词：在 YouTube 播放器里画一行可点的字幕，点字走浏览页现有的
/// 查词链路（阅读器选区脚本 → `onTextSelected` → 复习卡面那套查词弹窗）。
///
/// 字幕获取完全复用浏览器扩展的 youtube-bridge + subtitle-adapters + subtitle-providers
/// （见 [kWebBrowserYoutubeSubtitlesAssets]），本功能只多一个消费 store 的字幕层脚本。
/// 「⋯」菜单里的开关记在设备本地偏好里，关掉后新打开的文档不再注入脚本、已打开的页面
/// 立即收起字幕层并还原站点自己的字幕。
class YoutubeSubtitlesFeature extends WebBrowserFeature {
  YoutubeSubtitlesFeature({
    required PrefStore prefs,
    Future<String> Function(String asset)? loadAsset,
  }) : _prefs = prefs {
    _bundleLoad = loadWebBrowserYoutubeSubtitlesBundle(loadAsset: loadAsset)
        .then<String?>(
          (String bundle) => _bundle = bundle,
          onError: (Object e, StackTrace stack) {
            debugPrint('[web-browser] youtube subtitles assets: $e');
            return null;
          },
        );
  }

  final PrefStore _prefs;
  late final Future<String?> _bundleLoad;
  String? _bundle;

  /// 建过 WebView 的标签页（开关切换时同步到每个开着 YouTube 的页）。
  final Map<String, WebBrowserTab> _tabs = <String, WebBrowserTab>{};

  @override
  String get id => 'youtube_subtitles';

  bool get enabled {
    final Object? raw = _prefs.getPref(
      kWebBrowserYoutubeSubtitlesPref,
      defaultValue: kWebBrowserYoutubeSubtitlesDefault,
    );
    return raw is bool ? raw : kWebBrowserYoutubeSubtitlesDefault;
  }

  /// 测试用：资产读完（或读失败）。
  @visibleForTesting
  Future<String?> get bundleReady => _bundleLoad;

  @override
  List<UserScript> userScripts() {
    final String? bundle = _bundle;
    // 资产还没读完（WebView 建得比读资产快）时由 onLoadStop 补装；关着时不注入，
    // 免得 youtube-bridge 白白去取字幕。
    if (bundle == null || !enabled) return const <UserScript>[];
    return <UserScript>[
      UserScript(
        source:
            '$bundle\n${webBrowserYoutubeSubtitlesToggleScript(enabled: true)}',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ];
  }

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    _tabs[tab.id] = tab;
  }

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) async {
    _tabs[tab.id] = tab;
    if (!isWebBrowserYoutubePage(url ?? tab.url)) return;
    await _apply(controller, enabled: enabled);
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    _tabs.remove(tab.id);
  }

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    if (!isWebBrowserYoutubePage(tab.url)) return const <WebBrowserAction>[];
    final bool on = enabled;
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'youtube_subtitles',
        icon: on ? FushiIcons.subtitles : FushiIcons.subtitlesOff,
        label: t.web_browser_youtube_subtitles,
        selected: on,
        onPressed: () => unawaited(setEnabled(!on)),
      ),
    ];
  }

  /// 切换开关：落偏好，并同步到每个打开着 YouTube 的标签页。
  Future<void> setEnabled(bool value) async {
    await _prefs.setPref(kWebBrowserYoutubeSubtitlesPref, value);
    await Future.wait(<Future<void>>[
      for (final WebBrowserTab tab in _tabs.values.toList())
        if (tab.controller != null && isWebBrowserYoutubePage(tab.url))
          _apply(tab.controller!, enabled: value),
    ]);
  }

  /// 开：没装过就补装脚本块（块自己判主机与是否已装），再打开字幕层；关：只收起字幕层。
  Future<void> _apply(
    InAppWebViewController controller, {
    required bool enabled,
  }) async {
    try {
      if (enabled) {
        final Object? installed = await controller.evaluateJavascript(
          source: kWebBrowserYoutubeSubtitlesInstalledProbe,
        );
        if (installed != true) {
          final String? bundle = await _bundleLoad;
          if (bundle == null) return;
          await controller.evaluateJavascript(source: bundle);
        }
      }
      await controller.evaluateJavascript(
        source: webBrowserYoutubeSubtitlesToggleScript(enabled: enabled),
      );
    } catch (e) {
      // 标签页正在导航 / WebView 已销毁：下次 onLoadStop 再同步。
      debugPrint('[web-browser] youtube subtitles apply: $e');
    }
  }

  @override
  void dispose() {
    _tabs.clear();
  }
}
