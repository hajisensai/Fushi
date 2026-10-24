import 'package:fushi/src/web_browser/tab_view/web_browser_load_errors.dart';

/// 一个标签页的「这次导航该记成哪条历史」判据（纯逻辑，没有计时器）。
///
/// 每次主框架地址变化（整页加载或单页应用的 `pushState`）恰好记一次，用尽量准的
/// 标题：
/// - 地址变了 → 记为「待记」；
/// - 待记期间标题变了 / 整页加载完 → 立即记（YouTube 之类先换地址后换标题）；
/// - 待记期间地址又变了 → 先把上一条按当时的标题记掉，再开始新的待记；
/// - 标签页关掉 → [flush] 记掉最后一条。
///
/// `recordVisit` 每调一次访问次数 +1，所以这里保证同一次导航不重复记。
class WebBrowserVisitRecorder {
  WebBrowserVisitRecorder({required this.record});

  /// 真正写历史（`store.recordVisit`）。无痕标签页不建本对象。
  final void Function(Uri url, String title) record;

  Uri? _pending;
  Uri? _lastRecorded;
  String _title = '';

  /// 主框架地址变化（`onUpdateVisitedHistory` / `onLoadStart`）。
  void onUrlChanged(Uri? url) {
    if (url == null || !isWebBrowserNavigableUrl(url)) return;
    final Uri? pending = _pending;
    if (pending != null) {
      if (pending == url) return;
      _commit();
    } else if (_lastRecorded == url) {
      // 同一地址的重复事件（加载开始 + 历史更新），或刷新：不再记。
      return;
    }
    _pending = url;
    // 新页面的标题等它自己的 onTitleChanged / onLoadStop，别把上一页的标题带过去。
    _title = '';
  }

  /// 标题变化（`onTitleChanged`）。
  void onTitleChanged(String? title) {
    final String next = title?.trim() ?? '';
    if (next.isEmpty) return;
    _title = next;
    if (_pending != null) _commit();
  }

  /// 整页加载完成（`onLoadStop`）。
  void onLoadStop(Uri? url, String? title) {
    if (url != null) onUrlChanged(url);
    final String next = title?.trim() ?? '';
    if (next.isNotEmpty) _title = next;
    if (_pending != null) _commit();
  }

  /// 用户主动刷新 / 重新打开同一地址：允许再记一次。
  void onReload() => _lastRecorded = null;

  /// 标签页关闭：记掉还在待记的那条。
  void flush() {
    if (_pending != null) _commit();
  }

  void _commit() {
    final Uri? url = _pending;
    _pending = null;
    if (url == null) return;
    _lastRecorded = url;
    record(url, _title);
  }
}
