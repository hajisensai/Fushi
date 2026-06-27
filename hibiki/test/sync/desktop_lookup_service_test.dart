import 'package:flutter/services.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/desktop_foreground_guard.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/misc/lookup_input_limits.dart';
import 'package:characters/characters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DesktopLookupService.instance.debugReset();
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = false;
    DesktopForegroundGuard.debugHiddenWindowsRunner = false;
    // TODO-615: bringPendingLookupToFront 现在会经 WindowCaptionChannel 下发
    // clearTaskbarFlash 到 app.hibiki/window。在 Windows 测试宿主上，未 mock 的平台
    // 通道 invokeMethod 永不完成（无平台实现应答）会让 await 挂死。默认应答该通道
    // （返回 null = 立即完成）；想观察该调用的用例可各自再覆盖 handler 收集调用。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('app.hibiki/window'),
      (MethodCall call) async => null,
    );
  });
  tearDown(() {
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = null;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = null;
    DesktopForegroundGuard.debugHiddenWindowsRunner = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('app.hibiki/window'), null);
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

  // TODO-615 方案A：剪贴板/热键查词在主窗已前台时仍误触 SetForegroundWindow 退化成
  // 任务栏 flash（TODO-341）。判前台守卫在前台判据抖动时可能漏判而留下残留高亮，
  // 升级为「已前台 early-return 前主动 clearTaskbarFlash 一次」幂等熄灭残留高亮。
  // clearTaskbarFlash 只走 app.hibiki/window 单一封装（WindowCaptionChannel）。
  testWidgets(
      'focused window clears taskbar flash before no-op return (TODO-615)',
      (WidgetTester tester) async {
    final List<String> windowCalls = <String>[];
    final List<String> captionCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call.method);
      if (call.method == 'isMinimized') return false;
      if (call.method == 'isFocused') return true; // 窗口已在前台
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('app.hibiki/window'),
        (MethodCall call) async {
      captionCalls.add(call.method);
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await svc.configureWindowMode(DesktopClipboardWindowMode.lookup);
    windowCalls.clear();
    await svc.bringPendingLookupToFront();

    // 已前台仍 no-op 唤起/置顶（TODO-341 不回退）。
    expect(windowCalls, isNot(contains('show')));
    expect(windowCalls, isNot(contains('focus')));
    expect(windowCalls, isNot(contains('setAlwaysOnTop')));
    // 但主动熄灭残留任务栏高亮（TODO-615·clearTaskbarFlash 仅 Windows 下发 channel）。
    if (Platform.isWindows) {
      expect(captionCalls, contains('clearTaskbarFlash'));
    }
  });

  // TODO-615：真正的外部复制/热键场景窗口不在前台 → 照常 show/focus/置顶，唤前台
  // 路径尾部也无论如何 clearTaskbarFlash 一次（覆盖 always-on-top 路径在某些
  // Windows 版本仍引发任务栏请求注意态的残留）。
  testWidgets(
      'foreground path clears taskbar flash after show/focus (TODO-615)',
      (WidgetTester tester) async {
    final List<String> windowCalls = <String>[];
    final List<String> captionCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      windowCalls.add(call.method);
      if (call.method == 'isMinimized') return false;
      if (call.method == 'isFocused') return false; // 不在前台 → 走唤前台路径
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('app.hibiki/window'),
        (MethodCall call) async {
      captionCalls.add(call.method);
      return null;
    });

    final DesktopLookupService svc = DesktopLookupService.instance;
    svc.debugReset();

    await svc.configureWindowMode(DesktopClipboardWindowMode.lookup);
    windowCalls.clear();
    captionCalls.clear();
    await svc.bringPendingLookupToFront();

    expect(windowCalls, containsAllInOrder(<String>['show', 'focus']));
    expect(windowCalls.any(_setsAlwaysOnTop2), isTrue, reason: '置顶模式唤起后应置顶');
    // 唤前台后清掉可能残留的任务栏高亮（clearTaskbarFlash 仅 Windows 下发 channel）。
    if (Platform.isWindows) {
      expect(captionCalls, contains('clearTaskbarFlash'));
    }
  });

  // BUG-442：剪贴板/热键/显式查词排队入口对超长串统一截断到 kMaxLookupInputChars
  // 码点（防止超长文本流到逐字渲染的 SourceLookupTextPanel 把主 isolate 撑爆）。
  test('submitText caps over-long input to kMaxLookupInputChars (BUG-442)', () {
    final String longText = 'あ' * (kMaxLookupInputChars + 500);
    DesktopLookupService.instance.submitText(longText);
    final String? pending = DesktopLookupService.instance.pendingText;
    expect(pending, isNotNull);
    expect(pending!.characters.length, kMaxLookupInputChars);
  });

  test('triggerLookup caps over-long input to kMaxLookupInputChars (BUG-442)',
      () {
    final String longText = 'い' * (kMaxLookupInputChars * 3);
    DesktopLookupService.instance.triggerLookup(longText);
    final String? pending = DesktopLookupService.instance.pendingText;
    expect(pending, isNotNull);
    expect(pending!.characters.length, kMaxLookupInputChars);
  });

  test('input exactly at the cap is not truncated (BUG-442 boundary)', () {
    final String exact = 'う' * kMaxLookupInputChars;
    DesktopLookupService.instance.submitText(exact);
    expect(
      DesktopLookupService.instance.pendingText!.characters.length,
      kMaxLookupInputChars,
    );

    // 上限 + 1 → 截掉恰好一个码点。
    DesktopLookupService.instance.debugReset();
    DesktopLookupService.instance.submitText('え' * (kMaxLookupInputChars + 1));
    expect(
      DesktopLookupService.instance.pendingText!.characters.length,
      kMaxLookupInputChars,
    );
  });

  test('emoji surrogate pairs are not split when capping (BUG-442)', () {
    // 每个 emoji 是一个 grapheme（两个 UTF-16 码元）。用 characters 截断不应
    // 在代理对中间切断产生孤立代理项。构造 cap+10 个 emoji，截断到 cap 个。
    const String emoji = '😀';
    final String longText = emoji * (kMaxLookupInputChars + 10);
    DesktopLookupService.instance.submitText(longText);
    final String pending = DesktopLookupService.instance.pendingText!;
    expect(pending.characters.length, kMaxLookupInputChars);
    // 每个 grapheme 是完整 emoji（两码元），总码元数 = 2 × kMaxLookupInputChars。
    expect(pending.length, kMaxLookupInputChars * 2);
    for (final String g in pending.characters) {
      expect(g, emoji);
    }
  });
}

bool _setsAlwaysOnTop2(String method) => method == 'setAlwaysOnTop';

bool _setsAlwaysOnTop(MethodCall call) {
  final Object? arguments = call.arguments;
  return call.method == 'setAlwaysOnTop' &&
      arguments is Map &&
      arguments['isAlwaysOnTop'] == true;
}
