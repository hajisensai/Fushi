// 内置网页播放器的两种宿主档（用户可选）与「窗口宿主档」专用的 JS↔Dart 契约。纯数据 / 纯函数。
//
// · [WebVideoHosting.builtin]（默认）：fork 的 composition + WGC 纹理链路，软件 DRM 1080p，帧可捕获
//   → Flutter 字幕叠层 / 弹窗查词 / 超分 / 自动制卡全部可用。
// · [WebVideoHosting.windowed]：WebView2 挂成真 HWND 子窗口自己绘制（硬件 PlayReady，Netflix 到
//   2160p），Flutter 画不到它上面 → 字幕层注入页面 DOM（`web_video_dom_subtitles.js`），点词经
//   callHandler 回 Dart，查词卡走独立顶层窗口（GlobalLookupController），制卡只入队、之后切回
//   内置档重放（P3）。
import 'dart:ui' show Offset, Rect;

enum WebVideoHosting { builtin, windowed }

/// 偏好键（值为 [WebVideoHosting.name]；缺省 / 未知值 = builtin，Never break userspace）。
const String kWebVideoHostingPrefKey = 'web_video_hosting';

WebVideoHosting webVideoHostingFromPref(Object? raw) =>
    raw == WebVideoHosting.windowed.name
    ? WebVideoHosting.windowed
    : WebVideoHosting.builtin;

/// fork 识别「本环境的 WebView 用窗口宿主」的哨兵（`WebViewEnvironment::kWindowedHostingSentinel`），
/// 放进 `additionalBrowserArguments`；Chromium 忽略未知开关。守卫测试比对两侧字面量。
const String kWebVideoWindowedHostingSentinel = '--fushi-windowed-hosting';

const String kWebVideoDomSubtitlesAsset =
    'assets/web_video/web_video_dom_subtitles.js';

/// DOM 字幕层点词载荷 `{type:'lookup', kind, sentence, index, cueStart, cueEnd, rect:{x,y,w,h},
/// screenX, screenY, dpr}`：`rect` 是被点字形的视口矩形（CSS px），`screenX/Y` 是页面视口在屏幕上
/// 的位置（Chromium 给的是 DIP，与 Windows 逻辑 px 同单位）。
class WebVideoLookupRequest {
  const WebVideoLookupRequest({
    required this.kind,
    required this.sentence,
    required this.graphemeIndex,
    required this.cueStartMs,
    required this.cueEndMs,
    required this.clientRect,
    required this.screenX,
    required this.screenY,
  });

  /// `click` / `hover`。
  final String kind;
  final String sentence;
  final int graphemeIndex;
  final int cueStartMs;
  final int cueEndMs;
  final Rect clientRect;
  final double screenX;
  final double screenY;

  bool get isHover => kind == 'hover';
}

double? _asDouble(Object? v) => v is num ? v.toDouble() : null;

WebVideoLookupRequest? parseWebVideoLookupPayload(Object? raw) {
  if (raw is! Map) return null;
  final String sentence = raw['sentence']?.toString() ?? '';
  final Object? index = raw['index'];
  final Object? rect = raw['rect'];
  if (sentence.isEmpty || index is! num || rect is! Map) return null;
  final double? x = _asDouble(rect['x']);
  final double? y = _asDouble(rect['y']);
  final double? w = _asDouble(rect['w']);
  final double? h = _asDouble(rect['h']);
  if (x == null || y == null || w == null || h == null) return null;
  return WebVideoLookupRequest(
    kind: raw['kind']?.toString() ?? 'click',
    sentence: sentence,
    graphemeIndex: index.toInt(),
    cueStartMs: (raw['cueStart'] as num?)?.toInt() ?? 0,
    cueEndMs: (raw['cueEnd'] as num?)?.toInt() ?? 0,
    clientRect: Rect.fromLTWH(x, y, w, h),
    screenX: _asDouble(raw['screenX']) ?? 0,
    screenY: _asDouble(raw['screenY']) ?? 0,
  );
}

/// 被点字形的**屏幕逻辑 px** 矩形（GlobalLookupController.lookupText 的 anchorScreenRect 单位）：
/// 视口矩形 + 视口在屏幕上的位置。零尺寸矩形回 null（让查词窗回落到光标定位）。
Rect? webVideoLookupAnchorScreenRect(WebVideoLookupRequest r) {
  if (r.clientRect.width <= 0 || r.clientRect.height <= 0) return null;
  return r.clientRect.shift(Offset(r.screenX, r.screenY));
}
