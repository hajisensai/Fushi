// 网页视频的两种播放档位与「窗口宿主档」专用的 JS↔Dart 契约。纯数据 / 纯函数。
//
// 两档都在原生播放器页里播、同一套播放器外观与控件（拍板 cbKi3PN0G7-r2），用户只选「画质上限 vs
// 能否截图制卡」；默认用哪一档（按站点手动选择 / 实测 / DRM 预判）见 `web_video_hosting_default.dart`，
// 显示名与顶栏档位标识见 `web_video_mode_chip.dart`。
// · [WebVideoHosting.builtin]（界面名「制卡优先」）：fork 的 composition + WGC 离屏纹理链路，软件 DRM
//   ≤1080p，帧可捕获 → 超分 / 截图 / 识别画面文字可用；制卡队列重放也只在这一档跑（内置网页播放器
//   页当后台宿主）。
// · [WebVideoHosting.windowed]（界面名「画质优先」）：WebView2 挂成真 HWND 子窗口、经底层合成垫在
//   Flutter 下面自己绘制（硬件 PlayReady，Netflix 到 2160p），帧截不到 → 制卡只入队、之后换到可
//   捕获档重放（P3）。
import 'dart:ui' show Rect;

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

/// 悬停查词载荷（`web_video_page_lookup.js` 投来的 `type: 'pageLookup'`）`{kind, sentence, index,
/// cueStart, cueEnd, rect:{x,y,w,h}, screenX, screenY, dpr}`：`rect` 是被点字形的视口矩形（CSS px），`screenX/Y` 是页面视口在屏幕上
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
