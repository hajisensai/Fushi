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

  /// 标签上显示的名字：标题，退到域名，再退到原样地址。
  String get displayTitle {
    final String t = _title.trim();
    if (t.isNotEmpty) return t;
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
}

/// 主框架加载失败的描述（加载失败页用）。
@immutable
class WebBrowserLoadError {
  const WebBrowserLoadError({
    required this.url,
    required this.description,
    this.statusCode,
    this.offline = false,
  });

  final Uri url;
  final String description;

  /// HTTP 错误码（4xx / 5xx 主框架响应）；网络层错误为 null。
  final int? statusCode;

  /// 断网类错误（加载失败页换「检查网络」文案）。
  final bool offline;
}
