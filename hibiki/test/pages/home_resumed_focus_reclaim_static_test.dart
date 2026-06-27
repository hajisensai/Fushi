import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-900 源码守卫：app 回前台（[AppLifecycleState.resumed]）时首页必须把
/// Flutter 焦点收回键事件入口，修复「Alt+Tab 切窗回来后页级 / 全局快捷键整体失灵、
/// 只能重启复活」。两态分支（对齐 _wrapFocusNavigation）：实验焦点导航开 → 控制器
/// ensureFocus()；关 → requestFocus 既有 _keyboardFocusNode（不新造节点）。路由
/// isCurrent 门控保证压着对话框时不夺焦点。headless 难稳定复现 OS 失焦，用接线守卫
/// 固化不变式防回归（对齐 video_page_keyboard_focus_static_test.dart）。
void main() {
  late String src;
  setUpAll(() {
    final File f = File('lib/src/pages/implementations/home_page.dart');
    expect(f.existsSync(), isTrue, reason: '文件不存在');
    src = f.readAsStringSync();
  });

  test('存在 _reclaimHomeFocusIfOwned 回收 helper', () {
    expect(src, contains('void _reclaimHomeFocusIfOwned()'),
        reason: '应有统一的 resumed 焦点回收 helper');
  });

  test('didChangeAppLifecycleState 的 resumed 分支调回收 helper', () {
    final int lifecycle = src.indexOf('void didChangeAppLifecycleState(');
    expect(lifecycle, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }', lifecycle);
    final String body = src.substring(lifecycle, end);
    expect(body, contains('AppLifecycleState.resumed'),
        reason: 'resumed 分支不能缺失');
    expect(body, contains('_reclaimHomeFocusIfOwned();'),
        reason: 'resumed 时必须调回收 helper');
  });

  test('回收 helper 两态分支 + 路由门控 + 不新造节点', () {
    final int start = src.indexOf('void _reclaimHomeFocusIfOwned()');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    // [M1] 红线：路由 isCurrent 门控。
    expect(body, contains('ModalRoute.of(context)'), reason: 'helper 必须取所有者路由');
    expect(body, contains('isCurrent'),
        reason: 'helper 必须含路由 isCurrent 门控（否则夺对话框焦点）');
    // [M2]：开态走控制器 ensureFocus，关态走既有 _keyboardFocusNode（不新造节点）。
    expect(body, contains('HibikiFocusRoot.maybeControllerOf'),
        reason: '开态须经控制器解析');
    expect(body, contains('.ensureFocus()'), reason: '实验焦点导航开态须 ensureFocus');
    expect(body, contains('_keyboardFocusNode.requestFocus()'),
        reason: '关态须 requestFocus 既有 _keyboardFocusNode（不新造节点）');
  });
}
