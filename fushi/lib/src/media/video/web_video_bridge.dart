// 内置网页播放器（WebView2 站点播放）的 JS↔Dart 契约：纯函数 / 纯数据，无 Flutter、无平台依赖。
//
// JS 侧是 `assets/web_video/web_video_glue.js`（投递 `{type:'track'|'state'|'seekDone'}`），字幕数据
// 来自与浏览器扩展共用的 `assets/browser_extension/subtitle-providers.js` store。本文件负责：
//   · 把 JS 载荷解析成页面可用的 [WebVideoTrack] / [WebVideoPlaybackState]（坏载荷回 null，不抛）；
//   · 按 host 决定注入哪几个站点 bridge（**逐条对齐扩展 manifest.json 的 matches**，别在两处各写一份）；
//   · 默认字幕轨选择（[chooseWebVideoTrackKey]）。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';

import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/webview/untrusted_page_urls.dart';

/// 内置网页播放器（app 内 WebView2 打开 Netflix / YouTube 页面并登录站点）的总开关。
///
/// 2026-09-13 用户拍板**暂时砍掉**这条入口：关掉后网页视频站的书与其它平台一样走
/// mpv 页（由其失败路径提示），导入对话框提示「暂已停用」。页面 / 桥接 / 宿主档代码
/// 原样保留，翻回 `true` 即恢复；[isWebVideoPlayerEligible] 仍独立成立，守卫测试
/// 继续钉住平台 / 站点判据不漂移。
const bool kWebVideoPlayerEnabled = true;

/// 一本流媒体书**按平台与站点判据**是否够格进内置网页播放器（不含总开关）。
///
/// 判据 = `videoPath` 命中已知网页视频站（[isKnownWebPageVideoUrl]，mpv 解不出 HTML）∧
/// 平台是 Windows（fork 的 WebView2 纹理链路只有 Windows；其它平台照旧走 mpv 页、
/// 由其失败路径提示）。[platform] 可注入以便 widget test 覆盖两端。
bool isWebVideoPlayerEligible(String url, {TargetPlatform? platform}) {
  final TargetPlatform p = platform ?? defaultTargetPlatform;
  if (kIsWeb || p != TargetPlatform.windows) return false;
  return isKnownWebPageVideoUrl(url);
}

/// 一本流媒体书是否该用内置网页播放器打开（而非 mpv 视频页）：
/// [kWebVideoPlayerEnabled] ∧ [isWebVideoPlayerEligible]。所有入口只问这一个函数。
bool shouldOpenInWebVideoPlayer(String url, {TargetPlatform? platform}) =>
    kWebVideoPlayerEnabled && isWebVideoPlayerEligible(url, platform: platform);

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

/// 网页档 Shift 悬停查词（站点页面上的任意文字，投 `{type:'pageLookup'}`）。
const String kWebVideoPageLookupAsset =
    'assets/web_video/web_video_page_lookup.js';

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

/// 全部站点 bridge 及各自的站点覆盖，**顺序即注入顺序**（[webVideoBridgeAssetsForHost] 与
/// [webVideoHostGuardedBridgeSource] 同源）。
const List<(String asset, List<String> hosts)> kWebVideoSiteBridges =
    <(String, List<String>)>[
      (kWebVideoNetflixBridgeAsset, kWebVideoNetflixHosts),
      (kWebVideoYoutubeBridgeAsset, kWebVideoYoutubeHosts),
      (kWebVideoStreamBridgeAsset, kWebVideoStreamBridgeHosts),
    ];

/// 页面里判断当前 host 是否属于 [hosts] 的 JS 表达式（与 [_hostMatches] 同一规则：`www.` 开头的
/// 条目要求完全相等，其余按「等于或以 `.<条目>` 结尾」）。
String webVideoHostMatchJs(List<String> hosts) {
  final List<String> terms = <String>[
    for (final String raw in hosts)
      if (raw.toLowerCase().startsWith('www.'))
        'h===${jsonEncode(raw.toLowerCase())}'
      else
        '(h===${jsonEncode(raw.toLowerCase())}||'
            'h.slice(-${raw.length + 1})===${jsonEncode('.${raw.toLowerCase()}')})',
  ];
  return '(function(h){return ${terms.isEmpty ? 'false' : terms.join('||')};})'
      '(String(location.hostname).toLowerCase())';
}

/// 把站点 bridge 包成「只在它自己的站点上执行」：WebView 的 document-start 脚本在建 WebView 时
/// 就定死了，按起始页 host 选 bridge 的话，用户在网页档里换到别的站（YouTube → Netflix）就一个
/// bridge 都没有。所以全部注入、各自按**当前文档**的 host 自判。用块而不是函数包裹：bridge 的顶层
/// 声明（如 stream-bridge 的 UMD 全局）要保持全局可见。
String webVideoHostGuardedBridgeSource(String source, List<String> hosts) =>
    'if (${webVideoHostMatchJs(hosts)}) {\n$source\n}\n';

/// 宿主要求「页面一开始就藏起站点自己的字幕」时，排在 glue 之前的一行开关（glue 装载即读）。
const String kWebVideoHideNativeSubtitlesPrelude =
    'window.__fushiHideNativeSubtitlesAtStart = true;';

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
    this.siteTrackId = '',
    String? languageCode,
  }) : languageCode = languageCode ?? lang;

  final String key;
  final String videoKey;

  /// store key 的语言段（不含 `~trackId`）：Netflix / textTracks 是语言码，YouTube 是站点显示名
  /// （同语言人工轨与 ASR 轨靠它区分），面板直接拿它当标签。
  final String lang;
  final List<AudioCue> cues;

  /// 站点播放器里的轨 id（[WebVideoSiteTrack.id]）；只有 Netflix 的整轨带，其它为空。
  final String siteTrackId;

  /// 语言码（`en` / `ja-JP`），语言偏好匹配只认它。glue 的 `languageCode`（providers 的
  /// fushiTrackLangCodes）；旧 glue / 没有记录时等于 [lang]。
  final String languageCode;

  bool get isLive => lang == kWebVideoLiveTrackLang;
}

/// 站点播放器里可切换的一条字幕轨（还没采到 cue；选中后由站点自己下载、bridge 截下整轨）。
@immutable
class WebVideoSiteTrack {
  const WebVideoSiteTrack({
    required this.id,
    required this.lang,
    required this.name,
    this.type = '',
    this.imageBased = false,
    this.lazySegment = '',
  });

  final String id;

  /// BCP 47。
  final String lang;

  /// 站点的显示名（「日本語」「English [CC]」）；没有为空。
  final String name;

  /// 站点的轨类型（Netflix `trackType`：`PRIMARY` / `ASSISTIVE`（CC、口述影像）…）；没有为空。
  final String type;

  /// 图片字幕：截不到文字、不能查词，只能让站点自己画。
  final bool imageBased;

  /// 非空 = providers 登记的按需加载占位轨（YouTube 等站点桥先发整份清单、只急取一条；glue 的
  /// `lzt`），值是它在 store key 里的语言段。请求走 `__fushiWebVideo.requestLazyTrack`。
  /// 空 = 站点播放器自己的轨（Netflix，glue 的 `nftt`），请求是让播放器切过去（`selectNetflixTrack`）。
  final String lazySegment;

  /// 按需加载的占位轨（见 [lazySegment]）。
  bool get isLazy => lazySegment.isNotEmpty;

  /// 辅助轨（CC / SDH 字幕、口述影像音轨）：按语言自动选轨时排在普通轨后面。
  bool get isAssistive => type.toUpperCase() == 'ASSISTIVE';

  /// 这条站点轨采到的整轨在 store 里的 key：占位轨是 `videoKey|语言段`，站点播放器轨与
  /// subtitle-providers 的 `lang~trackId` 同形。
  String storeKey(String videoKey) =>
      isLazy ? '$videoKey|$lazySegment' : '$videoKey|$lang~$id';

  @override
  bool operator ==(Object other) =>
      other is WebVideoSiteTrack &&
      other.id == id &&
      other.lang == lang &&
      other.name == name &&
      other.type == type &&
      other.imageBased == imageBased &&
      other.lazySegment == lazySegment;

  @override
  int get hashCode =>
      Object.hash(id, lang, name, type, imageBased, lazySegment);
}

/// 按语言偏好在站点轨里挑一条（P1-5 默认轨）：语言码精确 > 前缀（`ja` 命中 `ja-JP`）；同等匹配下
/// 普通轨优先于辅助轨（CC / 口述影像），可查词的文字轨优先于图片轨。没有偏好或没有匹配返回 null。
WebVideoSiteTrack? pickWebVideoSiteTrackForLanguage(
  List<WebVideoSiteTrack> tracks,
  String? preferredLanguage,
) {
  final String pref = (preferredLanguage ?? '').trim().toLowerCase();
  if (pref.isEmpty) return null;
  int rank(WebVideoSiteTrack t) {
    final String l = t.lang.toLowerCase();
    final int match = l == pref ? 0 : (l.startsWith('$pref-') ? 1 : -1);
    if (match < 0) return -1;
    return match * 4 + (t.isAssistive ? 2 : 0) + (t.imageBased ? 1 : 0);
  }

  WebVideoSiteTrack? best;
  int bestRank = 1 << 30;
  for (final WebVideoSiteTrack t in tracks) {
    final int r = rank(t);
    if (r >= 0 && r < bestRank) {
      best = t;
      bestRank = r;
    }
  }
  return best;
}

/// glue `nftt` / `nfat`：每轨一行 `id\tlang\tname\ttype\timage(1/0)`（后两列旧 glue 没有），
/// 末行 `#当前轨 id`。坏行跳过。
List<WebVideoSiteTrack> parseWebVideoSiteTracks(Object? raw) {
  if (raw is! String || raw.isEmpty) return const <WebVideoSiteTrack>[];
  final List<WebVideoSiteTrack> out = <WebVideoSiteTrack>[];
  for (final String line in raw.split('\n')) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final List<String> parts = line.split('\t');
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) continue;
    out.add(
      WebVideoSiteTrack(
        id: parts[0],
        lang: parts[1],
        name: parts.length > 2 ? parts[2] : '',
        type: parts.length > 3 ? parts[3] : '',
        imageBased: parts.length > 4 && parts[4] == '1',
      ),
    );
  }
  return out;
}

/// glue `lzt`（按需加载的占位轨，与 `nftt` 同形：`语言段\t语言码\t显示名\t\t0`，末行 `#`）：
/// 每行一条 [WebVideoSiteTrack.isLazy] 轨，id 即语言段（同一视频内唯一）。坏行跳过。
List<WebVideoSiteTrack> parseWebVideoLazySiteTracks(
  Object? raw,
) => <WebVideoSiteTrack>[
  for (final WebVideoSiteTrack t in parseWebVideoSiteTracks(raw))
    WebVideoSiteTrack(id: t.id, lang: t.lang, name: t.name, lazySegment: t.id),
];

String parseWebVideoSiteTrackCurrent(Object? raw) {
  if (raw is! String) return '';
  final int i = raw.lastIndexOf('\n#');
  if (i >= 0) return raw.substring(i + 2);
  return raw.startsWith('#') ? raw.substring(1) : '';
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
    this.volume,
    this.muted = false,
    this.buffering = false,
    this.ad = false,
    this.videoTitle = '',
    this.imageUrl = '',
    this.siteTracks = const <WebVideoSiteTrack>[],
    this.siteTrackCurrent = '',
    this.siteAudioTracks = const <WebVideoSiteTrack>[],
    this.siteAudioTrackCurrent = '',
    this.blocker = '',
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

  /// `<video>.volume`（0–1）；旧 glue / 无视频为 null。
  final double? volume;

  /// `<video>.muted`。
  final bool muted;

  /// 正在 seek 或在播但数据不够（`readyState < HAVE_FUTURE_DATA`）。
  final bool buffering;

  /// 站点正在放广告（YouTube `ad-showing`）：位置 / 时长 / 倍速 / 静音都是广告的，
  /// 不是正片的。
  final bool ad;

  /// 站点播放器给的这一集真名（YouTube 播放器数据 / Netflix 播放器标题 / og:title）；
  /// 取不到为空。
  final String videoTitle;

  /// 页面的 og:image（封面候选）；没有为空。
  final String imageUrl;

  /// 还没采到整轨、可点选加载的字幕轨（站点无关）：Netflix 是播放器自己的轨（采集是被动的，要让
  /// 播放器切到某条轨它才下载那条字幕，见 glue 的 `netflixTextTracks`）；YouTube 等是 providers
  /// 登记的按需加载占位轨（glue 的 `lazyTextTracks`，[WebVideoSiteTrack.isLazy]）。
  final List<WebVideoSiteTrack> siteTracks;

  /// 站点播放器当前开着的轨 id（[WebVideoSiteTrack.id]）；字幕关着为空。
  final String siteTrackCurrent;

  /// 站点播放器的音轨（目前只有 Netflix，glue 的 `nfat`）；其它站点为空。
  final List<WebVideoSiteTrack> siteAudioTracks;

  /// 当前音轨 id。
  final String siteAudioTrackCurrent;

  /// 播放被站点弹层打断（glue 的 `blk`）：'' 正常；`interrupt`「还在看吗？」；`error` /
  /// `error:<码>` 播放错误。非空时播放器档让位给网页档，让用户在站点页面上处理。
  final String blocker;

  bool get isBlocked => blocker.isNotEmpty;

  /// 错误码（`error:M7375` → `M7375`）；不是错误或没有码为空。
  String get blockerErrorCode =>
      blocker.startsWith('error:') ? blocker.substring(6) : '';

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
  // 语言段可能是 `lang~trackId`（Netflix 同语言多轨）：glue 已拆好就用它的，否则这里拆。
  final String segment = sep >= 0 ? key.substring(sep + 1) : 'und';
  final int tilde = segment.indexOf('~');
  final String lang =
      (raw['lang'] ?? (tilde >= 0 ? segment.substring(0, tilde) : segment))
          .toString();
  final String siteTrackId =
      (raw['trackId'] ?? (tilde >= 0 ? segment.substring(tilde + 1) : ''))
          .toString();
  final String languageCode = (raw['languageCode'] ?? '').toString();
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
  return WebVideoTrack(
    key: key,
    videoKey: videoKey,
    lang: lang,
    cues: cues,
    siteTrackId: siteTrackId,
    languageCode: languageCode.isEmpty ? null : languageCode,
  );
}

/// 解析 `{type:'state', ...}`（字段名见 glue 的 `snapshot()`）。坏形状回 null。
///
/// 页面上报的 `href` / `vimg` 是不可信数据：`href` 经 [trustedPageHref] 与 WebView 自己
/// 的地址 [webViewUrl] 对过主机才采信（它决定这一集落成哪本书），`vimg` 只收
/// [safeRemoteImageUrl] 认可的 https 远端地址（它会被下载成封面）。
WebVideoPlaybackState? parseWebVideoStatePayload(
  Object? raw, {
  String? webViewUrl,
}) {
  if (raw is! Map) return null;
  final Object? rate = raw['rate'];
  final Object? vol = raw['vol'];
  return WebVideoPlaybackState(
    href: trustedPageHref((raw['href'] ?? '').toString(), webViewUrl),
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
    volume: vol is num ? vol.toDouble().clamp(0.0, 1.0) : null,
    muted: raw['muted'] == true,
    buffering: raw['buf'] == true,
    ad: raw['ad'] == true,
    videoTitle: (raw['vtitle'] ?? '').toString().trim(),
    imageUrl:
        safeRemoteImageUrl((raw['vimg'] ?? '').toString())?.toString() ?? '',
    siteTracks: <WebVideoSiteTrack>[
      ...parseWebVideoSiteTracks(raw['nftt']),
      ...parseWebVideoLazySiteTracks(raw['lzt']),
    ],
    siteTrackCurrent: parseWebVideoSiteTrackCurrent(raw['nftt']),
    siteAudioTracks: parseWebVideoSiteTracks(raw['nfat']),
    siteAudioTrackCurrent: parseWebVideoSiteTrackCurrent(raw['nfat']),
    blocker: (raw['blk'] ?? '').toString(),
  );
}

/// glue 的 seek 回执 `{type:'seekDone', ok, err, id}`。
@immutable
class WebVideoSeekDone {
  const WebVideoSeekDone({required this.ok, required this.err, this.id});

  final bool ok;
  final String err;

  /// 发起这次 seek 时带的序号（[WebVideoPlatformPlayer] 只认最后一次的回执）；旧 glue 为 null。
  final int? id;
}

WebVideoSeekDone? parseWebVideoSeekDonePayload(Object? raw) {
  if (raw is! Map) return null;
  return WebVideoSeekDone(
    ok: raw['ok'] == true,
    err: (raw['err'] ?? '').toString(),
    id: _asInt(raw['id']),
  );
}

/// glue 的整轨抓取失败回执 `{type:'trackFailed', key, err}`：返回失败轨的 store key。
String? parseWebVideoTrackFailedKey(Object? raw) {
  if (raw is! Map) return null;
  final String key = (raw['key'] ?? '').toString();
  return key.isEmpty ? null : key;
}

/// 选当前视频要显示的字幕轨。规则（消除「用户什么都没选就没字幕」这一特殊情况）：
/// 1. [pinned]（用户显式选的轨 / 显式请求后采到的轨）仍属于当前视频且有 cue → 保持；
/// 2. 否则**每次重算**自动结果（不把上一次的自动结果当成用户选择钉住：先到的 live 轨不能挡住
///    后到的整轨）。候选只看当前 [videoKey] 的轨、且要有 cue；
/// 3. 优先 [preferredLanguage]（按 [WebVideoTrack.languageCode] 前缀匹配，`ja` 命中 `ja`/`ja-JP`；
///    显示名「日本語」不算——只认码）；
/// 4. 其次任意非 live 整轨（整集精确时间轴 > DOM 采样）；
/// 5. 最后 live 轨；一条都没有 → null。
String? chooseWebVideoTrackKey({
  required Iterable<WebVideoTrack> tracks,
  required String videoKey,
  String? preferredLanguage,
  String? pinned,
}) {
  final List<WebVideoTrack> mine = <WebVideoTrack>[
    for (final WebVideoTrack t in tracks)
      if (t.videoKey == videoKey && t.cues.isNotEmpty) t,
  ];
  if (mine.isEmpty) return null;
  if (pinned != null && mine.any((WebVideoTrack t) => t.key == pinned)) {
    return pinned;
  }
  final String? pref = preferredLanguage?.toLowerCase();
  if (pref != null && pref.isNotEmpty) {
    for (final WebVideoTrack t in mine) {
      final String l = t.languageCode.toLowerCase();
      if (!t.isLive && (l == pref || l.startsWith('$pref-'))) return t.key;
    }
  }
  for (final WebVideoTrack t in mine) {
    if (!t.isLive) return t.key;
  }
  return mine.first.key;
}
