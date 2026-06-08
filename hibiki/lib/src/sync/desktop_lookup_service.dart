import 'dart:async';
import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hibiki/src/sync/clipboard_dedupe.dart';

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
  bool _alwaysOnTop = false;
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

  Future<void> start({required bool alwaysOnTop}) async {
    if (!isDesktop || _running) return;
    _running = true;
    _alwaysOnTop = alwaysOnTop;
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
    if (!shouldTriggerOnClipboard(_focused)) return;
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

  Future<void> bringPendingLookupToFront() async {
    if (!isDesktop) return;
    await windowManager.show();
    await windowManager.focus();
    if (_alwaysOnTop) await windowManager.setAlwaysOnTop(true);
  }
}
