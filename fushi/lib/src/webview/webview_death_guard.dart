import 'dart:async';

import 'package:flutter/foundation.dart';

/// WebView renderer 子进程死亡的**统一处置**。
///
/// ## 为什么必须有这个东西：救命动作是「传了回调」，不是「回调里做了什么」
///
/// Android 上一个 WebView 的 HTML 渲染跑在**独立的 chromium renderer 子进程**里。
/// 系统内存紧张时会把这个子进程回收掉（`didCrash=false`），或者它自己崩溃
/// （`didCrash=true`）。此时 `WebViewClient.onRenderProcessGone` 的返回值决定
/// 后果：返回 `true` = 「宿主已接管」，只有那一个 WebView 变白；返回 `false`
/// （`super` 的默认实现）= 「没人接管」，`AwBrowserTerminator` 直接 **SIGTRAP
/// 杀掉整个 app 进程**。
///
/// 本仓 vendored 的
/// `third_party/flutter_inappwebview_android/.../InAppWebViewClientCompat.java`
/// 那段是：
///
/// ```java
/// if (webView.customSettings.useOnRenderProcessGone && webView.channelDelegate != null) {
///   webView.channelDelegate.onRenderProcessGone(didCrash, rendererPriorityAtExit);
///   return true;                      // fire-and-forget，随即自报接管
/// }
/// return super.onRenderProcessGone(view, detail);   // 没接管 → 连坐杀 app
/// ```
///
/// 注意 Java 侧是**发完事件立刻 `return true`**，而 Dart 侧的回调签名是 `void`：
/// 返回值根本回不到 Java。所以 —— **救 app 的唯一动作，就是在构造
/// `InAppWebView` / `HeadlessInAppWebView` 时传了一个非 null 的
/// `onRenderProcessGone`**（它会让
/// `flutter_inappwebview_android/.../in_app_webview.dart:444` 把
/// `useOnRenderProcessGone` 自动推成 `true`，从而走进上面那个 `return true`
/// 分支）。回调体里写什么、写多少，都只影响「死后能恢复多少」，不影响「app
/// 是否被杀」。
///
/// 正因为救命动作在所有站点**完全同构**，处置就必须收在这一个类里，各站点只剩
/// 「重建后调哪个已有 restore」这一个差异（[flushBeforeRebuild] /
/// [afterRebuild] 两个钩子）。分散到 N 处各写各的，只要第 N+1 处忘了传，那处就
/// 是一颗真机崩溃地雷 —— 守卫
/// `test/webview/webview_render_process_gone_guard_test.dart` 断言 `lib/` 下每一
/// 处构造都传了这个回调。
///
/// ## 恢复策略
///
/// renderer 死后那个 WebView 的 native 视图已经报废，`evaluateJavascript` 只会
/// 抛或永久挂起；Flutter 侧不会自动知道。要复活只能把 widget 整个换掉，让
/// framework 重建一个新的平台视图 —— 这就是 [rebuildKey]：把它挂在 WebView
/// **之上**（`KeyedSubtree`），epoch 一变整棵子树重建，而 WebView 自己的
/// `ValueKey`（集成测试的 finder 锚点）保持不变。
///
/// 重建**不是**免费的：宿主 State 不会重建，字段全部原样保留，所以
/// - 易失状态（还在 debounce 窗口里没落盘的进度）必须在 [flushBeforeRebuild]
///   里抢救；
/// - 陈旧的 controller / ready 标志也必须在同一个钩子里清掉，否则新 WebView
///   起来之前的那段时间里，旧引用仍会被当成活的。
///
/// 宿主的恢复锚如果记的是「进入本章时的快照」而不是「当前实际位置」，重建反而会
/// 写坏数据（restore 回退到章首，再被进度落库覆盖掉更靠后的真实进度）。那种站点就
/// 把 [afterRebuild] 传 null：**只救命、不重建**。这不是偷懒，是两害相权 —— 白屏可
/// 以退出重进，进度被写回退不可逆。
///
/// 反过来，要让一个站点具备重建能力，前置就是**把恢复锚的所有权修对**：恢复在飞时
/// 归导航发起方，恢复落定后由实时进度采样接管，锚因此始终等于当前位置。EPUB 阅读器
/// 走的就是这条路（TODO-2603，见 `lib/src/reader/reader_restore_anchor.dart`）；不要
/// 在崩溃回调里临时把「当前位置」拷进「恢复锚」当补丁，那只是把同一个所有权错误挪
/// 了个地方。
class WebViewDeathGuard {
  WebViewDeathGuard({
    required this.surface,
    Future<void> Function()? flushBeforeRebuild,
    VoidCallback? afterRebuild,
    int maxRebuilds = kDefaultMaxRebuilds,
    void Function(String surface, String message)? reporter,
  })  : _flushBeforeRebuild = flushBeforeRebuild,
        _afterRebuild = afterRebuild,
        _maxRebuilds = maxRebuilds,
        _reporter = reporter ?? _debugPrintReport;

  /// 重建预算。renderer 被 OOM kill 往往不是一次性事件：内存压力还在，重建出来
  /// 的新 renderer 会立刻再死。无上限重建 = 无限重建风暴，比白屏更糟。用完预算
  /// 就停在「死着」的状态，等用户退出重进。
  static const int kDefaultMaxRebuilds = 3;

  /// 诊断用的站点名，也是 [rebuildKey] 的前缀。
  final String surface;

  final Future<void> Function()? _flushBeforeRebuild;
  final VoidCallback? _afterRebuild;
  final int _maxRebuilds;
  final void Function(String surface, String message) _reporter;

  int _epoch = 0;
  int _deathCount = 0;
  bool _handling = false;

  /// 当前这块表面的第几代 WebView（从 0 起）。
  int get epoch => _epoch;

  /// 累计观测到的 renderer 死亡次数（含预算用尽后不再重建的那些）。
  int get deathCount => _deathCount;

  /// 重建预算是否已用尽：此后只抢救数据、不再重建。
  bool get isRebuildBudgetExhausted => _deathCount > _maxRebuilds;

  /// 挂在 WebView **之上**（而不是 WebView 自己）的重建 key。
  ///
  /// 挂在上面而非 WebView 自己身上，是为了不动 `ValueKey('fushi_webview')` /
  /// `ValueKey('manga_webview')` 这类被大量集成测试 finder 依赖的锚点。
  Key get rebuildKey => ValueKey<String>('${surface}_webview_gen_$_epoch');

  /// renderer 死了。接到 `onRenderProcessGone` 就调这个。
  ///
  /// 顺序是硬的：**先抢救数据、再决定是否重建**。预算用尽时前半段照做，只是不
  /// 递增 epoch、不通知宿主重建。
  ///
  /// 参数取平台 `RenderProcessGoneDetail` 的两个原始值，本类刻意不 import
  /// flutter_inappwebview —— 处置策略是纯逻辑，要能脱离平台通道单测。
  Future<void> handleDeath({
    bool didCrash = false,
    Object? rendererPriorityAtExit,
  }) async {
    // 同一次死亡可能由多路回调进来（例如宿主自己也挂了监听）；重入直接丢弃，
    // 否则 epoch 会一次死亡跳两代、预算被虚耗。
    if (_handling) return;
    _handling = true;
    _deathCount += 1;
    _reporter(
      surface,
      'renderer gone (didCrash=$didCrash, '
      'priorityAtExit=$rendererPriorityAtExit, death#$_deathCount)',
    );
    try {
      // 抢救永远先做，且抛错也不能挡住后面的重建：宿主 flush 失败最多丢这次
      // 增量，而不重建就是永久白屏。
      await _flushBeforeRebuild?.call();
    } catch (e, stack) {
      _reporter(surface, 'flushBeforeRebuild failed: $e\n$stack');
    }
    if (isRebuildBudgetExhausted) {
      _reporter(
        surface,
        'rebuild budget exhausted (max=$_maxRebuilds); surface stays dead',
      );
      _handling = false;
      return;
    }
    _epoch += 1;
    try {
      _afterRebuild?.call();
    } catch (e, stack) {
      _reporter(surface, 'afterRebuild failed: $e\n$stack');
    }
    _handling = false;
  }

  static void _debugPrintReport(String surface, String message) {
    debugPrint('[WebViewDeathGuard] $surface: $message');
  }
}
