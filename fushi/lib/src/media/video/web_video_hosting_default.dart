// 网页站点视频默认用哪种播放方式（「Fushi 播放」= [WebVideoHosting.builtin] /
// 「站点原生播放」= [WebVideoHosting.windowed]）。纯数据 / 纯函数，页面只负责读写偏好与喂状态。
//
// 规则（用户 2026-11-22 拍板）：**有 DRM、且站点原生播放实际能高于 1080p 时默认原生，其余默认
// Fushi 播放**。原生能不能高于 1080p 取决于会员档位 / 显示器与 HDCP / 片源，开播前不可知，所以分两层：
//   1. 开播前预判（这个站还没有实测结论时）：已知 DRM 站（或 Fushi 播放里实测到加密）∧ 引擎能做
//      底层合成（否则原生跑不起来）∧ 当前显示器物理高度 > 1080；
//   2. 按站点记住实测：站点原生播放里加密流的视频高度 > 1080 → 记「原生」；稳定播够
//      [kWebVideoHostingProbeSettle] 仍 ≤ 1080（或根本没加密）→ 记「Fushi」。
// 用户手动切过的（按站点）永远优先；旧的全局偏好 [kWebVideoHostingPrefKey] 也是用户手动选的，
// 原样当作对所有站点的手动选择（Never break userspace），只读不再写。
import 'dart:convert';
import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart' show BuildContext, View, WidgetsBinding;
import 'package:fushi/src/media/video/web_video_bridge.dart'
    show WebVideoPlaybackState;
import 'package:fushi/src/media/video/web_video_hosting.dart';

/// 用户手动选过的播放方式，按站点（JSON 对象 `{站点键: WebVideoHosting.name}`）。
const String kWebVideoHostingManualBySitePrefKey =
    'web_video_hosting_manual_by_site';

/// 实测学到的结论，按站点（JSON 对象 `{站点键: WebVideoHostingVerdict.name}`）。
const String kWebVideoHostingLearnedBySitePrefKey =
    'web_video_hosting_learned_by_site';

/// 高于这个视频高度才算「原生比 Fushi 播放画质高」（Fushi 播放的软件 DRM 上限是 1080p）。
const int kWebVideoHostingHighQualityHeight = 1080;

/// 站点原生播放里要实际播够这么久，才下「原生超不过 1080p」的结论（自适应码率起播时偏低、
/// 之后爬升；高于 1080 的结论则一出现就下）。
const Duration kWebVideoHostingProbeSettle = Duration(seconds: 90);

/// 开播前就知道走 DRM 的站点（注册域，含子域）。不在表里的站点在 Fushi 播放里实测到加密后
/// 记成 [WebVideoHostingVerdict.drm]，同样进预判。
const List<String> kWebVideoDrmHosts = <String>[
  'netflix.com',
  'primevideo.com',
  'amazon.com',
  'amazon.co.jp',
  'amazon.co.uk',
  'amazon.de',
  'amazon.fr',
  'amazon.it',
  'amazon.es',
  'hulu.jp',
];

/// 按站点记住的实测结论。
enum WebVideoHostingVerdict {
  /// 站点原生播放实测到加密流高于 1080p → 默认原生。
  windowed,

  /// 站点原生播放稳定播放后仍 ≤ 1080p，或根本没加密 → 默认 Fushi 播放。
  builtin,

  /// 只在 Fushi 播放里见过加密流，原生能到多少还不知道 → 当作 DRM 站进预判。
  drm,
}

/// 站点键：小写 host 去掉开头的 `www.`（`www.netflix.com` 与 `netflix.com` 同一站）。
String webVideoSiteKey(Uri uri) {
  final String host = uri.host.toLowerCase();
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// [siteKey] 是不是已知 DRM 站（本身或其子域命中 [kWebVideoDrmHosts]）。
bool isKnownDrmWebVideoSite(String siteKey) => kWebVideoDrmHosts.any(
  (String h) => siteKey == h || siteKey.endsWith('.$h'),
);

/// 解析按站点的偏好（坏值 / 非对象 / 非字符串值一律忽略，不抛）。
Map<String, String> decodeWebVideoSiteMap(Object? raw) {
  if (raw is! String || raw.isEmpty) return <String, String>{};
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, String>{};
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in decoded.entries)
        if (e.key is String && e.value is String)
          e.key! as String: e.value! as String,
    };
  } on FormatException {
    return <String, String>{};
  }
}

String encodeWebVideoSiteMap(Map<String, String> map) => jsonEncode(map);

WebVideoHosting? _hostingFromName(String? name) => switch (name) {
  'windowed' => WebVideoHosting.windowed,
  'builtin' => WebVideoHosting.builtin,
  _ => null,
};

WebVideoHostingVerdict? _verdictFromName(String? name) => switch (name) {
  'windowed' => WebVideoHostingVerdict.windowed,
  'builtin' => WebVideoHostingVerdict.builtin,
  'drm' => WebVideoHostingVerdict.drm,
  _ => null,
};

/// 这个站点此刻默认用哪种播放方式。优先级：按站点的手动选择 > 旧全局手动选择 > 按站点实测
/// （原生 / Fushi）> 开播前预判（DRM ∧ 能底层合成 ∧ 显示器高于 1080p）> Fushi 播放。
///
/// [displayHeightPx] = 当前窗口所在显示器的物理像素高度（未知传 0）。
WebVideoHosting resolveWebVideoHosting({
  required String siteKey,
  required Object? manualBySite,
  required Object? legacyGlobal,
  required Object? learnedBySite,
  required bool underlaySupported,
  required double displayHeightPx,
}) {
  final WebVideoHosting? manual = _hostingFromName(
    decodeWebVideoSiteMap(manualBySite)[siteKey],
  );
  if (manual != null) return manual;
  final WebVideoHosting? legacy = legacyGlobal is String
      ? _hostingFromName(legacyGlobal)
      : null;
  if (legacy != null) return legacy;
  final WebVideoHostingVerdict? learned = _verdictFromName(
    decodeWebVideoSiteMap(learnedBySite)[siteKey],
  );
  switch (learned) {
    case WebVideoHostingVerdict.windowed:
      return WebVideoHosting.windowed;
    case WebVideoHostingVerdict.builtin:
      return WebVideoHosting.builtin;
    case WebVideoHostingVerdict.drm:
    case null:
      break;
  }
  final bool drm =
      learned == WebVideoHostingVerdict.drm || isKnownDrmWebVideoSite(siteKey);
  return drm &&
          underlaySupported &&
          displayHeightPx > kWebVideoHostingHighQualityHeight
      ? WebVideoHosting.windowed
      : WebVideoHosting.builtin;
}

/// [resolveWebVideoHosting] 的偏好读取版（三个偏好键由这里统一取，页面只给读取函数）。
WebVideoHosting resolveWebVideoHostingFromPrefs(
  Object? Function(String key) getPref, {
  required String siteKey,
  required bool underlaySupported,
  required double displayHeightPx,
}) => resolveWebVideoHosting(
  siteKey: siteKey,
  manualBySite: getPref(kWebVideoHostingManualBySitePrefKey),
  legacyGlobal: getPref(kWebVideoHostingPrefKey),
  learnedBySite: getPref(kWebVideoHostingLearnedBySitePrefKey),
  underlaySupported: underlaySupported,
  displayHeightPx: displayHeightPx,
);

/// 当前窗口所在显示器的物理像素高度（拿不到 = 0，预判按「不高于 1080」走）。
double webVideoDisplayHeightPx(BuildContext context) {
  final FlutterView? view =
      View.maybeOf(context) ??
      WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return 0;
  try {
    return view.display.size.height;
  } on Object {
    return 0;
  }
}

/// 把探针的结论写回按站点的实测偏好（不需要写时什么都不做）。
Future<void> recordWebVideoHostingVerdict({
  required Object? Function(String key) getPref,
  required Future<void> Function(String key, Object? value) setPref,
  required String siteKey,
  required WebVideoHostingVerdict verdict,
}) async {
  if (siteKey.isEmpty) return;
  final String? next = mergeWebVideoHostingVerdict(
    getPref(kWebVideoHostingLearnedBySitePrefKey),
    siteKey,
    verdict,
  );
  if (next == null) return;
  await setPref(kWebVideoHostingLearnedBySitePrefKey, next);
}

/// 记一次用户手动选择（按站点），返回新的偏好值。
String recordManualWebVideoHosting(
  Object? manualBySite,
  String siteKey,
  WebVideoHosting hosting,
) {
  final Map<String, String> map = decodeWebVideoSiteMap(manualBySite);
  map[siteKey] = hosting.name;
  return encodeWebVideoSiteMap(map);
}

/// 把实测结论并进按站点的偏好；不需要写（没变化 / [WebVideoHostingVerdict.drm] 不覆盖已有的
/// 原生 / Fushi 结论）时返回 null。
String? mergeWebVideoHostingVerdict(
  Object? learnedBySite,
  String siteKey,
  WebVideoHostingVerdict verdict,
) {
  final Map<String, String> map = decodeWebVideoSiteMap(learnedBySite);
  final WebVideoHostingVerdict? old = _verdictFromName(map[siteKey]);
  if (old == verdict) return null;
  if (verdict == WebVideoHostingVerdict.drm && old != null) return null;
  map[siteKey] = verdict.name;
  return encodeWebVideoSiteMap(map);
}

/// 一次播放会话里的实测探针：逐拍喂站点状态，结论变化时 [observe] 返回新结论（同一结论只报一次）。
class WebVideoHostingProbe {
  WebVideoHostingProbe({required this.hosting});

  /// 这次会话实际用的播放方式（探针只在两种方式里各下各的结论）。
  final WebVideoHosting hosting;

  int _playedMs = 0;
  int? _lastPositionMs;
  String? _lastVideoKey;
  bool _sawEncrypted = false;
  WebVideoHostingVerdict? _reported;

  /// 已累计的实际播放时长（测试用）。
  Duration get played => Duration(milliseconds: _playedMs);

  WebVideoHostingVerdict? observe(WebVideoPlaybackState s) {
    final bool playing = s.hasVideo && !s.paused && !s.ad;
    final int? pos = s.positionMs;
    if (s.videoKey != _lastVideoKey) {
      _lastVideoKey = s.videoKey;
      _lastPositionMs = null;
    }
    if (playing && pos != null) {
      final int? last = _lastPositionMs;
      // 只累计正常走动的那段（跳转 / 换集 / 倒退不算播放时长）。
      if (last != null && pos > last && pos - last <= 5000) {
        _playedMs += pos - last;
      }
      _lastPositionMs = pos;
    } else {
      _lastPositionMs = null;
    }
    if (playing && s.encrypted) _sawEncrypted = true;
    final WebVideoHostingVerdict? verdict = _verdictNow(s, playing: playing);
    if (verdict == null || verdict == _reported) return null;
    _reported = verdict;
    return verdict;
  }

  WebVideoHostingVerdict? _verdictNow(
    WebVideoPlaybackState s, {
    required bool playing,
  }) {
    switch (hosting) {
      case WebVideoHosting.builtin:
        // Fushi 播放被软件 DRM 封顶，看不出原生能到多少；只记「这是 DRM 站」。
        return _sawEncrypted ? WebVideoHostingVerdict.drm : null;
      case WebVideoHosting.windowed:
        if (playing &&
            s.encrypted &&
            s.videoHeight > kWebVideoHostingHighQualityHeight) {
          return WebVideoHostingVerdict.windowed;
        }
        // 已经见过高于 1080 就不再改口（自适应码率偶尔回落不算）。
        if (_reported == WebVideoHostingVerdict.windowed) return null;
        if (_playedMs >= kWebVideoHostingProbeSettle.inMilliseconds) {
          return WebVideoHostingVerdict.builtin;
        }
        return null;
    }
  }
}
