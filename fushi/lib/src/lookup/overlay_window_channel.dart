// spec 2026-07-10 — instance-level channel wrapper for a bare-WebView2 overlay
// window. Extracted from the static GlobalLookupChannel (TODO-617, which stays
// as a zero-churn delegating facade for the 1700-line controller) so the
// SECOND window instance — the persistent clipboard panel — reuses the exact
// same method contract on its own MethodChannel
// (app.fushi.reader/clipboard_panel) instead of copy-pasting ~250 lines.
//
// Native counterpart: windows/runner/global_lookup_window.cpp +
// FlutterWindow::RegisterGlobalLookupChannel / RegisterClipboardPanelChannel.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Native reply for [OverlayWindowChannel.showAt]: window-created flag plus the
/// anchor monitor's work area in PHYSICAL px (0 when unavailable). Divide the
/// work dimensions by the device pixel ratio to get CSS px for the cascade
/// layout (TODO-893 symptom 2).
class GlobalLookupShowResult {
  const GlobalLookupShowResult({
    required this.ok,
    required this.workWidth,
    required this.workHeight,
    this.cursorWorkX = 0,
    this.cursorWorkY = 0,
    this.monitorDpr = 0,
  });

  /// Whether the native overlay window was created.
  final bool ok;

  /// Anchor monitor work-area width in PHYSICAL px (0 when unavailable).
  final double workWidth;

  /// Anchor monitor work-area height in PHYSICAL px (0 when unavailable).
  final double workHeight;

  /// TODO-893 v2 (symptom 3) — the overlay window-local origin's offset from
  /// the anchor monitor work-area origin, in PHYSICAL px (0 when unavailable).
  /// The window-local (0,0) maps to (cursorWorkX, cursorWorkY) inside the work
  /// area; divide by the device pixel ratio for CSS px.
  final double cursorWorkX;

  /// See [cursorWorkX]: the vertical component (PHYSICAL px).
  final double cursorWorkY;

  /// BUG-859 — the ANCHOR MONITOR's device pixel ratio (effective DPI / 96;
  /// 0 when the native side could not query the monitor). The physical-px
  /// values above must be divided by THIS dpr — not the main window's — to
  /// land in the same CSS px scale the overlay page measures in: on a
  /// mixed-scale multi-monitor setup the overlay WebView2 rasterizes at its
  /// own monitor's scale, so converting with the main-window dpr put the
  /// cascade layout's work-area domain in the wrong scale (mis-placed nested
  /// cards, broken reserve-to-edge clamp invariant).
  final double monitorDpr;
}

class OverlayWindowChannel {
  const OverlayWindowChannel(this._channel, {this.target = ''});

  final MethodChannel _channel;

  /// 目标窗口标识。空 = 该通道自己的默认窗口（桌面浮窗 / 剪贴板面板）。
  ///
  /// `'galCard'` 指向游戏内查词专用的**离屏**卡片窗：同一条 MethodChannel、同一套
  /// 方法契约，只是 native 侧按这个字段解析成另一个 GlobalLookupWindow 实例。
  /// 这样游戏内查词能整条复用既有渲染管线（查词 → popupJson → 渲染 → 定尺寸），
  /// 而不必把 1700 行控制器复制一份；也不会像之前那样"渲染器建好却没人往里塞内容"。
  final String target;

  /// 所有调用的唯一出口：把 [target] 注入参数表。逐个方法手动加，迟早漏一个，
  /// 而漏掉的那个会静默打到错误的窗口上。
  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) {
    // 🔴 这里必须调 `_channel.invokeMethod`，**不能**调 `_invoke` —— 它就是 _invoke
    // 本身。（本文件的调用点是用整文件替换从 `_channel.invokeMethod<` 改成 `_invoke<`
    // 的，那次替换把这个 helper 自己体内的两处也换掉了，结果是无限自递归、栈溢出，
    // 且异常被 main.dart 的 `catch { debugPrint }` 吞掉——release 下整条桌面查词
    // 启动链静默中断，表现为"galgame 查词就是不工作"。）
    if (target.isEmpty) {
      return _channel.invokeMethod<T>(method, args);
    }
    return _channel.invokeMethod<T>(method, <String, Object?>{
      ...?args,
      'target': target,
    });
  }

  /// Sets the absolute folder that holds popup.html / popup.js / popup.css and
  /// popup_bridge_adapter.js (flutter_assets/assets/popup at runtime). Must be
  /// called once before the first [showAt].
  Future<void> prepare(String assetsDir) =>
      _invoke<void>('prepare', <String, Object?>{
        'assetsDir': assetsDir,
      });

  /// TODO-1079 — builds the overlay window + WebView2 OFF-SCREEN and navigates
  /// to host.html at startup so the first lookup hits a WARM surface.
  /// Idempotent natively (no-op once warm).
  Future<void> prewarmWebView({int width = 420, int height = 600}) =>
      _invoke<void>('prewarmWebView', <String, Object?>{
        'width': width,
        'height': height,
      });

  /// TODO-1079 — whether the overlay WebView2 finished its initial navigation
  /// (host document + popup iframes loaded). False on any non-bool reply.
  Future<bool> isWebViewReady() async =>
      (await _invoke<bool>('isWebViewReady')) ?? false;

  /// Shows the overlay at screen coordinates (physical pixels) without
  /// stealing focus. Returns the native reply (see [GlobalLookupShowResult]).
  /// [capWidth]/[capHeight]：**布局工作区**的物理像素上限（0 = 不限，用显示器工作区）。
  ///
  /// 游戏内查词必须传：卡片最终是画在游戏画面里的，可用空间是**游戏视口**而不是
  /// 显示器工作区。不传的话弹窗按 2560x1440 排版、排完再被缩到卡片尺寸，而 runner
  /// 超尺寸时是**裁不是缩**——真机表现就是工具栏和第三栏词典被切在画面外，看起来
  /// 像"少了很多功能"，其实只是没进画面。
  Future<GlobalLookupShowResult> showAt({
    required int x,
    required int y,
    int width = 420,
    int height = 600,
    bool atCursor = false,
    int capWidth = 0,
    int capHeight = 0,
  }) async {
    final Object? reply =
        await _invoke<Object?>('showAt', <String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'atCursor': atCursor,
      'capW': capWidth,
      'capH': capHeight,
    });
    if (reply is Map) {
      double num2(Object? v) => (v is num) ? v.toDouble() : 0;
      return GlobalLookupShowResult(
        ok: reply['ok'] == true,
        workWidth: num2(reply['workW']),
        workHeight: num2(reply['workH']),
        cursorWorkX: num2(reply['cursorWorkX']),
        cursorWorkY: num2(reply['cursorWorkY']),
        monitorDpr: num2(reply['monitorDpr']),
      );
    }
    // Legacy/native fallback (bool reply): no work-area reported.
    return GlobalLookupShowResult(
      ok: reply == true,
      workWidth: 0,
      workHeight: 0,
    );
  }

  /// Injects [popupJson] and calls window.renderPopup() in the overlay WebView.
  Future<void> render(String popupJson) =>
      _invoke<void>('render', <String, Object?>{
        'json': popupJson,
      });

  /// Resizes the overlay window (physical px), clamped to the work area by
  /// native. Keeps the current top-left anchor.
  Future<void> resize({required int width, required int height}) =>
      _invoke<void>('resize', <String, Object?>{
        'width': width,
        'height': height,
      });

  /// Resolves a deferred JS bridge promise. The overlay adapter does
  /// `JSON.parse(arg)` on the second argument of
  /// window.__fushiBridgeResolve(id, arg) — i.e. it expects a JS *string*
  /// containing the reply's JSON. So we double-encode: the inner jsonEncode
  /// produces the reply JSON text, the outer jsonEncode turns that into a JS
  /// string literal native can splice in verbatim.
  Future<void> resolveBridge(int id, Object? value) =>
      _invoke<void>('resolveBridge', <String, Object?>{
        'id': id,
        'value': jsonEncode(jsonEncode(value)),
      });

  /// Moves the off-screen-rendered overlay to its pending anchor at the final
  /// size and makes it visible.
  Future<void> reveal({required int width, required int height}) =>
      _invoke<void>('reveal', <String, Object?>{
        'width': width,
        'height': height,
      });

  /// TODO-867 P3c E1 — reveals/resizes the overlay to the nested-stack union
  /// bounding box. See GlobalLookupChannel.revealStack for the full geometry
  /// contract (dx/dy physical px window offset; left/top window-local CSS px
  /// forwarded to the host's commitLayerShift after SetWindowPos).
  Future<void> revealStack({
    required int dx,
    required int dy,
    required int width,
    required int height,
    double left = 0,
    double top = 0,
  }) =>
      _invoke<void>('revealStack', <String, Object?>{
        'dx': dx,
        'dy': dy,
        'width': width,
        'height': height,
        'left': left,
        'top': top,
      });

  /// Hides the overlay. [notify] true (default) = a genuine dismissal that
  /// fires the native `overlayHidden` callback; false = the programmatic reset
  /// before a fresh lookup (must not look like a user dismissal, TODO-1233).
  Future<void> hide({bool notify = true}) =>
      _invoke<void>('hide', <String, Object?>{'notify': notify});

  Future<bool> isShowing() async =>
      (await _invoke<bool>('isShowing')) ?? false;

  /// spec §6 — asks native for the Win11 acrylic system backdrop behind the
  /// window's transparent pixels. Returns whether the OS accepted it (false on
  /// Win10 / pre-22H2 / non-panel channels → caller keeps the surface opaque
  /// and hides the opacity slider). Only wired on the clipboard-panel channel;
  /// other channels answer notImplemented → false.
  Future<bool> applyBackdrop() async {
    try {
      return (await _invoke<bool>('applyBackdrop')) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// spec 2026-07-10 panel pin — toggles HWND_TOPMOST. Only wired on the
  /// clipboard-panel channel.
  Future<void> setPinned(bool pinned) =>
      _invoke<void>('setPinned', <String, Object?>{
        'pinned': pinned,
      });

  /// 防截屏 — SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)：窗口对用户可见
  /// 但从截图 / 录屏 / 屏幕共享里排除。Wired on BOTH channels（剪贴板面板 +
  /// 瞬态全局查词窗——同一 pref clipboardPanelBlockCapture 保护两块表面）。
  Future<void> setBlockCapture(bool block) =>
      _invoke<void>('setBlockCapture', <String, Object?>{
        'block': block,
      });

  /// 面板抬前台 — 把已显示的面板重排到 z 序最上，绝不激活（不抢当前前台窗口
  /// 焦点）。[topmost]=true（已 pin）直接置顶，false 则顶到非置顶带最上。
  /// Only wired on the clipboard-panel channel.
  Future<void> raise({required bool topmost}) =>
      _invoke<void>('raise', <String, Object?>{
        'topmost': topmost,
      });

  /// 面板任务栏图标 — 任务栏按钮 / Alt-Tab 项的窗口标题（本地化文案）。
  /// 窗口创建前设置则用于创建，已创建则即时更新。Only wired on the
  /// clipboard-panel channel.
  Future<void> setWindowTitle(String title) =>
      _invoke<void>('setWindowTitle', <String, Object?>{
        'title': title,
      });

  /// spec §6 真机修正 — 整窗不透明度（WS_EX_LAYERED + LWA_ALPHA，30-100%）。
  /// 真透视：整窗（含文字）统一变淡，透出底下的游戏/网页；acrylic backdrop
  /// 实测经 windowed WebView2 呈现为不透明且毛玻璃本就不是「看见底下」。
  /// Only wired on the clipboard-panel channel.
  Future<void> setWindowAlpha(int percent) =>
      _invoke<void>('setWindowAlpha', <String, Object?>{
        'percent': percent,
      });

  /// Wires the overlay's reverse calls. [onGetMedia] resolves gaiji bytes for
  /// an `image://` url; [onJsMessage] receives raw bridge messages decoded
  /// from JSON; [onOverlayHidden] fires on a genuine native dismissal.
  void setHandlers({
    required Future<Uint8List> Function(String url) onGetMedia,
    required void Function(Map<String, Object?> message) onJsMessage,
    void Function()? onOverlayHidden,
  }) {
    _channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'getMedia':
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          final String url = args['url'] as String;
          return await onGetMedia(url);
        case 'jsMessage':
          final Object? raw = call.arguments;
          if (raw is String) {
            final Object? decoded = jsonDecode(raw);
            if (decoded is Map) {
              onJsMessage(decoded.cast<String, Object?>());
            }
          }
          return null;
        case 'nativeError':
          // TODO-1153 -- the native overlay reported a WebView2 bring-up
          // failure. Surface it in ErrorLogService AND the glookup diagnostic
          // file so "no popup shows" is diagnosable rather than swallowed.
          final Object? message = call.arguments;
          if (message is String && message.isNotEmpty) {
            glog('nativeError(${_channel.name}): $message');
            ErrorLogService.instance.log(
              'OverlayWindowChannel(${_channel.name}).nativeError',
              message,
            );
          }
          return null;
        case 'overlayHidden':
          // TODO-1233 -- genuine native dismissal (foreground hook /
          // click-outside / JS dismiss).
          onOverlayHidden?.call();
          return null;
        default:
          return null;
      }
    });
  }
}
