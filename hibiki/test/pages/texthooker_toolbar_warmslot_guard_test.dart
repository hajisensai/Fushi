// gal-hook-ux-overhaul 源码接线守卫：
//  ① BUG-1028 查词预热——texthooker_page 必须 seedWarmSlot 且顶层查词 reuseWarmSlot（防回归到
//     每次点词冷建 WebView 的高延迟）。
//  ② 工具栏只保留一套按钮构建方法——嵌入/独立两模式都引用 _buildToolbarActions，旧的
//     _buildEmbeddedActions（与独立模式不一致的特殊情况）必须删除。
//  ③ 制卡成功回写——协调器成功点必须调 markLineMined，把行标记为已制卡。
//
// 这些守卫读源码字符串，不 import 页面（页面此时引用了尚待补的 i18n key），故独立可编译运行。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String pageSrc =
      File('lib/src/pages/implementations/texthooker_page.dart')
          .readAsStringSync();
  final String coordinatorSrc =
      File('lib/src/mining/gal_hook_mining_coordinator.dart')
          .readAsStringSync();

  group('BUG-1028 查词预热（防回归冷建 WebView）', () {
    test('initState seed 常驻热槽', () {
      expect(pageSrc.contains('seedWarmSlot'), isTrue,
          reason: '开页必须 seed 隐藏热槽，使弹窗 WebView 冷加载一次后全程复用');
      expect(pageSrc.contains('_popup.lowMemory = _appModel.lowMemoryMode'),
          isTrue,
          reason: 'seed 前须按 lowMemory 决定是否保留热槽（对齐 home_dictionary_page）');
    });

    test('顶层查词复用热槽而非 replaceStack 冷建', () {
      expect(pageSrc.contains('reuseWarmSlot: true'), isTrue,
          reason: '_onWordTap 必须 reuseWarmSlot:true 复用预热 WebView');
      // 逐词查词点击本身不得再走 replaceStack 冷建弹窗（BUG-1028 根因）。
      expect(pageSrc.contains('replaceStack: true'), isFalse,
          reason: 'texthooker 顶层查词不应再用 replaceStack 冷建');
    });
  });

  group('工具栏统一（消除两套按钮定义）', () {
    test('存在唯一共用构建方法 _buildToolbarActions', () {
      expect(
        RegExp(r'List<Widget> _buildToolbarActions\(').hasMatch(pageSrc),
        isTrue,
        reason: '必须有共用的工具栏动作构建方法',
      );
    });

    test('旧的 _buildEmbeddedActions 已删除', () {
      expect(pageSrc.contains('_buildEmbeddedActions'), isFalse,
          reason: '嵌入专用按钮定义必须收口进 _buildToolbarActions');
    });

    test('嵌入与独立两模式都复用同一构建方法', () {
      expect(pageSrc.contains('_buildToolbarActions(context, embedded: false)'),
          isTrue,
          reason: '独立模式 AppBar actions 走共用方法');
      expect(pageSrc.contains('_buildToolbarActions(context, embedded: true)'),
          isTrue,
          reason: '嵌入模式页头 actions 走共用方法');
    });

    test('低频开关收进「更多」PopupMenuButton', () {
      expect(pageSrc.contains('PopupMenuButton<_GalHookToolbarMenuAction>'),
          isTrue,
          reason: '低频开关必须收进更多菜单');
      expect(
          pageSrc.contains('CheckedPopupMenuItem<_GalHookToolbarMenuAction>'),
          isTrue,
          reason: '真开关（音频降级 / 外部窗口挖矿）用 CheckedPopupMenuItem 显示开关态');
    });

    test('嵌入模式删除冗余「兼容性诊断」按钮', () {
      expect(pageSrc.contains('game_open_diagnostics'), isFalse,
          reason: '顶部 GameSectionTabs 已有诊断入口，工具栏诊断按钮纯冗余，须删');
    });
  });

  group('制卡成功回写行模型（已制卡徽章数据源）', () {
    test('协调器成功点调 markLineMined', () {
      expect(coordinatorSrc.contains('markLineMined'), isTrue,
          reason: '制卡成功后必须把对应行标记为已制卡');
      expect(coordinatorSrc.contains('MineResult.success'), isTrue,
          reason: '仅在成功结果时回写 mined');
    });
  });
}
