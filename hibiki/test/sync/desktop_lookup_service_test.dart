import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/desktop_foreground_guard.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DesktopLookupService.instance.debugReset();
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = false;
    DesktopForegroundGuard.debugHiddenWindowsRunner = false;
  });
  tearDown(() {
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = null;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = null;
    DesktopForegroundGuard.debugHiddenWindowsRunner = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  test('submitText sets pendingText and notifies, deduped', () {
    int n = 0;
    void l() => n++;
    DesktopLookupService.instance.addListener(l);
    DesktopLookupService.instance.submitText('  見る ');
    expect(DesktopLookupService.instance.pendingText, '見る');
    expect(DesktopLookupService.instance.pendingRequest?.text, '見る');
    expect(
      DesktopLookupService.instance.pendingRequest?.origin,
      DesktopLookupOrigin.clipboard,
    );
    expect(
      DesktopLookupService.instance.pendingRequest?.foregroundPolicy,
      DesktopLookupForegroundPolicy.bringToFront,
    );
    expect(
        DesktopLookupService.instance.pendingRequest?.showSourcePanel, isTrue);
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

  // TODO-376：桌面悬浮字幕点词复用剪贴板查词出口。triggerLookup 是显式查词入口
  // （热键 / 悬浮字幕点词共用）：去空白后排进 pendingText 并通知，且**越过去重**
  // ——连点同一个词也要每次都能再查（submitText 自身对相同词会去重）。
  test('triggerLookup queues pendingText, bypasses dedupe, ignores blank', () {
    int n = 0;
    void l() => n++;
    DesktopLookupService.instance.addListener(l);

    DesktopLookupService.instance.triggerLookup('  良い ');
    expect(DesktopLookupService.instance.pendingText, '良い');
    expect(
      DesktopLookupService.instance.pendingRequest?.origin,
      DesktopLookupOrigin.explicit,
    );
    expect(
        DesktopLookupService.instance.pendingRequest?.showSourcePanel, isTrue);
    expect(n, 1);

    // 显式再查同一个词：必须越过去重再次排队（剪贴板被动 submitText 会去重，
    // 这正是 triggerLookup 与 submitText 的关键区别）。
    DesktopLookupService.instance.clearPending(); // n=2
    DesktopLookupService.instance.triggerLookup('良い');
    expect(DesktopLookupService.instance.pendingText, '良い');
    expect(n, 3);

    // 空白文本是 no-op（不排队、不通知）。
    DesktopLookupService.instance.triggerLookup('   ');
    expect(n, 3);

    DesktopLookupService.instance.removeListener(l);
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
  });

  testWidgets('clipboard hit queues lookup but waits for UI before foreground',
      (WidgetTester tester) async {
    final List<String> windowCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': '  見る  '};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call.method);
      if (call.method == 'isFocused') return false;
      if (call.method == 'isMinimized') return false;
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();
    svc.onWindowBlur();

    await tester.runAsync(() async {
      svc.onClipboardChanged();
      await Future<void>.delayed(Duration.zero);
    });

    expect(svc.pendingText, '見る');
    expect(windowCalls, isNot(contains('show')));
    expect(windowCalls, isNot(contains('focus')));

    await svc.bringPendingLookupToFront();

    expect(windowCalls, containsAllInOrder(<String>['show', 'focus']));
  });

  testWidgets('clipboard change inside foreground process is ignored',
      (WidgetTester tester) async {
    final List<String> platformCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = true;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      platformCalls.add(call.method);
      if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': '  見る  '};
      }
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();
    svc.onWindowBlur(); // WebView/native child can make window_manager blur.

    await tester.runAsync(() async {
      svc.onClipboardChanged();
      await Future<void>.delayed(Duration.zero);
    });

    expect(svc.pendingText, isNull);
    expect(platformCalls, isNot(contains('Clipboard.getData')));
  });

  testWidgets('clipboard change inside Hibiki app-family foreground is ignored',
      (WidgetTester tester) async {
    final List<String> platformCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = true;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      platformCalls.add(call.method);
      if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': '  見る  '};
      }
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();
    svc.onWindowBlur(); // foreground can be another Hibiki process/window.

    await tester.runAsync(() async {
      svc.onClipboardChanged();
      await Future<void>.delayed(Duration.zero);
    });

    expect(svc.pendingRequest, isNull);
    expect(platformCalls, isNot(contains('Clipboard.getData')));
  });

  testWidgets(
      'hotkey queues a hotkey-origin request without foregrounding early',
      (WidgetTester tester) async {
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': '  早い  '};
      }
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await tester.runAsync(() async {
      await svc.debugTriggerHotKey();
    });

    expect(svc.pendingText, '早い');
    expect(svc.pendingRequest?.origin, DesktopLookupOrigin.hotkey);
    expect(
      svc.pendingRequest?.foregroundPolicy,
      DesktopLookupForegroundPolicy.bringToFront,
    );
    expect(svc.pendingRequest?.showSourcePanel, isTrue);
  });

  testWidgets('window mode controls always-on-top timing',
      (WidgetTester tester) async {
    final List<MethodCall> windowCalls = <MethodCall>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call);
      if (call.method == 'isMinimized') return false;
      // 窗口不在前台 → 走真正的唤前台路径（本测试关心置顶时机，TODO-341）。
      if (call.method == 'isFocused') return false;
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await svc.configureWindowMode(DesktopClipboardWindowMode.normal);
    await svc.bringPendingLookupToFront();
    expect(
      windowCalls.where(_setsAlwaysOnTop),
      isEmpty,
      reason: '正常应用模式不应在查词时设置置顶',
    );

    windowCalls.clear();
    await svc.configureWindowMode(DesktopClipboardWindowMode.lookup);
    await svc.bringPendingLookupToFront();
    expect(
      windowCalls.any(_setsAlwaysOnTop),
      isTrue,
      reason: '查词时置顶模式应在查词窗口被唤起时置顶',
    );

    windowCalls.clear();
    await svc.configureWindowMode(DesktopClipboardWindowMode.always);
    expect(
      windowCalls.any(_setsAlwaysOnTop),
      isTrue,
      reason: '置顶模式应立即设置窗口置顶',
    );
  });

  testWidgets('foreground platform failure does not escape lookup request',
      (WidgetTester tester) async {
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      if (call.method == 'isMinimized') return false;
      if (call.method == 'isFocused') return false; // 不在前台 → 走唤前台路径
      if (call.method == 'show') {
        throw PlatformException(code: 'window-failed');
      }
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await expectLater(svc.bringPendingLookupToFront(), completes);
  });

  // TODO-341：在桌面词典页里复制文本 → Windows 任务栏 Hibiki 图标高亮。根因 =
  // 窗口已在前台时仍走唤前台路径，window_manager 的 show()/focus() 对前台窗口
  // 调 SetForegroundWindow 被前台锁定退化成任务栏 flash。守卫：窗口已在前台时
  // bringPendingLookupToFront 一律 no-op（不 show/focus/setAlwaysOnTop）。
  testWidgets('focused window: bringPendingLookupToFront is a no-op (TODO-341)',
      (WidgetTester tester) async {
    final List<String> windowCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call.method);
      if (call.method == 'isMinimized') return false;
      if (call.method == 'isFocused') return true; // 窗口已在前台
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    // 即使在置顶模式，已前台也不应做任何窗口动作（否则触发任务栏 flash）。
    await svc.configureWindowMode(DesktopClipboardWindowMode.lookup);
    windowCalls.clear();
    await svc.bringPendingLookupToFront();

    expect(windowCalls, isNot(contains('show')));
    expect(windowCalls, isNot(contains('focus')));
    expect(windowCalls, isNot(contains('setAlwaysOnTop')));
  });

  testWidgets(
      'foreground owned by current process: bringPendingLookupToFront is no-op',
      (WidgetTester tester) async {
    final List<String> windowCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = true;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call.method);
      if (call.method == 'isFocused') return false;
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await svc.configureWindowMode(DesktopClipboardWindowMode.lookup);
    windowCalls.clear();
    await svc.bringPendingLookupToFront();

    expect(windowCalls, isNot(contains('show')));
    expect(windowCalls, isNot(contains('focus')));
    expect(windowCalls, isNot(contains('setAlwaysOnTop')));
  });

  testWidgets('hidden Windows runner never performs window attention calls',
      (WidgetTester tester) async {
    final List<String> windowCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    DesktopForegroundGuard.debugHiddenWindowsRunner = true;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call.method);
      if (call.method == 'isFocused') return false;
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await svc.configureWindowMode(DesktopClipboardWindowMode.lookup);
    await svc.bringPendingLookupToFront();

    expect(windowCalls, isEmpty);
  });

  // A host/channel where window_manager.isFocused() resolves to null (incomplete
  // mock or misbehaving platform impl) makes window_manager's implicit bool cast
  // throw a TypeError. _isWindowFocused must swallow it and conservatively report
  // not-focused so the error never escapes the unawaited bringPendingLookupToFront
  // call into the global zone, and the foreground path still runs.
  testWidgets('isFocused null does not escape; foreground path still runs',
      (WidgetTester tester) async {
    final List<String> windowCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call.method);
      if (call.method == 'isMinimized') return false;
      // Intentionally return null for isFocused -> implicit bool cast throws.
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await expectLater(svc.bringPendingLookupToFront(), completes);
    expect(windowCalls, containsAllInOrder(<String>['show', 'focus']));
  });
}

bool _setsAlwaysOnTop(MethodCall call) {
  final Object? arguments = call.arguments;
  return call.method == 'setAlwaysOnTop' &&
      arguments is Map &&
      arguments['isAlwaysOnTop'] == true;
}
