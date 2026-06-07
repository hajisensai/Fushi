import 'dart:async';
import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hibiki/src/sync/clipboard_dedupe.dart';

/// 桌面剪贴板 + 全局热键查词触发器。单例 ChangeNotifier（仿 TexthookerService）。
/// 监听系统剪贴板变化与全局热键 → 去重 → 设 pendingText + 唤主窗前台。
class DesktopLookupService extends ChangeNotifier with ClipboardListener {
  DesktopLookupService._();
  static final DesktopLookupService instance = DesktopLookupService._();

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  String? _pendingText;
  String? get pendingText => _pendingText;
  String? _lastText;
  bool _running = false;
  bool _alwaysOnTop = false;
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
    clipboardWatcher.removeListener(this);
    await clipboardWatcher.stop();
    await hotKeyManager.unregisterAll();
    _hotKey = null;
  }

  /// clipboard_watcher 的 [ClipboardListener.onClipboardChanged] 返回 `void`，
  /// 故异步读取剪贴板的工作下放到不等待的 [_handleClipboardChange]。
  @override
  void onClipboardChanged() {
    unawaited(_handleClipboardChange());
  }

  Future<void> _handleClipboardChange() async {
    final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = d?.text ?? '';
    if (text.trim().isEmpty) return;
    submitText(text);
    await _bringToFront();
  }

  Future<void> _onHotKey() async {
    final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = d?.text ?? '';
    if (text.trim().isEmpty) return;
    _lastText = null; // 热键强制查（即便与上次相同）
    submitText(text);
    await _bringToFront();
  }

  Future<void> _bringToFront() async {
    if (!isDesktop) return;
    await windowManager.show();
    await windowManager.focus();
    if (_alwaysOnTop) await windowManager.setAlwaysOnTop(true);
  }
}
