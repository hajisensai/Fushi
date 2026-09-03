import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';

/// 桌面显式查词排队器（深链 / 浏览器扩展 / 悬浮字幕点词的共同出口）。
///
/// 剪贴板监听 / 全局热键 / 窗口置顶模式已随「剪贴板查词」功能整体删除；本服务只剩
/// 「排队 + 通知 + 唤前台」三件事，这里钉住排队语义与源码层的删除结果。
void main() {
  setUp(() => DesktopLookupService.instance.debugReset());
  tearDown(() => DesktopLookupService.instance.debugReset());

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
