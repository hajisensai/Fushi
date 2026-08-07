import 'package:flutter/services.dart';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/clipboard_history_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';
import 'package:characters/characters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DesktopLookupService.instance.debugReset();
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = false;
    DesktopForegroundGuard.debugHiddenWindowsRunner = false;
    // TODO-615: bringPendingLookupToFront 现在会经 WindowCaptionChannel 下发
    // clearTaskbarFlash 到 app.fushi/window。在 Windows 测试宿主上，未 mock 的平台
    // 通道 invokeMethod 永不完成（无平台实现应答）会让 await 挂死。默认应答该通道
    // （返回 null = 立即完成）；想观察该调用的用例可各自再覆盖 handler 收集调用。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('app.fushi/window'),
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
            const MethodChannel('app.fushi/window'), null);
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
    // TODO-1355：被动剪贴板变化不抢焦点 → foregroundPolicy 必须是 none（不是
    // bringToFront）。消费侧只在 bringToFront 时才唤前台。
    expect(
      DesktopLookupService.instance.pendingRequest?.foregroundPolicy,
      DesktopLookupForegroundPolicy.none,
    );
    expect(
        DesktopLookupService.instance.pendingRequest?.showSourcePanel, isTrue);
    expect(
      DesktopLookupService.instance.pendingRequest?.allowsAutomaticAudio,
      isFalse,
      reason: '剪贴板内容变化不代表用户要求播放声音',
    );
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
    expect(
      DesktopLookupService.instance.pendingRequest?.allowsAutomaticAudio,
      isTrue,
      reason: '显式点词可继续遵循自动朗读偏好',
    );
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
    // TODO-1355：外部复制的剪贴板命中排队后来源策略必须是 none（不抢焦点）。
    expect(
      svc.pendingRequest?.foregroundPolicy,
      DesktopLookupForegroundPolicy.none,
    );

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
  // clearTaskbarFlash 只走 app.fushi/window 单一封装（WindowCaptionChannel）。
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
    messenger.setMockMethodCallHandler(const MethodChannel('app.fushi/window'),
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
    messenger.setMockMethodCallHandler(const MethodChannel('app.fushi/window'),
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

  // TODO-1355：被动剪贴板变化不得把窗口拉前台/抢焦点。两道守卫：
  //   ① 服务侧：clipboard 来源的排队请求带 foregroundPolicy.none（见上面 submitText 用例）。
  //   ② 消费侧：HomeDictionaryPage._runDesktopLookup 只在 foregroundPolicy==bringToFront
  //      时才调 bringPendingLookupToFront；none（剪贴板）只搜索、不唤前台。
  // 本用例守护 ②：若有人把消费侧的策略门控删掉/改成无条件唤前台，剪贴板变化又会
  // 抢焦点，测试立即红。
  test(
      'consumer only foregrounds when foregroundPolicy is bringToFront '
      '(TODO-1355)', () {
    final String page = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();
    final int runStart = page.indexOf('void _runDesktopLookup(');
    expect(runStart, isNonNegative,
        reason: 'consumer entry _runDesktopLookup must exist.');
    final int runEnd = page.indexOf('void _onFocusChanged()', runStart);
    expect(runEnd, greaterThan(runStart));
    final String body = page.substring(runStart, runEnd);

    // 唤前台调用必须存在，但必须被 bringToFront 策略门控住。
    final int guard =
        body.indexOf('DesktopLookupForegroundPolicy.bringToFront');
    final int foreground = body.indexOf('bringPendingLookupToFront');
    expect(guard, isNonNegative,
        reason: 'foreground must be gated on the bringToFront policy.');
    expect(foreground, isNonNegative);
    expect(guard < foreground, isTrue,
        reason: 'the bringToFront policy check must precede the foreground '
            'call so a clipboard (none) lookup never steals focus.');
  });

  // TODO-1355：submitText（剪贴板来源）源码必须显式带 foregroundPolicy.none，
  // 不能回退到默认 bringToFront（默认值一旦被误用，剪贴板又会抢焦点）。
  test(
      'submitText source pins clipboard origin to foregroundPolicy.none '
      '(TODO-1355)', () {
    final String service =
        File('lib/src/sync/desktop_lookup_service.dart').readAsStringSync();
    // 匹配签名前缀（galgame UX 统一后 submitText 增加了可选具名参数
    // `{bool passiveStream}`，故不再匹配到闭合括号）。
    final int start = service.indexOf('void submitText(String raw');
    expect(start, isNonNegative);
    final int end = service.indexOf('void _queueLookupRequest(', start);
    expect(end, greaterThan(start));
    final String body = service.substring(start, end);
    expect(body.contains('DesktopLookupForegroundPolicy.none'), isTrue,
        reason: 'passive clipboard lookups must not bring the window to '
            'the foreground / steal focus.');
  });

  // BUG-1025 回归守卫：用户在浏览器里复制同一个词两次，第二次必须也能查。旧实现用
  // 永久内容去重（_lastText 相等即丢弃），把用户的显式重复复制误判成自触发回声。
  // 现改为时间窗：窗口内的同词仍当回声吞掉（防挖词/抓选区写回自触发循环），超窗口放行。
  group('剪贴板同词重复复制 (BUG-1025)', () {
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 7, 23, 12, 0, 0);
      DesktopLookupService.instance.clock = () => fakeNow;
    });

    tearDown(() {
      DesktopLookupService.instance.clock = DateTime.now;
    });

    test('窗口内重复同一文本仍被当作自触发回声吞掉', () {
      final DesktopLookupService service = DesktopLookupService.instance;
      service.submitText('見る');
      expect(service.pendingText, '見る');
      service.clearPending();

      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      service.submitText('見る');
      expect(service.pendingText, isNull, reason: '窗口内的同词是挖词/抓选区写回的回声，必须继续吞掉');
    });

    test('超出窗口后重复复制同一个词必须重新排队查词', () {
      final DesktopLookupService service = DesktopLookupService.instance;
      service.submitText('見る');
      expect(service.pendingText, '見る');
      service.clearPending();

      fakeNow = fakeNow.add(const Duration(seconds: 3));
      service.submitText('見る');
      expect(service.pendingText, '見る',
          reason: '用户手动再次复制同一个词查不了，正是 BUG-1025 的用户症状');
    });

    test('不同的词不受时间窗影响，恒放行', () {
      final DesktopLookupService service = DesktopLookupService.instance;
      service.submitText('見る');
      service.clearPending();
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      service.submitText('読む');
      expect(service.pendingText, '読む');
    });
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

  // BUG-1145：桌面「剪贴板复制历史」🕘 面板永远是空的。根因不是读侧——DB 表、
  // 仓库、payload、面板 UI、i18n 全都在——而是 [DesktopLookupService.onClipboardCaptured]
  // 这个采集回调自 24e6443bb 引入起就只有声明 + AppModel 的赋值，**零调用点**，
  // 于是 add() 永不发生，用户每次点开都命中空态。本组是该路径的首个覆盖（此前 0
  // 测试，正是它潜伏这么久、CI 一直绿的原因），直接打到真实
  // [ClipboardHistoryRepository] + 内存 Drift 库上，钉死「剪贴板来源写穿到历史 /
  // 非剪贴板来源不写 / 重复复制不堆重复行」三条契约。
  group('剪贴板复制历史采集 (BUG-1145)', () {
    late FushiDatabase db;
    late ClipboardHistoryRepository repo;
    late DateTime fakeNow;

    setUp(() {
      // 外层 setUp 已跑过 debugReset（会把 onClipboardCaptured 清成 null），故本组的
      // 装配必须在它之后——group 的 setUp 恒后于外层 setUp 执行。
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = ClipboardHistoryRepository(db);
      fakeNow = DateTime(2026, 7, 27, 9, 0, 0);
      final DesktopLookupService service = DesktopLookupService.instance;
      service.clock = () => fakeNow;
      // 与 AppModel.addClipboardHistoryEntry 同构的装配（生产侧那行赋值由本组末尾的
      // 源码守卫单独钉住）；时刻用假时钟保证顺序断言确定。
      service.onClipboardCaptured = (String text) => repo.add(text, fakeNow);
    });

    tearDown(() async {
      DesktopLookupService.instance.onClipboardCaptured = null;
      DesktopLookupService.instance.clock = DateTime.now;
      repo.dispose();
      await db.close();
    });

    test('剪贴板复制的文本真的写进历史仓库并落库', () async {
      final DesktopLookupService service = DesktopLookupService.instance;

      service.submitText('  見る ');

      // 内存层：进了仓库，且是 trim 后的纯基准文本。
      expect(
        repo.entries.map((ClipboardHistoryEntry e) => e.text),
        <String>['見る'],
        reason: '这正是 BUG-1145 的用户症状——采集点缺失时这里恒为空',
      );
      expect(repo.entries.single.copiedAt, fakeNow);
      // 查词管线不受影响（采集是旁路副作用，不能吃掉原有行为）。
      expect(service.pendingText, '見る');

      // 写穿层：debounce 刷盘后真的有行落到 clipboard_history 表。
      await repo.flushNow();
      final List<ClipboardHistoryRow> rows = await db.getAllClipboardHistory();
      expect(rows.map((ClipboardHistoryRow r) => r.content), <String>['見る']);
    });

    test('多次复制不同文本按时间顺序累积（队尾 = 最新）', () async {
      final DesktopLookupService service = DesktopLookupService.instance;

      service.submitText('見る');
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      service.submitText('読む');
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      service.submitText('走る');

      expect(
        repo.entries.map((ClipboardHistoryEntry e) => e.text),
        <String>['見る', '読む', '走る'],
      );
    });

    // 负向契约：热键查词 / 悬浮字幕点词是「查词」不是「复制」，不得污染复制历史。
    // 用普通 async test 而非 testWidgets：ClipboardHistoryRepository.add 会起一个真实
    // 的 debounce 刷盘 Timer，testWidgets 的 FakeAsync 收尾时会因「仍有 pending Timer」
    // 直接判红（该 Timer 由 tearDown 的 repo.dispose() 取消）。
    // 两者都走 dedupe:false 分支，压根到不了采集点；本用例守住这条边界，防止有人
    // 把采集点上移到 _queueLookupRequest 顶部或删掉 origin 判定。
    test('热键与悬浮字幕点词不写进复制历史', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform,
              (MethodCall call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': '  早い  '};
        }
        return null;
      });

      final DesktopLookupService service = DesktopLookupService.instance;

      // ① 全局热键（origin=hotkey）。
      await service.debugTriggerHotKey();
      expect(service.pendingRequest?.origin, DesktopLookupOrigin.hotkey);
      expect(service.pendingText, '早い', reason: '热键查词本身必须照常发生');
      expect(repo.entries, isEmpty, reason: '热键查词不是「复制」，不计入复制历史');

      // ② 悬浮字幕点词（origin=explicit）。
      service.triggerLookup('良い');
      expect(service.pendingRequest?.origin, DesktopLookupOrigin.explicit);
      expect(service.pendingText, '良い', reason: '点词查词本身必须照常发生');
      expect(repo.entries, isEmpty, reason: '点词查词不是「复制」，不计入复制历史');

      // 只有真正的剪贴板来源才落历史（同一组里作正向对照，证明上面的空不是装配没接上）。
      service.submitText('見る');
      expect(
        repo.entries.map((ClipboardHistoryEntry e) => e.text),
        <String>['見る'],
      );
    });

    test('去重窗口内的自触发回声不写进历史', () {
      final DesktopLookupService service = DesktopLookupService.instance;

      service.submitText('見る');
      expect(repo.entries, hasLength(1));
      service.clearPending();

      // 窗口内（<800ms）的同词 = 挖词/抓选区写回的回声，dedupeClipboard 判 null，
      // 采集点在其后故一并跳过。
      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      service.submitText('見る');

      expect(service.pendingText, isNull, reason: '回声本来就不该触发查词');
      expect(repo.entries, hasLength(1), reason: '回声更不该在历史里堆出第二条');
    });

    test('超窗口重复复制同一文本去重到最新，不堆重复行', () async {
      final DesktopLookupService service = DesktopLookupService.instance;

      service.submitText('見る');
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      service.submitText('読む');
      expect(
        repo.entries.map((ClipboardHistoryEntry e) => e.text),
        <String>['見る', '読む'],
      );

      // 用户隔了几秒再复制一次「見る」：查词要重新排队（BUG-1025），历史侧则由
      // ClipboardHistoryRepository.add 的「同文本去重到最新」把它移到队尾，
      // 而不是留下两条一样的行。
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      service.submitText('見る');

      expect(service.pendingText, '見る', reason: '超窗口的同词是用户显式重查，必须放行');
      expect(
        repo.entries.map((ClipboardHistoryEntry e) => e.text),
        <String>['読む', '見る'],
        reason: '同文本去重到最新：只剩一条「見る」且被移到队尾',
      );
      expect(repo.entries.last.copiedAt, fakeNow);

      await repo.flushNow();
      final List<ClipboardHistoryRow> rows = await db.getAllClipboardHistory();
      expect(
        rows.map((ClipboardHistoryRow r) => r.content),
        <String>['読む', '見る'],
      );
    });

    // 采集链路的另一半：AppModel 必须把 addClipboardHistoryEntry 接到回调上。
    // 上面的行为用例是自己装的捕获器，接不上生产装配也照样绿；这条源码守卫补上
    // 那一环，删掉赋值行即红。
    test('AppModel 仍把 addClipboardHistoryEntry 接到 onClipboardCaptured', () {
      final String model =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(
        // Dart RegExp 的 \s 覆盖换行，故这条能跨行匹配 app_model.dart 里
        // `onClipboardCaptured =` 换行再接 `addClipboardHistoryEntry;` 的写法。
        model.contains(
          RegExp(r'onClipboardCaptured\s*=\s*addClipboardHistoryEntry'),
        ),
        isTrue,
        reason: '生产侧的采集装配丢了，复制历史又会永远为空（BUG-1145）',
      );
    });
  });
}

bool _setsAlwaysOnTop2(String method) => method == 'setAlwaysOnTop';

bool _setsAlwaysOnTop(MethodCall call) {
  final Object? arguments = call.arguments;
  return call.method == 'setAlwaysOnTop' &&
      arguments is Map &&
      arguments['isAlwaysOnTop'] == true;
}
