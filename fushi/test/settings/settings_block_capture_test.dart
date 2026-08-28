import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

import '../helpers/test_platform_services.dart';

/// 阶段 E：查词设置页「防截屏」开关。守卫：
/// 1) 查词 destination 确有此开关，且 Windows 门控；
/// 2) 切换写穿 pref（setLookupBlockCapture，存储键沿用历史名
///    clipboard_panel_block_capture）；
/// 3) 切换即时重应用到瞬态全局查词窗（GlobalLookupController.applyBlockCapture，
///    不新起并行机制）。
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

  testWidgets('switch writes through pref and live-applies to the overlay', (
    WidgetTester tester,
  ) async {
    // 瞬态全局查词窗 native 通道的 mock：记录 setBlockCapture（即时重应用的落点），
    // 同时避免测试机上真调 native 抛 MissingPluginException。
    final List<MethodCall> overlayCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      FushiChannels.globalLookup,
      (MethodCall call) async {
        overlayCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        FushiChannels.globalLookup,
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
                readerSource: ReaderFushiSource.instance,
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

    // 即时重应用只在 Windows 生效（GlobalLookupController.isSupported）——落到
    // 全局查词窗 native 通道的 setBlockCapture。非 Windows 平台恒隐藏、不接线。
    if (Platform.isWindows) {
      final Iterable<MethodCall> blockCalls = overlayCalls.where(
        (MethodCall c) => c.method == 'setBlockCapture',
      );
      expect(blockCalls, isNotEmpty, reason: '切换必须经 native 通道即时重应用到瞬态全局查词窗');
      final Map<Object?, Object?> lastArgs =
          (blockCalls.last.arguments as Map<Object?, Object?>);
      expect(lastArgs['block'], isTrue);
    }
  });

  test(
    'native global-lookup channel wires setBlockCapture (Finding 1 guard)',
    () {
      // 源码守卫（flutter test 无法编译/运行 C++ runner）：flutter_window.cpp 的
      // 全局查词通道（RegisterGlobalLookupChannel）必须有 setBlockCapture 分支并
      // 应用到通道当前路由到的窗口，否则「防截屏」开关是空的。
      final String fw = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();
      final int globalStart = fw.indexOf(
        'void FlutterWindow::RegisterGlobalLookupChannel()',
      );
      final int nextStart = fw.indexOf(
        'void FlutterWindow::RegisterForegroundSelectionChannel()',
      );
      expect(globalStart, greaterThan(0));
      expect(nextStart, greaterThan(globalStart));
      final String globalChannel = fw.substring(globalStart, nextStart);
      expect(
        globalChannel.contains('"setBlockCapture"'),
        isTrue,
        reason: '全局查词通道必须处理 setBlockCapture',
      );
      // 通道现在按 `target` 路由到桌面浮窗或游戏内离屏卡片窗，处理器统一用局部
      // `win`——这条防截屏因此同时覆盖两个表面，不是只覆盖成员那一个。
      expect(
        globalChannel.contains('win->SetBlockCapture'),
        isTrue,
        reason: 'setBlockCapture 必须应用到通道当前路由到的瞬态查词窗对象',
      );

      // Dart 侧：控制器 start 时推 pref 初值（native 记值 + 窗口重建自动重加，
      // 覆盖此后每次弹出），并暴露 applyBlockCapture 供设置页即时重推。
      final String controllerSrc = File(
        'lib/src/lookup/global_lookup_controller.dart',
      ).readAsStringSync();
      expect(
        controllerSrc.contains('GlobalLookupChannel.setBlockCapture('),
        isTrue,
        reason: 'GlobalLookupController 必须经本窗通道推 setBlockCapture',
      );
      expect(
        controllerSrc.contains('appModel.lookupBlockCapture'),
        isTrue,
        reason: 'GlobalLookupController.start 必须推「防截屏」pref 初值',
      );
      expect(
        controllerSrc.contains('Future<void> applyBlockCapture('),
        isTrue,
        reason: 'GlobalLookupController 必须暴露 applyBlockCapture 供设置页',
      );
    },
  );

  test('schema onChanged reuses GlobalLookupController.applyBlockCapture', () {
    // 源码守卫：查词 schema 的开关 onChanged 写穿 pref 后复用控制器的即时重应用，
    // 而非另起并行机制。
    final String lookupSrc = File(
      'lib/src/settings/settings_schema_lookup.dart',
    ).readAsStringSync();
    expect(
      lookupSrc.contains('setLookupBlockCapture(value)'),
      isTrue,
      reason: '开关必须写穿 pref',
    );
    expect(
      lookupSrc.contains(
        'GlobalLookupController.instance.applyBlockCapture(value)',
      ),
      isTrue,
      reason: '开关必须调 GlobalLookupController.applyBlockCapture 即时重应用',
    );
  });

  test('storage key stays frozen at clipboard_panel_block_capture', () {
    // 面板已删，但用户已存的开关值不能丢：存储键冻结不追改。
    final String prefsSrc = File(
      'lib/src/models/preferences_repository.dart',
    ).readAsStringSync();
    final int at = prefsSrc.indexOf('bool get lookupBlockCapture');
    expect(at, greaterThan(0));
    expect(
      prefsSrc
          .substring(at, at + 400)
          .contains("'clipboard_panel_block_capture'"),
      isTrue,
      reason: 'lookupBlockCapture 必须继续读写历史存储键',
    );
  });
}

/// 记录 pref 写穿的 AppModel：绕开 prefsRepo，直接记住最后写入值。
class _RecordingAppModel extends AppModel {
  _RecordingAppModel() : super(testPlatformServices());

  final List<bool> recorded = <bool>[];
  bool _stored = true;

  @override
  bool get lookupBlockCapture => _stored;

  @override
  Future<void> setLookupBlockCapture(bool value) async {
    recorded.add(value);
    _stored = value;
  }
}
