import 'dart:async';
import 'dart:convert';

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
///
/// 选轨与浏览器扩展**同一份规则**（扩展 subtitle-adapters.js 的共享纯函数，字幕层直接调）：
/// 扩展没有字幕语言偏好，所以这里也不下发任何语言；用户要看别的轨，在「⋯ › 字幕轨」里换
/// （= 扩展播放器内嵌菜单的轨页）。
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
            '$bundle\n'
            '${webBrowserYoutubeSubtitlesToggleScript(enabled: true)}',
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
      if (on)
        WebBrowserAction(
          id: 'youtube_subtitles_track',
          icon: FushiIcons.language,
          label: t.video_menu_subtitle_track,
          onPressed: () => unawaited(pickTrack(context, tab)),
        ),
    ];
  }

  /// 读 [tab] 页里当前视频的字幕轨；字幕层没装 / 页面在导航 → null。
  Future<WebBrowserYoutubeSubtitleTracks?> readTracks(WebBrowserTab tab) async {
    final InAppWebViewController? controller = tab.controller;
    if (controller == null) return null;
    try {
      final Object? raw = await controller.evaluateJavascript(
        source: kWebBrowserYoutubeSubtitlesTrackListScript,
      );
      return raw is String ? parseWebBrowserYoutubeSubtitleTracks(raw) : null;
    } catch (e) {
      debugPrint('[web-browser] youtube subtitles tracks: $e');
      return null;
    }
  }

  /// 「⋯ › 字幕轨」：列出当前视频的轨（与扩展播放器菜单的轨页同一份数据与次序），选中即换。
  Future<void> pickTrack(BuildContext context, WebBrowserTab tab) async {
    final WebBrowserYoutubeSubtitleTracks? info = await readTracks(tab);
    if (!context.mounted) return;
    final List<WebBrowserYoutubeSubtitleTrack> tracks =
        info?.tracks ?? const <WebBrowserYoutubeSubtitleTrack>[];
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.video_menu_subtitle_track,
      icon: FushiIcons.subtitles,
      message: tracks.isEmpty
          ? t.web_browser_youtube_subtitles_track_empty
          : null,
      selected: info?.active,
      options: <FushiChoiceOption<String>>[
        for (final WebBrowserYoutubeSubtitleTrack track in tracks)
          FushiChoiceOption<String>(
            value: track.lang,
            label: track.live
                ? t.web_browser_youtube_subtitles_track_live
                : track.label,
            subtitle: track.pending
                ? t.web_browser_youtube_subtitles_track_pending
                : null,
          ),
      ],
    );
    if (picked == null || picked == info?.active) return;
    try {
      await tab.controller?.evaluateJavascript(
        source: webBrowserYoutubeSubtitlesSelectTrackScript(picked),
      );
    } catch (e) {
      debugPrint('[web-browser] youtube subtitles select track: $e');
    }
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

/// 字幕层报上来的一条轨（与扩展 `fushiSubtitleTrackList` 的轨同形）。
@immutable
class WebBrowserYoutubeSubtitleTrack {
  const WebBrowserYoutubeSubtitleTrack({
    required this.lang,
    required this.label,
    required this.live,
    required this.pending,
    required this.length,
  });

  /// store key 的语言段（选轨时原样传回）。
  final String lang;

  /// 站点显示名（live 轨由界面本地化，这里是 [lang]）。
  final String label;
  final bool live;

  /// 占位轨（清单已到、cue 未取，选中后按需加载）。
  final bool pending;

  /// 已加载的句数。
  final int length;
}

/// 当前视频的轨列表 + 活动轨。
@immutable
class WebBrowserYoutubeSubtitleTracks {
  const WebBrowserYoutubeSubtitleTracks({
    required this.active,
    required this.tracks,
  });

  final String? active;
  final List<WebBrowserYoutubeSubtitleTrack> tracks;
}

/// 解析 [kWebBrowserYoutubeSubtitlesTrackListScript] 回的 JSON；形状不对 → null。
WebBrowserYoutubeSubtitleTracks? parseWebBrowserYoutubeSubtitleTracks(
  String raw,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final Object? list = decoded['tracks'];
  if (list is! List<dynamic>) return null;
  final List<WebBrowserYoutubeSubtitleTrack> tracks =
      <WebBrowserYoutubeSubtitleTrack>[];
  for (final Object? item in list) {
    if (item is! Map<String, dynamic>) continue;
    final Object? lang = item['lang'];
    if (lang is! String || lang.isEmpty) continue;
    final Object? label = item['label'];
    final Object? length = item['length'];
    tracks.add(
      WebBrowserYoutubeSubtitleTrack(
        lang: lang,
        label: label is String && label.isNotEmpty ? label : lang,
        live: item['live'] == true,
        pending: item['pending'] == true,
        length: length is num ? length.toInt() : 0,
      ),
    );
  }
  final Object? active = decoded['active'];
  return WebBrowserYoutubeSubtitleTracks(
    active: active is String ? active : null,
    tracks: tracks,
  );
}
