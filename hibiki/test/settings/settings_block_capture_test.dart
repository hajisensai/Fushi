import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_lookup.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

import '../helpers/test_platform_services.dart';

/// 阶段 E：查词设置页「防截屏」开关。守卫：
/// 1) 查词 destination「剪贴板与全局查词」区确有此开关，且 Windows 门控；
/// 2) 切换写穿 pref（setClipboardPanelBlockCapture）；
/// 3) 切换即时重应用到面板窗（与面板栏 🛡 按钮同一 native 通道，不新起并行机制）。
void main() {
  SettingsItem? findLookupItem(String id) {
    final SettingsDestination dest = buildLookupDestination();
    for (final SettingsSection section in dest.sections) {
      for (final SettingsItem item in section.items) {
        if (item.id == id) return item;
      }
    }
    return null;
  }

  test('lookup destination owns the block-capture switch (Windows-gated)', () {
    final SettingsItem? item = findLookupItem('lookup.block_capture');
    expect(item, isNotNull, reason: '查词设置页必须有防截屏开关');
    expect(item, isA<SettingsSwitchItem>());
    // 仅 Windows 可见——SetWindowDisplayAffinity 是 Win32 能力。
    expect(item!.visible, isNotNull, reason: '防截屏开关必须门控（否则泄漏进非 Windows 平台）');
  });

  testWidgets('switch writes through pref and live-applies to the panel window',
      (WidgetTester tester) async {
    final List<MethodCall> channelCalls = <MethodCall>[];
    // 面板窗 native 通道的 mock：记录 setBlockCapture（即时重应用的落点），
    // 同时避免测试机上真调 native 抛 MissingPluginException。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      HibikiChannels.clipboardPanel,
      (MethodCall call) async {
        channelCalls.add(call);
        return null;
      },
    );
    // 瞬态全局查词窗 native 通道的 mock：applyBlockCapture 是唯一扇出入口，
    // 同一次切换必须同时保护瞬态窗（审查 Finding 1——否则录屏/串流从热键或
    // 面板内点词弹出的瞬态窗泄露面板承诺保护的内容）。
    final List<MethodCall> overlayCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      HibikiChannels.globalLookup,
      (MethodCall call) async {
        overlayCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        HibikiChannels.clipboardPanel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        HibikiChannels.globalLookup,
        null,
      );
    });

    final _RecordingAppModel appModel = _RecordingAppModel();
    late SettingsContext sctx;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sctx = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderHibikiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final SettingsSwitchItem toggle =
        findLookupItem('lookup.block_capture')! as SettingsSwitchItem;

    // Windows 门控与实际平台一致（本机无关的确定性断言）。
    expect(toggle.visible!(sctx), Platform.isWindows);

    // 关 → 写穿 pref。
    await toggle.onChanged(sctx, false);
    expect(appModel.recorded, <bool>[false]);
    expect(toggle.value(sctx), isFalse);

    // 开 → 写穿 pref。
    await toggle.onChanged(sctx, true);
    expect(appModel.recorded, <bool>[false, true]);
    expect(toggle.value(sctx), isTrue);

    // 即时重应用只在 Windows 生效（isSupported）——落到面板窗 native 通道的
    // setBlockCapture（同 🛡 按钮路径）。非 Windows 平台恒隐藏、不接线。
    if (Platform.isWindows) {
      final Iterable<MethodCall> blockCalls =
          channelCalls.where((MethodCall c) => c.method == 'setBlockCapture');
      expect(blockCalls, isNotEmpty,
          reason: '切换必须经 native 通道即时重应用（同面板栏 🛡 按钮）');
      final Map<Object?, Object?> lastArgs =
          (blockCalls.last.arguments as Map<Object?, Object?>);
      expect(lastArgs['block'], isTrue);

      // 审查 Finding 1：同一次切换必须扇出到瞬态全局查词窗通道。
      final Iterable<MethodCall> overlayBlockCalls =
          overlayCalls.where((MethodCall c) => c.method == 'setBlockCapture');
      expect(overlayBlockCalls, isNotEmpty,
          reason: '切换必须同时重应用到瞬态全局查词窗（同一 pref 保护两块表面）');
      final Map<Object?, Object?> overlayArgs =
          (overlayBlockCalls.last.arguments as Map<Object?, Object?>);
      expect(overlayArgs['block'], isTrue);
    }
  });

  test('native global-lookup channel wires setBlockCapture (Finding 1 guard)',
      () {
    // 源码守卫（flutter test 无法编译/运行 C++ runner）：flutter_window.cpp 的
    // 全局查词通道（RegisterGlobalLookupChannel）必须有 setBlockCapture 分支并
    // 应用到 global_lookup_window_，否则「防截屏」只保护面板、瞬态查词窗照样
    // 被录屏/串流采集（与 clipboard_panel_guard_test 的 C++ 源码扫描同款）。
    final String fw =
        File('windows/runner/flutter_window.cpp').readAsStringSync();
    final int globalStart =
        fw.indexOf('void FlutterWindow::RegisterGlobalLookupChannel()');
    final int panelStart =
        fw.indexOf('void FlutterWindow::RegisterClipboardPanelChannel()');
    expect(globalStart, greaterThan(0));
    expect(panelStart, greaterThan(globalStart));
    final String globalChannel = fw.substring(globalStart, panelStart);
    expect(globalChannel.contains('"setBlockCapture"'), isTrue,
        reason: '全局查词通道必须处理 setBlockCapture');
    expect(globalChannel.contains('global_lookup_window_->SetBlockCapture'),
        isTrue,
        reason: 'setBlockCapture 必须应用到瞬态查词窗对象');

    // Dart 侧：控制器 start 时推 pref 初值（native 记值 + 窗口重建自动重加，
    // 覆盖此后每次弹出），并暴露 applyBlockCapture 供扇出入口即时重推。
    final String controllerSrc =
        File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync();
    // dart format 可能折行，拆两段断言（不锁死单行）。
    expect(
        controllerSrc.contains('GlobalLookupChannel.setBlockCapture('), isTrue,
        reason: 'GlobalLookupController 必须经本窗通道推 setBlockCapture');
    expect(
        controllerSrc.contains('appModel.clipboardPanelBlockCapture'), isTrue,
        reason: 'GlobalLookupController.start 必须推「防截屏」pref 初值');
    expect(controllerSrc.contains('Future<void> applyBlockCapture('), isTrue,
        reason: 'GlobalLookupController 必须暴露 applyBlockCapture 供扇出');

    // 唯一扇出入口：ClipboardPanelController.applyBlockCapture 同时推两条通道
    // （面板 + 瞬态窗），设置页开关与面板栏 🛡 按钮都走它。
    final String panelSrc =
        File('lib/src/lookup/clipboard_panel_controller.dart')
            .readAsStringSync();
    final int at = panelSrc.indexOf('Future<void> applyBlockCapture(');
    expect(at, greaterThan(0));
    final int end = panelSrc.indexOf('\n  }', at);
    final String body = panelSrc.substring(at, end);
    expect(
        body.contains(
            'GlobalLookupController.instance.applyBlockCapture(block)'),
        isTrue,
        reason: 'applyBlockCapture 必须扇出到瞬态全局查词窗');
  });

  test(
      'schema onChanged reuses the 🛡 button live-apply path (no parallel wiring)',
      () {
    // 源码守卫：查词 schema 的开关 onChanged 复用 ClipboardPanelController 的
    // 即时重应用（applyBlockCapture），而非另起并行机制。
    final String lookupSrc =
        File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync();
    expect(lookupSrc.contains('setClipboardPanelBlockCapture(value)'), isTrue,
        reason: '开关必须写穿 pref');
    // dart format 可能把链式调用折行，故拆两段断言（不锁死单行）。
    expect(lookupSrc.contains('ClipboardPanelController.instance'), isTrue,
        reason: '开关必须经控制器即时重应用到面板窗');
    expect(lookupSrc.contains('.applyBlockCapture(value)'), isTrue,
        reason: '开关必须调 applyBlockCapture 复用 🛡 按钮路径');

    // 控制器的 applyBlockCapture 复用面板栏 🛡 按钮同一条 native 通道。
    final String controllerSrc =
        File('lib/src/lookup/clipboard_panel_controller.dart')
            .readAsStringSync();
    final int at = controllerSrc.indexOf('Future<void> applyBlockCapture(');
    expect(at, greaterThan(0), reason: '控制器必须暴露 applyBlockCapture 供设置页复用');
    final int end = controllerSrc.indexOf('\n  }', at);
    final String body = controllerSrc.substring(at, end);
    expect(body.contains('_channel.setBlockCapture(block)'), isTrue,
        reason: 'applyBlockCapture 必须调同一 native 通道（同 🛡 按钮）');
  });
}

/// 记录 pref 写穿的 AppModel：绕开 prefsRepo，直接记住最后写入值。
class _RecordingAppModel extends AppModel {
  _RecordingAppModel() : super(testPlatformServices());

  final List<bool> recorded = <bool>[];
  bool _stored = true;

  @override
  bool get clipboardPanelBlockCapture => _stored;

  @override
  Future<void> setClipboardPanelBlockCapture(bool value) async {
    recorded.add(value);
    _stored = value;
  }
}
