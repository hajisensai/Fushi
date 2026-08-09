import 'dart:async';

/// 是否应在启动后预热 WebView 引擎，把冷启动成本提前到用户翻书架时。
///
/// 移动端与桌面端都预热（桌面端调用时机另由调用方保证在首帧后），
/// 低内存模式一律跳过。纯逻辑，便于单测；真正的 HeadlessInAppWebView
/// 调用留在 main.dart（依赖平台无法单测）。
bool shouldPrewarmWebView({
  required bool isMobile,
  required bool isDesktop,
  required bool lowMemory,
}) {
  if (lowMemory) return false;
  return isMobile || isDesktop;
}

/// 预热 WebView 的**生命周期看门人**：保证那个 headless WebView 一定会被销毁。
///
/// 为什么需要它——预热是纯优化，但它持有的是**进程级**资源：一个 headless
/// WebView 会拉起一个独立的 chromium renderer 子进程。旧实现把 `dispose()`
/// 挂在 `onLoadStop` 这一条**成功路径**上，于是「回调不来」等于「永久泄漏一个
/// renderer 进程」，而 renderer 一旦被系统 OOM kill，`WebViewClient
/// .onRenderProcessGone` 没人接管时 Android 的默认动作就是**杀掉整个 app
/// 进程**（`AwBrowserTerminator` → SIGTRAP）。CI Android appSmoke 连续 4 次
/// 就死在这条路上：`[Fushi] WebView engine pre-warm` 一次都没打印过（说明
/// dispose 从未执行），随后 `Render process crash wasn't handled by all
/// associated webviews, triggering application crash`。
///
/// 修法不是等更久或重试，而是把「什么时候结束」从单一成功回调改成**先到者胜的
/// 多路终点**：载入完成 / 载入失败 / renderer 进程死亡 / [timeout] 兜底。
/// [finish] 幂等，重复触发是 no-op，所以四条路可以同时接线而不会二次 dispose。
class WebViewPrewarmSession {
  WebViewPrewarmSession({
    required Future<void> Function() disposeWebView,
    Duration timeout = kDefaultTimeout,
    void Function(String reason)? onFinished,
  })  : _disposeWebView = disposeWebView,
        _timeout = timeout,
        _onFinished = onFinished;

  /// 兜底时限：预热收益只有几百毫秒到 1.5 秒，超过这个量级还没回调就已经没有
  /// 预热价值了，留着只剩泄漏成本。不是「等久一点也许就好了」的重试窗口。
  static const Duration kDefaultTimeout = Duration(seconds: 30);

  final Future<void> Function() _disposeWebView;
  final Duration _timeout;
  final void Function(String reason)? _onFinished;

  Timer? _timer;
  bool _finished = false;

  /// 预热是否已终结（dispose 已发起）。
  bool get isFinished => _finished;

  /// 兜底定时器是否在跑。仅供测试与诊断。
  bool get hasPendingTimeout => _timer != null;

  /// 在 headless WebView 真的 `run()` 起来之后调用：装上兜底终点。
  ///
  /// 已终结时不再装（回调可能比 `run()` 返回还快）。
  void armTimeout() {
    if (_finished || _timer != null) return;
    _timer = Timer(_timeout, () {
      unawaited(finish('timeout'));
    });
  }

  /// 终结预热并销毁 WebView。先到者胜，重复调用是 no-op。
  ///
  /// dispose 抛错只记原因、不外抛：预热失败不该冒泡进启动链路。
  Future<void> finish(String reason) async {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    String outcome = reason;
    try {
      await _disposeWebView();
    } catch (e) {
      outcome = '$reason (dispose failed: $e)';
    }
    _onFinished?.call(outcome);
  }
}
