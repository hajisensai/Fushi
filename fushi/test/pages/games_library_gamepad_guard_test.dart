import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 手柄重设计 P4：游戏库卡片手柄接线的源码守卫（页面依赖太重，widget 测试不现实；
/// GalgamePosterCard 侧的长按 A 行为由 galgame_poster_card_test 真实驱动）。
void main() {
  const String path = 'lib/src/pages/implementations/games_library_page.dart';

  test('游戏卡包了 Y=详情 的 GamepadButtonIntent Action', () {
    final String code = maskComments(File(path).readAsStringSync());
    expect(code.contains('_GameCardDetailGamepadAction('), isTrue,
        reason: '卡片没挂 Y=详情 action：手柄用户只能启动、进不了详情页');
    // isEnabled 只认 Y 的门控必须在：CallbackAction 返回 false 会把 home scope
    // 的 LT/RT 换 tab 等外层解析静默吞掉（Actions 停在第一个 enabled 的 action）。
    final int classIdx = code.indexOf('class _GameCardDetailGamepadAction');
    expect(classIdx, greaterThanOrEqualTo(0));
    final String slice = code.substring(classIdx);
    expect(slice.contains('bool isEnabled(GamepadButtonIntent intent)'), isTrue,
        reason: '必须用 isEnabled 门控放行非 Y 按钮');
    expect(slice.contains('intent.button == GamepadButton.y'), isTrue,
        reason: 'Y 是详情键的唯一判据');
  });
}
