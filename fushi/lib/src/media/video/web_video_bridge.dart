// 内置网页播放器（WebView2 站点播放）的 JS↔Dart 契约：纯函数 / 纯数据，无 Flutter、无平台依赖。
//
// JS 侧是 `assets/web_video/web_video_glue.js`（投递 `{type:'track'|'state'|'seekDone'}`），字幕数据
// 来自与浏览器扩展共用的 `assets/browser_extension/subtitle-providers.js` store。本文件负责：
//   · 把 JS 载荷解析成页面可用的 [WebVideoTrack] / [WebVideoPlaybackState]（坏载荷回 null，不抛）；
//   · 按 host 决定注入哪几个站点 bridge（**逐条对齐扩展 manifest.json 的 matches**，别在两处各写一份）；
//   · 默认字幕轨选择（[chooseWebVideoTrackKey]）。
import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';

import 'package:fushi/src/media/video/url_stream_video.dart';

/// 一本流媒体书是否该用内置网页播放器打开（而非 mpv 视频页）。
///
/// 判据 = `videoPath` 命中已知网页视频站（[isKnownWebPageVideoUrl]，mpv 解不出 HTML）∧
/// 平台是 Windows（fork 的 WebView2 纹理链路只有 Windows；其它平台照旧走 mpv 页、
/// 由其失败路径提示）。[platform] 可注入以便 widget test 覆盖两端。
bool shouldOpenInWebVideoPlayer(String url, {TargetPlatform? platform}) {
  final TargetPlatform p = platform ?? defaultTargetPlatform;
  if (kIsWeb || p != TargetPlatform.windows) return false;
  return isKnownWebPageVideoUrl(url);
}

/// 扩展 manifest 里三个主世界 bridge 的站点覆盖（`tools/browser-extension/manifest.json`
/// `content_scripts[].matches`）。app 内没有 manifest 的按站分发，这里手动对齐；守卫测试
/// `test/media/video/web_video_bridge_test.dart` 把两边逐条比对。
const List<String> kWebVideoNetflixHosts = <String>['netflix.com'];
const List<String> kWebVideoYoutubeHosts = <String>['youtube.com'];
const List<String> kWebVideoStreamBridgeHosts = <String>[
  'tver.jp',
  'bilibili.tv',
  'www.hulu.jp',
  'primevideo.com',
  'amazon.com',
  'amazon.co.jp',
  'amazon.co.uk',
  'amazon.de',
  'amazon.fr',
  'amazon.it',
  'amazon.es',
];

/// 扩展镜像资产根（`assets/browser_extension/`）里各文件的资产路径。
const String kWebVideoAdaptersAsset =
    'assets/browser_extension/subtitle-adapters.js';
const String kWebVideoProvidersAsset =
    'assets/browser_extension/subtitle-providers.js';
const String kWebVideoNetflixBridgeAsset =
    'assets/browser_extension/netflix-bridge.js';
const String kWebVideoStreamBridgeAsset =
    'assets/browser_extension/stream-bridge.js';
const String kWebVideoYoutubeBridgeAsset =
    'assets/browser_extension/youtube-bridge.js';
const String kWebVideoGlueAsset = 'assets/web_video/web_video_glue.js';

/// 软件 DRM 档 EME 垫片（拒 PlayReady、Widevine 降软件级），仅制卡 / 增强环境用；须与
/// [kWebVideoChromeUserAgent] 配对，否则 Netflix 被拒后不试 Widevine。
const String kWebVideoEmeShimAsset = 'assets/web_video/web_video_eme_shim.js';

/// 去掉 `Edg/` 标记的 Chrome UA（版本号与随包 WebView2 运行时同代即可；站点只看有没有 Edg）。
const String kWebVideoChromeUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

/// DOM 采样 live 轨的语言标签（与 `subtitle-providers.js` 的 `FUSHI_LIVE_LANG` 同值）。
const String kWebVideoLiveTrackLang = 'live';

bool _hostMatches(String host, String pattern) {
  final String h = host.toLowerCase();
  final String p = pattern.toLowerCase();
  // `www.hulu.jp` 这种带子域的条目要求完全相等（manifest 里也没有 `*.`）；其余按
  // 「等于或以 `.<条目>` 结尾」匹配 `*://*.<条目>/*`。
  if (p.startsWith('www.')) return h == p;
  return h == p || h.endsWith('.$p');
}

/// 按 [host] 决定要注入的站点 bridge 资产，**顺序即注入顺序**，全部在 adapters/providers
/// 之前（bridge 必须先注册 `replayCues` 监听，providers 装载时才会请求重放）。不命中任何
/// 站点时为空（通用 textTracks 收割 + DOM 采样仍由 providers 提供）。
List<String> webVideoBridgeAssetsForHost(String host) {
  final List<String> out = <String>[];
  if (kWebVideoNetflixHosts.any((String h) => _hostMatches(host, h))) {
    out.add(kWebVideoNetflixBridgeAsset);
  }
  if (kWebVideoYoutubeHosts.any((String h) => _hostMatches(host, h))) {
    out.add(kWebVideoYoutubeBridgeAsset);
  }
  if (kWebVideoStreamBridgeHosts.any((String h) => _hostMatches(host, h))) {
    out.add(kWebVideoStreamBridgeAsset);
  }
  return out;
}

/// 一条字幕轨：store key（`videoKey|lang`）+ 已转成 [AudioCue] 的整轨（按 startMs 升序，
/// 由 providers 保证）。
class WebVideoTrack {
  const WebVideoTrack({
    required this.key,
    required this.videoKey,
    required this.lang,
    required this.cues,
  });

  final String key;
  final String videoKey;
  final String lang;
  final List<AudioCue> cues;

  bool get isLive => lang == kWebVideoLiveTrackLang;
}

/// 页面 JS 轮询上报的播放态快照。
class WebVideoPlaybackState {
  const WebVideoPlaybackState({
    required this.href,
    required this.videoKey,
    required this.hasVideo,
    required this.positionMs,
    required this.paused,
    required this.durationMs,
    required this.videoWidth,
    required this.videoHeight,
    required this.rate,
    required this.fullscreen,
    required this.title,
  });

  final String href;
  final String videoKey;
  final bool hasVideo;
  final int? positionMs;
  final bool paused;
  final int? durationMs;
  final int videoWidth;
  final int videoHeight;
  final double rate;
  final bool fullscreen;
  final String title;

  bool get isPlaying => hasVideo && !paused;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  return null;
}

/// 解析 `{type:'track', key, videoKey, lang, cues:[{s,e,t}]}`。[bookUid] 写进每条 cue 的
/// `bookKey`（收藏句 / 制卡锚点按 bookUid 归属）；`chapterHref` 存轨 key，`sentenceIndex`
/// 即轨内序号。坏形状回 null。
WebVideoTrack? parseWebVideoTrackPayload(
  Object? raw, {
  required String bookUid,
}) {
  if (raw is! Map) return null;
  final String key = (raw['key'] ?? '').toString();
  if (key.isEmpty) return null;
  final Object? rawCues = raw['cues'];
  if (rawCues is! List) return null;
  final int sep = key.indexOf('|');
  final String videoKey =
      (raw['videoKey'] ?? (sep >= 0 ? key.substring(0, sep) : key)).toString();
  final String lang =
      (raw['lang'] ?? (sep >= 0 ? key.substring(sep + 1) : 'und')).toString();
  final List<AudioCue> cues = <AudioCue>[];
  for (final Object? item in rawCues) {
    if (item is! Map) continue;
    final int? s = _asInt(item['s']);
    final int? e = _asInt(item['e']);
    final String text = (item['t'] ?? '').toString().trim();
    if (s == null || e == null || text.isEmpty) continue;
    cues.add(
      AudioCue()
        ..bookKey = bookUid
        ..chapterHref = key
        ..sentenceIndex = cues.length
        ..textFragmentId = ''
        ..text = text
        ..startMs = s
        ..endMs = e < s ? s : e
        ..audioFileIndex = 0,
    );
  }
  return WebVideoTrack(key: key, videoKey: videoKey, lang: lang, cues: cues);
}

/// 解析 `{type:'state', ...}`（字段名见 glue 的 `snapshot()`）。坏形状回 null。
WebVideoPlaybackState? parseWebVideoStatePayload(Object? raw) {
  if (raw is! Map) return null;
  final Object? rate = raw['rate'];
  return WebVideoPlaybackState(
    href: (raw['href'] ?? '').toString(),
    videoKey: (raw['videoKey'] ?? '').toString(),
    hasVideo: raw['hasVideo'] == true,
    positionMs: _asInt(raw['t']),
    paused: raw['paused'] != false,
    durationMs: _asInt(raw['dur']),
    videoWidth: _asInt(raw['vw']) ?? 0,
    videoHeight: _asInt(raw['vh']) ?? 0,
    rate: rate is num ? rate.toDouble() : 1.0,
    fullscreen: raw['fs'] == true,
    title: (raw['title'] ?? '').toString(),
  );
}

/// 选当前视频要显示的字幕轨。规则（消除「用户什么都没选就没字幕」这一特殊情况）：
/// 1. 用户已选且仍属于当前视频 → 保持；
/// 2. 候选只看当前 [videoKey] 的轨、且要有 cue；
/// 3. 优先 [preferredLanguage]（语言码前缀匹配，`ja` 命中 `ja`/`ja-JP`/`日本語` 不算——只认码）；
/// 4. 其次任意非 live 整轨（整集精确时间轴 > DOM 采样）；
/// 5. 最后 live 轨；一条都没有 → null。
String? chooseWebVideoTrackKey({
  required Iterable<WebVideoTrack> tracks,
  required String videoKey,
  String? preferredLanguage,
  String? current,
}) {
  final List<WebVideoTrack> mine = <WebVideoTrack>[
    for (final WebVideoTrack t in tracks)
      if (t.videoKey == videoKey && t.cues.isNotEmpty) t,
  ];
  if (mine.isEmpty) return null;
  if (current != null && mine.any((WebVideoTrack t) => t.key == current)) {
    return current;
  }
  final String? pref = preferredLanguage?.toLowerCase();
  if (pref != null && pref.isNotEmpty) {
    for (final WebVideoTrack t in mine) {
      final String l = t.lang.toLowerCase();
      if (!t.isLive && (l == pref || l.startsWith('$pref-'))) return t.key;
    }
  }
  for (final WebVideoTrack t in mine) {
    if (!t.isLive) return t.key;
  }
  return mine.first.key;
}
