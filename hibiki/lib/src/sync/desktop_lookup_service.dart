import 'dart:async';
import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/clipboard_dedupe.dart';
import 'package:hibiki/src/sync/desktop_foreground_guard.dart';

/// 给定窗口聚焦态，剪贴板自动监听是否应触发查词。
///
/// app 在前台（聚焦）时复制 = 本 app 内部复制（制卡、选词复制等），不弹；
/// 只有 Hibiki 不在前台（用户在别的 app 复制）时，剪贴板变化才触发查词。
/// 纯函数，便于单测（见 desktop_lookup_service_test.dart）。
bool shouldTriggerOnClipboard(bool focused) => !focused;

/// 桌面剪贴板 + 全局热键查词触发器。单例 ChangeNotifier（仿 TexthookerService）。
/// 监听系统剪贴板变化与全局热键 → 去重 → 设 pendingText。
///
/// 这里不直接唤主窗前台：只有词典页实际消费 [pendingText] 并开始搜索时，
/// 才由 UI 调用 [bringPendingLookupToFront]，避免任意剪贴板变化抢前台。
///
/// 窗口聚焦跟踪（[WindowListener]）用于区分「app 内复制」与「外部 app 复制」：
/// 仅外部复制才自动弹查词；全局热键不受聚焦过滤约束（用户在别的 app 按热键
/// 查当前剪贴板属正常用法，即便随后 Hibiki 抢到前台）。
class DesktopLookupService extends ChangeNotifier
    with ClipboardListener, WindowListener {
  DesktopLookupService._();
  static final DesktopLookupService instance = DesktopLookupService._();

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  String? _pendingText;
  String? get pendingText => _pendingText;
  String? _lastText;
  bool _running = false;
  DesktopClipboardWindowMode _windowMode = DesktopClipboardWindowMode.normal;
  bool _focused = true;
  HotKey? _hotKey;

  bool get isRunning => _running;

  void submitText(String raw) {
    final String? deduped = dedupeClipboard(raw, _lastText);
    if (deduped == null) return;
    _lastText = deduped;
    _pendingText = deduped;
    notifyListeners();
  }

  void clearPending() {
    _pendingText = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _pendingText = null;
    _lastText = null;
  }

  Future<void> start({required DesktopClipboardWindowMode windowMode}) async {
    if (!isDesktop) return;
    if (_running) {
      await configureWindowMode(windowMode);
      return;
    }
    _running = true;
    await configureWindowMode(windowMode);
    windowManager.addListener(this);
    // 初始聚焦态：窗口可能尚未在前台（如开机自启），以平台真实状态为准。
    _focused = await windowManager.isFocused();
    clipboardWatcher.addListener(this);
    await clipboardWatcher.start();
    _hotKey = HotKey(
      key: PhysicalKeyboardKey.keyD,
      modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );
    await hotKeyManager.register(_hotKey!, keyDownHandler: (_) => _onHotKey());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    windowManager.removeListener(this);
    clipboardWatcher.removeListener(this);
    await clipboardWatcher.stop();
    await hotKeyManager.unregisterAll();
    _hotKey = null;
    if (_windowMode == DesktopClipboardWindowMode.lookup) {
      await _setAlwaysOnTop(false);
    }
  }

  Future<void> configureWindowMode(
    DesktopClipboardWindowMode windowMode,
  ) async {
    _windowMode = windowMode;
    if (!isDesktop) return;
    await _setAlwaysOnTop(windowMode == DesktopClipboardWindowMode.always);
  }

  Future<void> _setAlwaysOnTop(bool value) async {
    if (!isDesktop) return;
    if (DesktopForegroundGuard.isHiddenWindowsRunner) return;
    try {
      await windowManager.setAlwaysOnTop(value);
    } on MissingPluginException {
      // Widget tests and non-window-manager hosts may not install the plugin.
    } on PlatformException {
      // Keep lookup service lifecycle independent from a transient window call.
    }
  }

  @override
  void onWindowFocus() => _focused = true;

  @override
  void onWindowBlur() => _focused = false;

  /// clipboard_watcher 的 [ClipboardListener.onClipboardChanged] 返回 `void`，
  /// 故异步读取剪贴板的工作下放到不等待的 [_handleClipboardChange]。
  @override
  void onClipboardChanged() {
    unawaited(_handleClipboardChange());
  }

  Future<void> _handleClipboardChange() async {
    // app 在前台 = 本 app 内复制（制卡/选词复制），不弹查词。
    final bool foreground = _focused || await _isHibikiForeground();
    if (!shouldTriggerOnClipboard(foreground)) return;
    final String? text = await _readClipboardText();
    if (text == null || text.trim().isEmpty) return;
    submitText(text);
  }

  Future<void> _onHotKey() async {
    final String? text = await _readClipboardText();
    if (text == null || text.trim().isEmpty) return;
    _lastText = null; // 热键强制查（即便与上次相同）
    submitText(text);
  }

  /// BUG-114：Windows 剪贴板是全局独占资源——刚复制的进程可能仍持有句柄，
  /// 此刻 `OpenClipboard` 会失败（errno 5 / "Unable to open clipboard"），
  /// `Clipboard.getData` 抛 [PlatformException]。`_handleClipboardChange` 经
  /// `unawaited` 发射，异常会逃逸到全局 zone（被记成 UncaughtZone 噪音）。
  ///
  /// 这是不可控的平台竞态：做有界重试（占用方通常毫秒级释放），仍失败则放弃
  /// 本次剪贴板变化而不是把异常往外抛。返回 null 表示读取失败。
  Future<String?> _readClipboardText() async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
        return d?.text ?? '';
      } on PlatformException {
        if (attempt == 2) return null;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return null;
  }

  /// 显式查词入口（TODO-376）：把一段文本送进与剪贴板/热键完全相同的查词管线
  /// 与出口（[pendingText] → 词典页消费 → [bringPendingLookupToFront]）。
  ///
  /// 与被动剪贴板 [submitText] 的区别：这是用户的**显式**意图（在桌面悬浮字幕条上
  /// 点词），故先清 [_lastText] 越过去重——即便与上次查的是同一个词也要再查一次；
  /// 也不受 [shouldTriggerOnClipboard] 的「app 内复制不弹」聚焦过滤约束（聚焦过滤
  /// 只针对被动的剪贴板变化）。Windows 桌面悬浮字幕点词经
  /// `reader_hibiki_page.dart` 的 `_lookupFromFloatingLyric` 调到这里，从而复用
  /// 剪贴板查词出口（主窗查词 tab），而不是在阅读器内弹 in-app 浮层。
  ///
  /// 注意：本方法只负责**排队**待查词（设 [pendingText] + 通知），与剪贴板/热键
  /// 回调一致；唤前台、切到查词 tab、实际搜索都由消费侧（[bringPendingLookupToFront]
  /// + HomeDictionaryPage 挂载消费）负责，故仍满足「服务只排队、不在回调里抢前台」
  /// 的守卫契约。
  void triggerLookup(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _lastText = null; // 显式查词：越过去重，即便与上次相同也再查。
    submitText(trimmed);
  }

  /// TODO-341：在桌面词典页里复制文本会让 Windows 任务栏的 Hibiki 图标高亮
  /// （图标闪烁/请求注意），用户得点一下 app 才能消掉。
  ///
  /// 根因：`window_manager` 的 `show()`/`focus()` 在 Windows 上都调
  /// `SetForegroundWindow`（见 window_manager-0.5.1/windows/window_manager.cpp
  /// `Show()`/`Focus()`）。`SetForegroundWindow` 对一个**本就在前台**的窗口调用
  /// 时，会被系统的前台锁定规则拒绝并退化为「闪烁该窗口的任务栏按钮以提醒用户」
  /// （MSDN 明文）——即任务栏高亮。用户在词典页复制时主窗口仍在前台，却仍走到
  /// 这条唤前台路径（外部复制/失焦判据被同进程子窗口焦点切换等情形误触），于是
  /// 出现「复制即任务栏高亮」。
  ///
  /// 修法（消除特殊情况，而非按来源打补丁）：「把待查词带到前台」对一个**已经
  /// 在前台**的窗口本就无事可做——唤前台无用、置顶是用户没要的副作用、且
  /// `SetForegroundWindow` 还会触发任务栏 flash。所以已前台时整个调用 no-op。
  /// 热键/真正的外部复制场景窗口不在前台，`isFocused()` 为 false，照常唤起 +
  /// 置顶，行为不变。
  Future<void> bringPendingLookupToFront() async {
    if (!isDesktop) return;
    if (DesktopForegroundGuard.isHiddenWindowsRunner) return;
    // 已在前台无需（也不该）做任何唤起/置顶动作：对前台窗口调
    // SetForegroundWindow 会被 Windows 前台锁定退化成任务栏 flash（TODO-341）。
    if (await _isHibikiForeground()) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    if (_windowMode != DesktopClipboardWindowMode.normal) {
      await _setAlwaysOnTop(true);
    }
  }

  /// 判断 Hibiki 是否已经占据前台。Windows 上不能只信
  /// [windowManager.isFocused]：词典 WebView/原生子窗口拿焦点时，插件可能报告
  /// 主窗未聚焦，但 `GetForegroundWindow` 仍属于当前 Hibiki 进程。此时继续
  /// show/focus 主窗会触发任务栏请求注意态。
  Future<bool> _isHibikiForeground() async {
    if (DesktopForegroundGuard.isForegroundOwnedByCurrentProcess()) {
      return true;
    }
    return _isWindowFocused();
  }

  /// 查询主窗口是否已在前台。插件缺失（widget 测试）或平台调用失败时保守返回
  /// false，让 [bringPendingLookupToFront] 退回到改前的「照常唤前台」行为，
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
      // falls back to the pre-TODO-341 "bring to front as usual" path instead of
      // letting the error escape the unawaited call into the global zone.
      return false;
    }
  }
}
