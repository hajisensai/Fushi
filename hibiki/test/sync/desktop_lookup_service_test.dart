import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => DesktopLookupService.instance.debugReset());
  tearDown(() {
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
}

bool _setsAlwaysOnTop(MethodCall call) {
  final Object? arguments = call.arguments;
  return call.method == 'setAlwaysOnTop' &&
      arguments is Map &&
      arguments['isAlwaysOnTop'] == true;
}
