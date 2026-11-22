// 内置网页播放器的两种宿主档（用户可选）与「窗口宿主档」专用的 JS↔Dart 契约。纯数据 / 纯函数。
//
// 默认用哪一档（按站点手动选择 / 实测 / DRM 预判）见 `web_video_hosting_default.dart`。
// · [WebVideoHosting.builtin]（界面名「Fushi 播放」）：fork 的 composition + WGC 纹理链路，软件 DRM 1080p，帧可捕获
//   → Flutter 字幕叠层 / 弹窗查词 / 超分 / 自动制卡全部可用。
// · [WebVideoHosting.windowed]（界面名「站点原生播放」）：WebView2 挂成真 HWND 子窗口自己绘制（硬件 PlayReady，Netflix 到
//   2160p），Flutter 画不到它上面 → 字幕层注入页面 DOM（`web_video_dom_subtitles.js`），点词经
//   callHandler 回 Dart，查词卡走独立顶层窗口（GlobalLookupController），制卡只入队、之后切回
//   内置档重放（P3）。
import 'dart:ui' show Offset, Rect;

import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

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

/// 窗口宿主档环境的浏览器参数：[browserArguments]（app 内浏览器共享环境的那套）后面接哨兵。
///
/// fork 在交给 WebView2 之前把哨兵剥掉（[stripWindowedHostingSentinel] 是它的 Dart 镜像），
/// 所以 WebView2 看到的参数与浏览器环境逐字相同——两者才能共用同一个 user data folder
/// （同一 cookie 罐；同目录参数不一致会 0x8007139F）。
String windowedHostingArguments(String browserArguments) =>
    browserArguments.isEmpty
    ? kWebVideoWindowedHostingSentinel
    : '$browserArguments $kWebVideoWindowedHostingSentinel';

/// `WebViewEnvironment::StripWindowedHostingSentinel`（fork C++）的 Dart 镜像，只供测试断言
/// 「剥完与浏览器参数逐字一致」：整词匹配哨兵，连同它前面的空白剥掉（在开头时连同后面的空白）；
/// 只是更长开关的子串（`--fushi-windowed-hosting-x`）不算。两侧算法由守卫测试咬住。
({String arguments, bool found}) stripWindowedHostingSentinel(
  String arguments,
) {
  const String token = kWebVideoWindowedHostingSentinel;
  bool isSpace(String ch) => ch == ' ' || ch == '\t';
  String out = arguments;
  bool found = false;
  int pos = 0;
  while ((pos = out.indexOf(token, pos)) != -1) {
    final int end = pos + token.length;
    final bool startOk = pos == 0 || isSpace(out[pos - 1]);
    final bool endOk = end == out.length || isSpace(out[end]);
    if (!startOk || !endOk) {
      pos = end;
      continue;
    }
    found = true;
    int eraseStart = pos;
    int eraseEnd = end;
    if (pos > 0) {
      while (eraseStart > 0 && isSpace(out[eraseStart - 1])) {
        eraseStart--;
      }
    } else {
      while (eraseEnd < out.length && isSpace(out[eraseEnd])) {
        eraseEnd++;
      }
    }
    out = out.replaceRange(eraseStart, eraseEnd, '');
    pos = eraseStart;
  }
  return (arguments: out, found: found);
}

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

/// DOM 字幕层点词的制卡锚点 cue（BUG-4714）：就是被点的那一句。
///
/// DOM 层直接读页面 store 里的活对象，载荷里的 (cueStart, cueEnd, sentence) 是用户此刻看到、
/// 点下去的那句的权威描述；Dart 侧 [cues] 只是 glue 节流投过来的轨快照（live 轨边看边改：文本
/// 逐字变长、起点往前并、终点往后延；Dart 解析时还会 trim），未必对得上，甚至还没到。
/// - Dart 副本里有时间窗与文本都相同的那条 → 返回它本身（`cueStreamOwning` 按 identical 认流，
///   同时显示的整句 / 收藏归属照旧）；
/// - 否则按载荷建一条（[trackKey] 记进 `chapterHref`，与 [parseWebVideoTrackPayload] 同形）。
///
/// 永不为 null：点词那一刻就有确定的一句，制卡必须走入队重放（截帧 + 录音），不能因为快照
/// 滞后退回到「当前播放位置」那句（常常是 null → 纯字段卡，无画面无音频）。
AudioCue webVideoDomLookupAnchorCue({
  required WebVideoLookupRequest request,
  required List<AudioCue> cues,
  required String bookUid,
  required String trackKey,
}) {
  final int start = request.cueStartMs;
  final int end = request.cueEndMs < start ? start : request.cueEndMs;
  final String text = request.sentence.trim();
  for (final AudioCue c in cues) {
    if (c.startMs == start && c.endMs == end && c.text.trim() == text) {
      return c;
    }
  }
  return AudioCue()
    ..bookKey = bookUid
    ..chapterHref = trackKey
    ..sentenceIndex = -1
    ..textFragmentId = ''
    ..text = text
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = 0;
}

/// 被点字形的**屏幕逻辑 px** 矩形（GlobalLookupController.lookupText 的 anchorScreenRect 单位）：
/// 视口矩形 + 视口在屏幕上的位置。零尺寸矩形回 null（让查词窗回落到光标定位）。
Rect? webVideoLookupAnchorScreenRect(WebVideoLookupRequest r) {
  if (r.clientRect.width <= 0 || r.clientRect.height <= 0) return null;
  return r.clientRect.shift(Offset(r.screenX, r.screenY));
}
