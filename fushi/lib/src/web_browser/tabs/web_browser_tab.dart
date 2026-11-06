import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 浏览器里的一个标签页：只放跨组件共享的「可观察状态」。
///
/// WebView 本体（平台视图 + 控制器生命周期）由每个标签页自己的
/// `WebBrowserTabView` 持有；侧边栏 / 顶部标签栏 / 标签页网格 / 菜单只读这里。
/// 状态改变一律走 [update]，它负责 [notifyListeners]。
class WebBrowserTab extends ChangeNotifier {
  WebBrowserTab({
    required this.id,
    required Uri? url,
    this.incognito = false,
    this.openerId,
    this.windowId,
    String title = '',
  }) : _url = url,
       _title = title;

  /// 会话内唯一，持久化时也用它（无痕标签页不落盘）。
  final String id;

  /// 无痕：独立 Cookie / 存储环境，不记历史，不进会话恢复，关掉即清。
  final bool incognito;

  /// 由哪个标签页打开（`target=_blank` / `window.open`）；关掉时回到它。
  final String? openerId;

  /// `onCreateWindow` 给的窗口 id：新标签页的 WebView 必须用它创建，
  /// 否则 `window.open` 拿到的窗口对象对不上（新窗口打不开的一类根因）。
  final int? windowId;

  Uri? _url;
  String _title;
  Uri? _faviconUrl;
  double _progress = 1;
  bool _loading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  WebBrowserLoadError? _error;
  bool _desktopMode = false;
  int _textZoom = 100;
  bool _fullscreen = false;
  bool _findOpen = false;
  InAppWebViewController? _controller;

  Uri? get url => _url;
  String get title => _title;

  /// 标签上显示的名字：标题，退到域名，再退到原样地址。失败页盖着时标题是引擎
  /// 自带错误页的（如 WebView2 证书拦截页的「隐私错误」），不用它、直接退到域名。
  String get displayTitle {
    final String t = _title.trim();
    if (t.isNotEmpty && _error == null) return t;
    final Uri? u = _url;
    if (u == null) return '';
    return u.host.isNotEmpty ? u.host : u.toString();
  }

  Uri? get faviconUrl => _faviconUrl;

  /// 0..1；[loading] 为 false 时恒为 1。
  double get progress => _progress;
  bool get loading => _loading;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;

  /// 主框架加载失败（非 null 时显示加载失败页）。
  WebBrowserLoadError? get error => _error;

  /// 「桌面版网页」：换桌面 UA + 宽视口。
  bool get desktopMode => _desktopMode;

  /// 文字大小百分比（50..300）。
  int get textZoom => _textZoom;

  /// 网页请求了全屏（HTML5 视频全屏）：浏览器 chrome 全部让位。
  bool get fullscreen => _fullscreen;

  /// 页内查找条开着（壳在此时显示 `WebBrowserFindBar`）。
  bool get findOpen => _findOpen;

  /// 当前活着的控制器；标签页被回收（只剩地址）或 WebView 还没建时为 null。
  InAppWebViewController? get controller => _controller;

  void update({
    Uri? url,
    String? title,
    Uri? faviconUrl,
    double? progress,
    bool? loading,
    bool? canGoBack,
    bool? canGoForward,
    bool? desktopMode,
    int? textZoom,
    bool? fullscreen,
    bool? findOpen,
  }) {
    bool changed = false;
    if (url != null && url != _url) {
      _url = url;
      changed = true;
    }
    if (title != null && title != _title) {
      _title = title;
      changed = true;
    }
    if (faviconUrl != null && faviconUrl != _faviconUrl) {
      _faviconUrl = faviconUrl;
      changed = true;
    }
    if (loading != null && loading != _loading) {
      _loading = loading;
      if (!loading) _progress = 1;
      changed = true;
    }
    if (progress != null && progress != _progress && _loading) {
      _progress = progress.clamp(0, 1).toDouble();
      changed = true;
    }
    if (canGoBack != null && canGoBack != _canGoBack) {
      _canGoBack = canGoBack;
      changed = true;
    }
    if (canGoForward != null && canGoForward != _canGoForward) {
      _canGoForward = canGoForward;
      changed = true;
    }
    if (desktopMode != null && desktopMode != _desktopMode) {
      _desktopMode = desktopMode;
      changed = true;
    }
    if (textZoom != null && textZoom != _textZoom) {
      _textZoom = textZoom.clamp(50, 300);
      changed = true;
    }
    if (fullscreen != null && fullscreen != _fullscreen) {
      _fullscreen = fullscreen;
      changed = true;
    }
    if (findOpen != null && findOpen != _findOpen) {
      _findOpen = findOpen;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void setError(WebBrowserLoadError? error) {
    if (identical(error, _error)) return;
    _error = error;
    notifyListeners();
  }

  /// 只由 `WebBrowserTabView` 调：WebView 建好 / 销毁时挂上 / 摘掉。
  void attachController(InAppWebViewController? controller) {
    if (identical(controller, _controller)) return;
    _controller = controller;
    notifyListeners();
  }

  Rect? Function(Rect local)? _viewportToGlobal;

  /// 只由 `WebBrowserTabView` 调：登记「网页视口坐标（CSS px）→ 全局逻辑坐标」的换算
  /// （页内脚本报来的矩形据此给 Flutter 弹窗做锚点）。null = 摘掉。
  void attachViewport(Rect? Function(Rect local)? mapper) {
    _viewportToGlobal = mapper;
  }

  /// WebView 在屏上、能换算坐标。
  bool get hasViewport => _viewportToGlobal != null;

  /// 网页视口里的矩形换成全局坐标；WebView 不在屏上（后台标签页 / 已销毁）时 null。
  Rect? viewportRectToGlobal(Rect local) => _viewportToGlobal?.call(local);
}

/// 主框架加载失败的描述（加载失败页用）。
@immutable
class WebBrowserLoadError {
  const WebBrowserLoadError({
    required this.url,
    required this.description,
    this.statusCode,
    this.kind = WebBrowserLoadErrorKind.generic,
  });

  final Uri url;

  /// 引擎给的原始描述（WebView2 / Android / iOS 的英文或系统语言原文）。失败页
  /// 只把它放进折叠的「详细信息」，正文按 [kind] 取本地化文案。
  final String description;

  /// HTTP 错误码（4xx / 5xx 主框架响应）；网络层错误为 null。
  final int? statusCode;

  /// 网络层失败的类别（决定失败页的标题 / 正文 / 图标）。
  final WebBrowserLoadErrorKind kind;

  /// 断网类错误（加载失败页换「检查网络」文案）。
  bool get offline => kind == WebBrowserLoadErrorKind.offline;
}

/// 主框架网络层失败的类别。三端引擎的错误码在
/// `web_browser_load_errors.dart` 的 `classifyWebBrowserMainFrameError` 里归到这里。
enum WebBrowserLoadErrorKind {
  /// 归不了类（含 WebView2 的 UNKNOWN：连接被拒在 WebView2 上就落这里）。
  generic,

  /// 本机没有网络 / 网络中途断开。
  offline,

  /// 域名解析失败。
  dnsFailed,

  /// 连接被拒 / 被重置 / 主机不可达。
  connectionFailed,

  /// 连接或响应超时。
  timedOut,

  /// TLS 握手失败 / 证书无效。
  certificate,

  /// 服务器回了无法解析的响应（空响应 / 格式错误）。
  badResponse,

  /// 重定向过多或重定向失败。
  tooManyRedirects,
}
