// spec 2026-07-10 — OverlayWindowChannel 抽取的契约测试：
// ① 两条 channel（global_lookup / clipboard_panel）互不串线；
// ② GlobalLookupChannel 静态门面仍走 global_lookup channel 名（1700 行
//    controller 零改动的前提）；
// ③ resolveBridge 双重 jsonEncode 契约保持（adapter 侧 JSON.parse(arg)）。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/global_lookup_channel.dart';
import 'package:hibiki/src/lookup/overlay_window_channel.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> globalCalls = <String>[];
  final List<String> panelCalls = <String>[];
  MethodCall? lastPanelCall;

  setUp(() {
    globalCalls.clear();
    panelCalls.clear();
    lastPanelCall = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.globalLookup,
            (MethodCall call) async {
      globalCalls.add(call.method);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.clipboardPanel,
            (MethodCall call) async {
      panelCalls.add(call.method);
      lastPanelCall = call;
      if (call.method == 'applyBackdrop') return true;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.globalLookup, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.clipboardPanel, null);
  });

  test('GlobalLookupChannel 静态门面仍走 global_lookup channel', () async {
    await GlobalLookupChannel.hide(notify: false);
    await GlobalLookupChannel.render('{}');
    expect(globalCalls, <String>['hide', 'render']);
    expect(panelCalls, isEmpty);
  });

  test('面板实例走 clipboard_panel channel，与 global_lookup 互不串线', () async {
    const OverlayWindowChannel panel =
        OverlayWindowChannel(HibikiChannels.clipboardPanel);
    await panel.hide();
    await panel.setPinned(true);
    expect(await panel.applyBackdrop(), isTrue);
    expect(panelCalls, <String>['hide', 'setPinned', 'applyBackdrop']);
    expect(globalCalls, isEmpty);
  });

  test('resolveBridge 保持双重 jsonEncode 契约（adapter JSON.parse(arg)）', () async {
    const OverlayWindowChannel panel =
        OverlayWindowChannel(HibikiChannels.clipboardPanel);
    await panel.resolveBridge(7, <String, Object?>{'ok': true});
    final Map<Object?, Object?> args =
        lastPanelCall!.arguments as Map<Object?, Object?>;
    // 外层 jsonEncode 产出 JS 字符串字面量：值本身是 '"{\"ok\":true}"'。
    expect(args['id'], 7);
    expect(args['value'], '"{\\"ok\\":true}"');
  });

  test('showAt 解析 native map 回复（work area + 窗口原点偏移）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.clipboardPanel,
            (MethodCall call) async {
      return <String, Object?>{
        'ok': true,
        'workW': 2560,
        'workH': 1400,
        'cursorWorkX': 120,
        'cursorWorkY': 80,
        // BUG-859 — 光标显示器 dpr（native 用 FlutterDesktopGetDpiForMonitor
        // 上报）；Dart 必须用它（而非主窗口 dpr）把上面的物理 px 换算成 CSS px。
        'monitorDpr': 1.25,
      };
    });
    const OverlayWindowChannel panel =
        OverlayWindowChannel(HibikiChannels.clipboardPanel);
    final GlobalLookupShowResult r =
        await panel.showAt(x: 100, y: 60, width: 380, height: 520);
    expect(r.ok, isTrue);
    expect(r.workWidth, 2560);
    expect(r.workHeight, 1400);
    expect(r.cursorWorkX, 120);
    expect(r.cursorWorkY, 80);
    expect(r.monitorDpr, 1.25);
  });

  test('showAt 旧 native 回复（无 monitorDpr 键）回退 0', () async {
    // BUG-859 — 旧 native / 查询失败：monitorDpr 缺省 0，controller 据此回退主窗口
    // dpr（行为与修复前逐字节一致，Never break userspace）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HibikiChannels.clipboardPanel,
            (MethodCall call) async {
      return <String, Object?>{'ok': true, 'workW': 1920, 'workH': 1040};
    });
    const OverlayWindowChannel panel =
        OverlayWindowChannel(HibikiChannels.clipboardPanel);
    final GlobalLookupShowResult r =
        await panel.showAt(x: 0, y: 0, width: 380, height: 520);
    expect(r.monitorDpr, 0);
  });
}
