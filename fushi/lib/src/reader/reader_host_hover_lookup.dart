import 'dart:ui' show Offset, Size;

/// 阅读器**宿主（Flutter）侧**悬停查词的门控 + 节流（BUG-2490）。
///
/// 阅读器的 Shift-悬停查词此前只有一条腿：正文 WebView 里的 JS `mousemove`
/// 监听（`webview.part.dart` 的 `onShiftHover`）。这条腿在 macOS 上是死的：
/// WebKit 的 `WKMouseTrackingObserver.mouseMoved:` 先对窗口 contentView 做一次
/// AppKit 命中测试，只有命中视图是 WKWebView 的后代才把 mouseMoved 交给页面
/// （WebKit `UIProcess/mac/WebViewImpl.mm` `updateViewIsTopmostAtMouseLocation:`）；
/// 而 Flutter macOS 嵌入层把「排在平台视图之后的 Flutter 绘制」写进
/// `FlutterMutatorView._hitTestIgnoreRegion`，落在其中的点 `hitTest:` 返回 nil
/// （BUG-1692 同一机制）——于是页面 DOM 收不到 `mousemove`，`e.shiftKey` 门永远
/// 不开。Flutter 自己的 `FlutterView` tracking area 与 WKWebView 的互不干扰，
/// 宿主侧的 [PointerHoverEvent] 照常到达，且 macOS 嵌入层在每个鼠标事件上同步
/// 修饰键状态（`FlutterViewController.dispatchMouseEvent` → `syncModifiersIfNeeded`），
/// `HardwareKeyboard.isShiftPressed` 在 hover 时可靠。故给宿主补一条腿。
///
/// 两条腿按 [hostOwnsWebViewPointerInput] 互斥（BUG-2031 纪律：任一平台恒只有
/// 一条腿活着）：Windows 的 WebView2 是 Flutter 纹理、指针由 fork 逐个转发，JS 腿
/// 已验证可用，宿主腿不装；其余平台（WebView 是真正的原生视图）走宿主腿，JS 腿
/// 的 mousemove 监听由 `window.__fushiHostHoverLookup` 关掉。
///
/// 语义与 JS 腿逐字对齐：按住 Shift **或**开了「悬停即查词」才触发；未触发分支
/// 复位节流锚，使下次进入即触发；移动距离平方 < [thresholdPx]² 不重复查词
/// （同词去重的第二道闸在 JS `selectText` 的 `fromHover` 同词短路）。
class ReaderHostHoverLookupGate {
  /// 与 JS 腿（`webview.part.dart` / `lyrics_mode_html.dart` 的 `dx*dx+dy*dy < 64`）
  /// 同一阈值。
  static const double thresholdPx = 8;

  double _lastDx = -1;
  double _lastDy = -1;

  /// 本次 hover 落点 [local]（WebView 局部 == CSS 视口坐标）是否应触发一次查词。
  /// 返回 false 的两种情形：门未开（复位锚点）、或仍在上次触发点 [thresholdPx]
  /// 内（锚点不动）。返回 true 时锚点已推进到 [local]。
  bool shouldLookup(
    Offset local, {
    required bool shiftPressed,
    required bool hoverAutoLookup,
  }) {
    if (!shiftPressed && !hoverAutoLookup) {
      reset();
      return false;
    }
    final double dx = local.dx - _lastDx;
    final double dy = local.dy - _lastDy;
    if (dx * dx + dy * dy < thresholdPx * thresholdPx) return false;
    markLookedUp(local);
    return true;
  }

  /// 把锚点钉到 [local]：Shift 按下时在静止光标处直接查词后调用，使紧随其后的
  /// 微小抖动不再重复查同一处。
  void markLookedUp(Offset local) {
    _lastDx = local.dx;
    _lastDy = local.dy;
  }

  /// 复位锚点（指针离开正文 / 门关闭），下次进入即触发。
  void reset() {
    _lastDx = -1;
    _lastDy = -1;
  }
}

/// 宿主腿只对落在 WebView 盒内的点动手：盒外（负坐标 / 超出尺寸）喂给 JS
/// `selectText` 会命中空白→清掉当前选区，而 JS 腿对盒外点根本不会触发。
bool readerHostHoverPointInside(Offset local, Size box) =>
    local.dx >= 0 &&
    local.dy >= 0 &&
    local.dx < box.width &&
    local.dy < box.height;
