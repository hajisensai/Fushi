import 'dart:io';

import 'package:fushi/src/prefs/fushi_pref_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/platform/desktop/desktop_tray.dart';

/// 托盘菜单拼装、通道去重与原生侧「只拦用户关闭手势」的契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String label(DesktopTrayEntry entry) => 'L:${entry.name}';

  List<String> shape(List<DesktopTrayMenuItem> items) => <String>[
    for (final DesktopTrayMenuItem item in items)
      item.separator ? '-' : item.entry!.name,
  ];

  group('buildDesktopTrayMenu', () {
    test('全开时按分组排好、组间一条分隔线', () {
      final List<DesktopTrayMenuItem> items = buildDesktopTrayMenu(
        isModuleEnabled: (_) => true,
        labelOf: label,
        screenOcrAvailable: true,
        clipboardLookupAvailable: true,
      );
      expect(shape(items), <String>[
        'show',
        '-',
        'lookup',
        'clipboardLookup',
        'screenOcr',
        '-',
        'books',
        'manga',
        'video',
        'music',
        'srs',
        '-',
        'settings',
        '-',
        'exit',
      ]);
      expect(items.first.label, 'L:show');
    });

    test('关掉的模块不出现，整组空了不留多余分隔线', () {
      const Set<ModuleId> off = <ModuleId>{
        ModuleId.lookup,
        ModuleId.books,
        ModuleId.manga,
        ModuleId.video,
        ModuleId.music,
        ModuleId.srs,
      };
      final List<DesktopTrayMenuItem> items = buildDesktopTrayMenu(
        isModuleEnabled: (ModuleId module) => !off.contains(module),
        labelOf: label,
        screenOcrAvailable: false,
        clipboardLookupAvailable: false,
      );
      expect(shape(items), <String>['show', '-', 'settings', '-', 'exit']);
    });

    test('只有默认项带 isDefault，导航项要求原生先露出窗口', () {
      final List<DesktopTrayMenuItem> items = buildDesktopTrayMenu(
        isModuleEnabled: (_) => true,
        labelOf: label,
        screenOcrAvailable: true,
        clipboardLookupAvailable: true,
      );
      final Map<String, Map<String, Object>> wire =
          <String, Map<String, Object>>{
            for (final DesktopTrayMenuItem item in items)
              if (!item.separator) item.entry!.id: item.toWire(),
          };
      expect(
        wire.values.where((Map<String, Object> m) => m['isDefault'] == true),
        hasLength(1),
      );
      expect(wire['show']!['isDefault'], isTrue);
      expect(wire['books']!['revealWindow'], isTrue);
      expect(wire['settings']!['revealWindow'], isTrue);
      // 不打扰正在用的别的应用：剪贴板查词 / 截屏识字 / 退出都不把主窗口拽出来。
      expect(wire['clipboardLookup']!['revealWindow'], isFalse);
      expect(wire['screenOcr']!['revealWindow'], isFalse);
      expect(wire['exit']!['revealWindow'], isFalse);
    });
  });

  test('「已收进托盘」提示标记是设备本地键，不随 Profile 切换重弹', () {
    expect(isKnownPreferenceKey('desktop_tray_hint_shown'), isTrue);
    expect(ProfileKeys.isExcludedPref('desktop_tray_hint_shown'), isTrue);
  });

  group('DesktopTray 通道', () {
    const MethodChannel channel = MethodChannel('app.fushi/tray.test');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return true;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    List<DesktopTrayMenuItem> menu() => buildDesktopTrayMenu(
      isModuleEnabled: (_) => true,
      labelOf: label,
      screenOcrAvailable: true,
      clipboardLookupAvailable: true,
    );

    test('同内容只推一次；开关变化立即重推', () async {
      final DesktopTray tray = DesktopTray(
        platformSupported: true,
        channel: channel,
      );
      tray.setCloseToTray(true);
      await pumpEventQueue();
      expect(calls, isEmpty, reason: '菜单还没拼出来时不挂图标');

      tray.sync(items: menu(), tooltip: 'Fushi', closeToTray: false);
      tray.sync(items: menu(), tooltip: 'Fushi', closeToTray: false);
      await pumpEventQueue();
      expect(calls, hasLength(1));
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(calls.single.method, 'configure');
      expect(args['visible'], isTrue);
      expect(args['closeToTray'], isFalse);
      expect((args['items']! as List<Object?>).length, menu().length);

      tray.setCloseToTray(true);
      await pumpEventQueue();
      expect(calls, hasLength(2));
      expect(
        (calls.last.arguments as Map<Object?, Object?>)['closeToTray'],
        isTrue,
      );
    });

    test('不支持的平台不碰通道', () async {
      final DesktopTray tray = DesktopTray(
        platformSupported: false,
        channel: channel,
      );
      tray.sync(items: menu(), tooltip: 'Fushi', closeToTray: true);
      await tray.showNotification(title: 't', body: 'b');
      await tray.notifyExiting();
      await pumpEventQueue();
      expect(calls, isEmpty);
    });

    test('退出链通知原生侧摘托盘标记', () async {
      final DesktopTray tray = DesktopTray(
        platformSupported: true,
        channel: channel,
      );
      await tray.notifyExiting();
      expect(calls.single.method, 'exiting');
    });

    test('原生回调分发到对应处理器，未知 id 忽略', () async {
      final DesktopTray tray = DesktopTray(
        platformSupported: true,
        channel: channel,
      );
      final List<DesktopTrayEntry> entries = <DesktopTrayEntry>[];
      int hidden = 0;
      int activated = 0;
      tray.attach(
        onEntry: entries.add,
        onHiddenToTray: () => hidden++,
        onActivate: () => activated++,
      );
      await tray.handleNativeCallForTest(
        const MethodCall('onMenuItem', 'manga'),
      );
      await tray.handleNativeCallForTest(
        const MethodCall('onMenuItem', 'no_such_entry'),
      );
      await tray.handleNativeCallForTest(const MethodCall('onHiddenToTray'));
      await tray.handleNativeCallForTest(const MethodCall('onActivate'));
      expect(entries, <DesktopTrayEntry>[DesktopTrayEntry.manga]);
      expect(hidden, 1);
      expect(activated, 1);
      tray.detach();
    });
  });

  group('原生侧关闭契约（源码守卫）', () {
    String read(String rel) =>
        File(rel).readAsStringSync().replaceAll('\r\n', '\n');

    test('只拦 SC_CLOSE，且排在 window_manager 之前；裸 WM_CLOSE 照旧退出', () {
      final String src = read('windows/runner/flutter_window.cpp');
      final int handler = src.indexOf('FlutterWindow::MessageHandler(');
      expect(handler, greaterThan(0));
      final String body = src.substring(handler);
      final int intercept = body.indexOf(
        '(wparam & 0xFFF0) == SC_CLOSE &&\n      close_to_tray_ && HideToTray()',
      );
      final int plugins = body.indexOf('HandleTopLevelWindowProc(');
      expect(intercept, greaterThan(0), reason: '关闭到托盘必须只认 SC_CLOSE');
      expect(
        intercept,
        lessThan(plugins),
        reason: 'window_manager 会把 SC_CLOSE 变成 WM_CLOSE 走退出链，拦截必须在它之前',
      );
      // 安装器 / taskkill 用裸 WM_CLOSE 让 app 落盘退出（process_control.iss），
      // 绝不能被收进托盘。
      expect(
        RegExp(r'message == WM_CLOSE[^\n]*HideToTray').hasMatch(body),
        isFalse,
      );
    });

    test('第二实例启动能把收进托盘的主窗口找回来', () {
      final String main = read('windows/runner/main.cpp');
      expect(
        main,
        contains('::GetPropW(existing, ::fushi::kTrayHiddenWindowProp)'),
      );
      final String fw = read('windows/runner/flutter_window.cpp');
      expect(fw, contains('SetPropW(hwnd, ::fushi::kTrayHiddenWindowProp'));
      expect(fw, contains('RemovePropW(hwnd, ::fushi::kTrayHiddenWindowProp)'));
    });

    test('藏在托盘的首实例按「运行中」转交，不当退出中白等互斥量', () {
      final String main = read('windows/runner/main.cpp');
      final int classify = main.indexOf('ClassifyExistingInstance(');
      expect(classify, greaterThan(0));
      final int end = main.indexOf(');', classify);
      expect(
        main.substring(classify, end),
        contains('::fushi::kTrayHiddenWindowProp'),
        reason: '收进托盘的主窗显示过又不可见，不带托盘标记就会被判成退出中',
      );
      final String policy = read('windows/runner/startup_reveal_policy.h');
      expect(
        policy,
        contains('if (hidden_to_tray) return ExistingInstanceState::kInTray;'),
      );
    });

    test('退出链先摘托盘标记再隐藏主窗', () {
      final String dartMain = read('lib/main.dart');
      final int notify = dartMain.indexOf(
        'DesktopTray.instance.notifyExiting()',
      );
      final int hide = dartMain.indexOf("_guardedExitStep('window hide'");
      expect(notify, greaterThan(0));
      expect(notify, lessThan(hide), reason: '隐藏后再摘，二次启动会转交给正在退出的进程');
      final String fw = read('windows/runner/flutter_window.cpp');
      final int exiting = fw.indexOf('call.method_name() == "exiting"');
      expect(exiting, greaterThan(0));
      expect(
        fw.substring(exiting, exiting + 600),
        contains('RemovePropW(hwnd, ::fushi::kTrayHiddenWindowProp)'),
      );
    });

    test('主窗属性在 WM_DESTROY 时用消息参数 hwnd 摘除', () {
      // Win32Window 处理 WM_DESTROY 时先清 window_handle_ 再调 OnDestroy，
      // OnDestroy 里 GetHandle() 已是 nullptr，在那里摘属性永远走不到。
      final String fw = read('windows/runner/flutter_window.cpp');
      final int handler = fw.indexOf('FlutterWindow::MessageHandler(');
      expect(handler, greaterThan(0));
      final int destroy = fw.indexOf('if (message == WM_DESTROY) {', handler);
      expect(destroy, greaterThan(handler));
      final String block = fw.substring(destroy, fw.indexOf('}', destroy));
      expect(
        block,
        contains('RemovePropW(hwnd, ::fushi::kMainWindowShownProp);'),
      );
      expect(
        block,
        contains('RemovePropW(hwnd, ::fushi::kTrayHiddenWindowProp);'),
      );
      final int onDestroy = fw.indexOf('void FlutterWindow::OnDestroy()');
      expect(onDestroy, greaterThan(0));
      final String onDestroyBody = fw.substring(
        onDestroy,
        fw.indexOf('Win32Window::OnDestroy();', onDestroy),
      );
      expect(onDestroyBody, isNot(contains('RemovePropW')));
    });
  });
}
