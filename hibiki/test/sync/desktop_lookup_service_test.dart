import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => DesktopLookupService.instance.debugReset());

  test('submitText sets pendingText and notifies, deduped', () {
    int n = 0;
    void l() => n++;
    DesktopLookupService.instance.addListener(l);
    DesktopLookupService.instance.submitText('  見る ');
    expect(DesktopLookupService.instance.pendingText, '見る');
    expect(n, 1);
    DesktopLookupService.instance.submitText('見る');
    expect(n, 1);
    DesktopLookupService.instance.submitText('読む');
    expect(DesktopLookupService.instance.pendingText, '読む');
    expect(n, 2);
    DesktopLookupService.instance.removeListener(l);
  });

  test('clearPending resets pendingText', () {
    DesktopLookupService.instance.submitText('見る');
    DesktopLookupService.instance.clearPending();
    expect(DesktopLookupService.instance.pendingText, isNull);
  });

  test('shouldTriggerOnClipboard: app 内复制(聚焦)不触发, 外部复制(失焦)触发', () {
    // Hibiki 在前台聚焦 = 本 app 内复制（制卡/选词复制），不弹查词。
    expect(shouldTriggerOnClipboard(true), isFalse);
    // Hibiki 不在前台 = 用户在别的 app 复制，剪贴板变化触发查词。
    expect(shouldTriggerOnClipboard(false), isTrue);
  });

  // BUG-114：Windows 剪贴板被占用时 Clipboard.getData 抛 PlatformException，
  // 不得逃逸到 zone（否则记成 UncaughtZone 噪音），且不得误触发查词。
  testWidgets('clipboard busy (PlatformException) is swallowed, no lookup',
      (WidgetTester tester) async {
    Object? escaped;
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        throw PlatformException(
          code: 'Clipboard error',
          message: 'Unable to open clipboard',
        );
      }
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();
    svc.onWindowBlur(); // 失焦 → 剪贴板变化应触发读取

    await tester.runAsync(() async {
      try {
        svc.onClipboardChanged();
        // 覆盖 3 次重试 + 2×50ms 退避。
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } catch (e) {
        escaped = e;
      }
    });

    expect(escaped, isNull); // 异常没有逃逸
    expect(svc.pendingText, isNull); // 读取失败 → 没有误提交查词

    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
