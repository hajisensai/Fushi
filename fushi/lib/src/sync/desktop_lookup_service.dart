import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/src/utils/misc/lookup_input_limits.dart';
import 'package:fushi/src/utils/misc/ruby_markup.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';

class DesktopLookupRequest {
  const DesktopLookupRequest({required this.text});

  /// 纯基准文本：注音标记已在 [DesktopLookupService.triggerLookup] 剥掉
  /// （主窗词典页只显示 / 查询基准文本，不渲染注音）。
  final String text;
}

/// 桌面显式查词排队器。单例 ChangeNotifier。
///
/// 来源只有用户的显式意图：`fushi://lookup` 深链 / 浏览器扩展 / 桌面悬浮字幕点词。
/// 它们把待查词排进 [pendingRequest] 并通知；消费侧（[HomeDictionaryPage]）在挂载
/// 或收到通知时取走并搜索，需要时再调 [bringPendingLookupToFront] 唤主窗。
///
/// 这里不直接唤主窗前台：只有词典页实际消费 [pendingText] 并开始搜索时，
/// 才由 UI 调用 [bringPendingLookupToFront]。
class DesktopLookupService extends ChangeNotifier {
  DesktopLookupService._();
  static final DesktopLookupService instance = DesktopLookupService._();

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  DesktopLookupRequest? _pendingRequest;
  DesktopLookupRequest? get pendingRequest => _pendingRequest;
  String? get pendingText => _pendingRequest?.text;

  /// 显式查词入口（TODO-376）：把一段文本送进查词管线与出口
  /// （[pendingText] → 词典页消费 → [bringPendingLookupToFront]）。
  ///
  /// 注意：本方法只负责**排队**待查词（设 [pendingText] + 通知）；唤前台、切到查词
  /// tab、实际搜索都由消费侧（[bringPendingLookupToFront] + HomeDictionaryPage
  /// 挂载消费）负责。
  void triggerLookup(String text) {
    // 注音标记在这里剥（悬浮字幕行可能带 `<rふる>震</r>` 标记），且必须**先于**
    // 下面的截断：先截断会把标记拦腰切断，解析器认不出就只能把半截标记当正文留下。
    final String base = parseRubyMarkup(text).text;
    // BUG-442：所有来源在排队前先按同一码点上限截断（用 characters 不切碎代理对 /
    // 字素簇），避免超长串一路流到逐字渲染的 SourceLookupTextPanel 把主 isolate 撑爆。
    final String trimmed = _capLookupInput(base).trim();
    if (trimmed.isEmpty) return;
    _pendingRequest = DesktopLookupRequest(text: trimmed);
    notifyListeners();
  }

  /// BUG-442：把查词输入截断到 [kMaxLookupInputChars] 个码点（字素簇），防止超长
  /// 文本一路流到逐字建 widget 的 [SourceLookupTextPanel] 触发主 isolate OOM。
  String _capLookupInput(String raw) {
    final Characters chars = raw.characters;
    if (chars.length <= kMaxLookupInputChars) return raw;
    debugPrint(
      '[desktop-lookup] input ${chars.length} chars exceeds '
      '$kMaxLookupInputChars; truncating for lookup.',
    );
    return chars.take(kMaxLookupInputChars).toString();
  }

  void clearPending() {
    _pendingRequest = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _pendingRequest = null;
  }

  /// TODO-341：在桌面词典页里复制文本会让 Windows 任务栏的 Hibiki 图标高亮
  /// （图标闪烁/请求注意），用户得点一下 app 才能消掉。
  ///
  /// 根因：`window_manager` 的 `show()`/`focus()` 在 Windows 上都调
  /// `SetForegroundWindow`（见 window_manager-0.5.1/windows/window_manager.cpp
  /// `Show()`/`Focus()`）。`SetForegroundWindow` 对一个**本就在前台**的窗口调用
  /// 时，会被系统的前台锁定规则拒绝并退化为「闪烁该窗口的任务栏按钮以提醒用户」
  /// （MSDN 明文）——即任务栏高亮。
  ///
  /// 修法（消除特殊情况，而非按来源打补丁）：「把待查词带到前台」对一个**已经
  /// 在前台**的窗口本就无事可做——唤前台无用、且 `SetForegroundWindow` 还会触发
  /// 任务栏 flash。所以已前台时整个调用 no-op。窗口不在前台时 `isFocused()` 为
  /// false，照常唤起。
  Future<void> bringPendingLookupToFront() => bringMainWindowToFront();

  /// 统一的桌面主窗口显式唤起出口。Hook 台词浮窗的“打开捕获工作台”等非查词
  /// 场景也必须经过这里，复用 Windows 前台归属判断和任务栏闪烁清理。
  Future<void> bringMainWindowToFront() async {
    if (!isDesktop) return;
    if (DesktopForegroundGuard.isHiddenWindowsRunner) return;
    // 已在前台无需（也不该）做任何唤起动作：对前台窗口调 SetForegroundWindow
    // 会被 Windows 前台锁定退化成任务栏 flash（TODO-341）。
    // TODO-615：前台判据抖动时此守卫可能漏判，导致先前误触的任务栏 flash 仍残留；
    // 已前台路径 early-return 前主动 clear 一次，把残留高亮幂等熄灭（FLASHW_STOP
    // 对没有 flash 的窗口是 no-op）。
    if (await _isFushiForeground()) {
      await WindowCaptionChannel.clearTaskbarFlash();
      return;
    }
    try {
      await windowManager.show();
      await windowManager.focus();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    // TODO-615：show/focus 在某些 Windows 版本上仍可能把任务栏按钮置成请求注意态
    // （即便窗口此刻确实被唤到前台）。唤前台路径尾部统一 clear 一次。
    await WindowCaptionChannel.clearTaskbarFlash();
  }

  /// 判断 Hibiki 是否已经占据前台。Windows 上不能只信
  /// [windowManager.isFocused]：词典 WebView/原生子窗口拿焦点时，插件可能报告
  /// 主窗未聚焦，但 `GetForegroundWindow` 仍属于当前 Hibiki 进程。此时继续
  /// show/focus 主窗会触发任务栏请求注意态。
  Future<bool> _isFushiForeground() async {
    if (DesktopForegroundGuard.isForegroundOwnedByCurrentProcess()) {
      return true;
    }
    if (DesktopForegroundGuard.isForegroundOwnedByFushiAppFamily()) {
      return true;
    }
    return _isWindowFocused();
  }

  /// 查询主窗口是否已在前台。插件缺失（widget 测试）或平台调用失败时保守返回
  /// false，让 [bringPendingLookupToFront] 退回到「照常唤前台」行为，
  /// 不因一次瞬态查询失败而漏掉真正需要的唤起。
  Future<bool> _isWindowFocused() async {
    try {
      return await windowManager.isFocused();
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TypeError {
      // window_manager.isFocused() does `return await invokeMethod(...)` typed
      // as Future<bool>; a host/channel that yields null (e.g. an incomplete
      // mock or a misbehaving platform impl) makes that implicit bool cast throw
      // a TypeError. Per this method's contract, any inability to determine the
      // focus state conservatively returns false so bringPendingLookupToFront
      // falls back to the "bring to front as usual" path instead of letting the
      // error escape the unawaited call into the global zone.
      return false;
    }
  }
}
