import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-700 T1 source-scan guard: 全局「返回」必须经快捷键注册表 (globalBack) 解析，
/// 不得再有任何把手柄 B 硬编码成 maybePop / HibikiPopIntent 的旁路。删硬绑后 B 才能
/// 随 globalBack 改键（约束3/5），且阅读器内 B=上一句不被全局返回夺舍（约束2/4）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync();
  }

  test('global_navigation.dart 不再把 gameButtonB 硬绑成 HibikiPopIntent', () {
    final String src = read('lib/src/shortcuts/global_navigation.dart');
    expect(
      src.contains('LogicalKeyboardKey.gameButtonB):'),
      isFalse,
      reason: '手柄 B 仍被硬绑成全局 Pop Intent —— 应改为经 registry globalBack 解析',
    );
  });

  test('gamepad_service.dart 不再用裸 case b: maybePop，B 经 registry global 解析', () {
    final String src = read('lib/src/shortcuts/gamepad_service.dart');
    // 旧硬绑：case GamepadButton.b: navigatorKey.currentState?.maybePop();
    expect(
      RegExp(r'case GamepadButton\.b:\s*\n\s*navigatorKey\.currentState\?\.maybePop\(\);')
          .hasMatch(src),
      isFalse,
      reason:
          '裸 case b maybePop 仍在 —— B 应经 registry.resolveGamepad(globalBack)',
    );
    expect(
      src.contains('dispatchNativeGamepadButtonIntent'),
      isTrue,
    );
    // B 不再被 dispatchNativeGamepadButtonIntent 特殊 ignore。
    expect(
      src.contains('button == GamepadButton.b'),
      isFalse,
      reason: 'dispatchNativeGamepadButtonIntent 仍特殊 ignore B —— 应让 B 同其它键进注册表',
    );
    // B 的全局返回回退经注册表 globalBack。
    expect(
      src.contains('ShortcutAction.globalBack'),
      isTrue,
      reason: 'B 的全局返回回退应解析 ShortcutAction.globalBack',
    );
  });
}
