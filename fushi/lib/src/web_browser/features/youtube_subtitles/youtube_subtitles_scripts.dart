import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'package:fushi/src/media/video/web_video_bridge.dart'
    show
        kWebVideoAdaptersAsset,
        kWebVideoProvidersAsset,
        kWebVideoYoutubeBridgeAsset,
        kWebVideoYoutubeHosts,
        webVideoHostMatchJs;

/// 消费字幕 store、在 YouTube 播放器里画可点字幕的脚本（本功能自己的资产）。
const String kWebBrowserYoutubeSubtitlesAsset =
    'assets/web_browser/youtube_subtitles.js';

/// 依次拼进脚本块的资产，**顺序即执行顺序**：youtube-bridge（取整轨）→ adapters
/// （解析器）→ providers（store）→ 本功能的字幕层。前三样直接读浏览器扩展镜像
/// `assets/browser_extension/`（与扩展、内置网页播放器逐字节同一份，镜像守卫
/// `browser_extension_mirror_full_guard_test.dart`），不另拷一份。
const List<String> kWebBrowserYoutubeSubtitlesAssets = <String>[
  kWebVideoYoutubeBridgeAsset,
  kWebVideoAdaptersAsset,
  kWebVideoProvidersAsset,
  kWebBrowserYoutubeSubtitlesAsset,
];

/// 脚本块装没装过的全局标记（同一文档只装一次：document-start 已装过时，
/// onLoadStop / 开关补装不再重复执行，免得 providers 的顶层 `const` 重复声明）。
const String kWebBrowserYoutubeSubtitlesInstalledFlag = '__fushiYtSubsBundle';

/// 把 [sources]（按 [kWebBrowserYoutubeSubtitlesAssets] 顺序读出的文本）拼成一段
/// 脚本：只在 YouTube 主机（与内置网页播放器 youtube-bridge 同一份主机清单）上、
/// 且本文档还没装过时执行。
///
/// 用块而不是函数包裹：与 `webVideoHostGuardedBridgeSource` 同理，块里的顶层函数声明
/// 照样挂到全局，providers 与 adapters 之间按名字互相调用不受影响；它们的顶层
/// `const` / `let` 只在块内可见，而跨脚本的契约本来就只走 `window.*`。
String webBrowserYoutubeSubtitlesBundle(List<String> sources) {
  final StringBuffer out = StringBuffer()
    ..write('if (${webVideoHostMatchJs(kWebVideoYoutubeHosts)} && ')
    ..write('!window.$kWebBrowserYoutubeSubtitlesInstalledFlag) {\n')
    ..write('window.$kWebBrowserYoutubeSubtitlesInstalledFlag = true;\n');
  for (final String source in sources) {
    out
      ..write(source)
      ..write('\n;\n');
  }
  out.write('}\n');
  return out.toString();
}

/// 开 / 关页面里的字幕层（字幕层没装时什么也不做）。选哪条轨不由 Dart 决定：字幕层按
/// 浏览器扩展同一份规则（subtitle-adapters.js `fushiListSubtitleTracks` /
/// `fushiResolveActiveSubtitleTrack`）自己选，用户可在「⋯ › 字幕轨」里换。
String webBrowserYoutubeSubtitlesToggleScript({required bool enabled}) =>
    'if (window.__fushiYtSubs) window.__fushiYtSubs.setEnabled($enabled);';

/// 读当前视频的字幕轨列表（JSON 字符串；字幕层没装 → `null`）。形状与扩展
/// `fushiSubtitleTrackList` 同：`{active, tracks: [{lang, label, live, length, pending}]}`。
const String kWebBrowserYoutubeSubtitlesTrackListScript =
    'window.__fushiYtSubs ? JSON.stringify(window.__fushiYtSubs.trackList()) : null';

/// 选中 [lang]（轨列表里的 `lang`）为活动轨；回 bool（轨不在 → false）。
String webBrowserYoutubeSubtitlesSelectTrackScript(String lang) =>
    'window.__fushiYtSubs ? window.__fushiYtSubs.selectTrack(${jsonEncode(lang)}) : false';

/// 页面里字幕层装好了没有（`evaluateJavascript` 回 bool）。
const String kWebBrowserYoutubeSubtitlesInstalledProbe =
    '!!window.$kWebBrowserYoutubeSubtitlesInstalledFlag';

/// 从资产包读 [kWebBrowserYoutubeSubtitlesAssets] 并拼好脚本块。[loadAsset] 是测试
/// 注入口（默认 [rootBundle]）。资产读取失败直接抛。
Future<String> loadWebBrowserYoutubeSubtitlesBundle({
  Future<String> Function(String asset)? loadAsset,
}) async {
  final Future<String> Function(String) load =
      loadAsset ?? rootBundle.loadString;
  return webBrowserYoutubeSubtitlesBundle(<String>[
    for (final String asset in kWebBrowserYoutubeSubtitlesAssets)
      await load(asset),
  ]);
}
