import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';

/// 桌面显式查词排队器（深链 / 浏览器扩展 / 悬浮字幕点词的共同出口）。
///
/// 剪贴板监听 / 全局热键 / 窗口置顶模式已随「剪贴板查词」功能整体删除；本服务只剩
/// 「排队 + 通知 + 唤前台」三件事，这里钉住排队语义与源码层的删除结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => DesktopLookupService.instance.debugReset());
  tearDown(() {
    DesktopLookupService.instance.debugReset();
    DesktopForegroundGuard.debugHiddenWindowsRunner = null;
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = null;
    DesktopForegroundGuard.debugForegroundOwnedByFushiAppFamily = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  /// 桩掉 window_manager 通道：记录方法序列，[minimized] 决定 isMinimized 的答复。
  List<String> mockWindowManager({required bool minimized}) {
    final List<String> calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'isMinimized':
            return minimized;
          case 'isFocused':
            return false;
          default:
            return null;
        }
      },
    );
    return calls;
  }

  // 查词页「返回上一级」最小化主窗（用户请求，Flow Launcher 式用法）的两个出口：
  // 去程 minimizeMainWindow 真发 minimize；回程 bringMainWindowToFront 对已最小化
  // 的窗口先 restore 再 show/focus（macOS 的 makeKeyAndOrderFront 不会
  // deminiaturize，少了这步热键回来只会在 Dock 里闪一下）。
  group('查词页 Esc 最小化 ↔ 热键回来', () {
    test('minimizeMainWindow：桌面上真发 minimize 并返回 true', () async {
      DesktopForegroundGuard.debugHiddenWindowsRunner = false;
      final List<String> calls = mockWindowManager(minimized: false);

      final bool sent =
          await DesktopLookupService.instance.minimizeMainWindow();

      expect(sent, DesktopLookupService.isDesktop);
      expect(calls,
          DesktopLookupService.isDesktop ? <String>['minimize'] : isEmpty);
    });

    test('minimizeMainWindow：隐藏 runner 里不动窗口、返回 false', () async {
      DesktopForegroundGuard.debugHiddenWindowsRunner = true;
      final List<String> calls = mockWindowManager(minimized: false);

      expect(await DesktopLookupService.instance.minimizeMainWindow(), isFalse);
      expect(calls, isEmpty);
    });

    test('bringMainWindowToFront：已最小化时 restore 排在 show/focus 之前', () async {
      if (!DesktopLookupService.isDesktop) return;
      DesktopForegroundGuard.debugHiddenWindowsRunner = false;
      DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
      DesktopForegroundGuard.debugForegroundOwnedByFushiAppFamily = false;
      final List<String> calls = mockWindowManager(minimized: true);

      await DesktopLookupService.instance.bringMainWindowToFront();

      expect(calls, contains('restore'));
      expect(calls.indexOf('restore'), lessThan(calls.indexOf('show')));
      expect(calls.indexOf('show'), lessThan(calls.indexOf('focus')));
    });

    test('bringMainWindowToFront：没最小化就不发 restore', () async {
      if (!DesktopLookupService.isDesktop) return;
      DesktopForegroundGuard.debugHiddenWindowsRunner = false;
      DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
      DesktopForegroundGuard.debugForegroundOwnedByFushiAppFamily = false;
      final List<String> calls = mockWindowManager(minimized: false);

      await DesktopLookupService.instance.bringMainWindowToFront();

      expect(calls, isNot(contains('restore')));
      expect(calls, containsAllInOrder(<String>['show', 'focus']));
    });
  });

  test('triggerLookup trims, queues and notifies', () {
    int notified = 0;
    void listener() => notified++;
    DesktopLookupService.instance.addListener(listener);
    addTearDown(() => DesktopLookupService.instance.removeListener(listener));

    DesktopLookupService.instance.triggerLookup('  日本語  ');
    expect(DesktopLookupService.instance.pendingText, '日本語');
    expect(notified, 1);
  });

  test('blank text never queues', () {
    int notified = 0;
    void listener() => notified++;
    DesktopLookupService.instance.addListener(listener);
    addTearDown(() => DesktopLookupService.instance.removeListener(listener));

    DesktopLookupService.instance.triggerLookup('   ');
    expect(DesktopLookupService.instance.pendingRequest, isNull);
    expect(notified, 0);
  });

  test('same word twice re-queues (explicit intent, no dedupe)', () {
    int notified = 0;
    void listener() => notified++;
    DesktopLookupService.instance.addListener(listener);
    addTearDown(() => DesktopLookupService.instance.removeListener(listener));

    DesktopLookupService.instance.triggerLookup('猫');
    DesktopLookupService.instance.clearPending();
    DesktopLookupService.instance.triggerLookup('猫');
    expect(DesktopLookupService.instance.pendingText, '猫');
    expect(notified, 3, reason: 'trigger / clear / trigger 各通知一次');
  });

  test('BUG-442: input is capped to kMaxLookupInputChars code points', () {
    final String huge = 'あ' * (kMaxLookupInputChars + 50);
    DesktopLookupService.instance.triggerLookup(huge);
    expect(
      DesktopLookupService.instance.pendingText!.runes.length,
      kMaxLookupInputChars,
    );
  });

  test('source guard: no clipboard watcher / hotkey / always-on-top left', () {
    final String src = File(
      'lib/src/sync/desktop_lookup_service.dart',
    ).readAsStringSync();
    for (final String banned in <String>[
      'clipboard_watcher',
      'ClipboardListener',
      'hotkey_manager',
      'setAlwaysOnTop',
      'DesktopClipboardWindowMode',
    ]) {
      expect(src.contains(banned), isFalse, reason: '剪贴板查词已删，服务里不得残留 $banned');
    }
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec.contains('clipboard_watcher'),
      isFalse,
      reason: 'clipboard_watcher 依赖随功能一起删除',
    );
  });
}
