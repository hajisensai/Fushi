import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/gamepad_forwarding_action.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

import '../helpers/source_guard.dart';

/// 手柄重设计 P4：游戏库卡片手柄接线（页面依赖太重，widget 测试不现实；
/// GalgamePosterCard 侧的长按 A 行为由 galgame_poster_card_test 真实驱动）。
void main() {
  const String path = 'lib/src/pages/implementations/games_library_page.dart';

  test('游戏卡挂了 X=详情 且非 X 按钮显式转发给祖先', () {
    final String code = maskComments(File(path).readAsStringSync());
    expect(code.contains('GamepadButtonForwardingAction('), isTrue,
        reason: '卡片没挂详情 action：手柄用户只能启动、进不了详情页');
    // 必须显式转发，不能靠覆写 isEnabled：Actions.maybeInvoke 的上溯停止条件是
    // 「本层注册了这个 Intent 类型没有」，与 enabled 无关，靠 isEnabled 让位的按钮
    // 既不被本层执行也到不了祖先，等于静默吞掉（下面那条 widget 测试实证）。
    expect(code.contains('ancestorContext: context'), isTrue,
        reason: '必须传本层 Actions 之上的 context，否则转发原地自我循环');
    expect(code.contains('bool isEnabled(GamepadButtonIntent intent)'), isFalse,
        reason: 'isEnabled 门控做不到让位，不得改回去');
    // 必须是 X 而不是 Y：游戏库是 home tab，与 home scope 同 co-active 组，Y 在那里
    // 绑着注册表动作 homeFocusSearch，卡片抢 Y = 把一个设置页里看得见、可改键的动作
    // 吞掉，而游戏库里焦点几乎总在某张卡上 ⇒ 该 tab 里 Y=搜索永久失效。
    expect(code.contains('button != GamepadButton.x'), isTrue,
        reason: 'X 是详情键的唯一判据');
    expect(code.contains('GamepadButton.y'), isFalse,
        reason: '不得改回 Y —— 会遮蔽 home scope 的 homeFocusSearch');
  });

  // isEnabled 门控的老写法到底会不会让位，只能用真 widget 树验。这条同时钉住
  // GamepadButtonForwardingAction 的两个方向：本层键被消费、其余键真的到达祖先。
  testWidgets('非详情键经转发到达祖先 Actions，X 被本层消费', (WidgetTester tester) async {
    final List<GamepadButton> outer = <GamepadButton>[];
    bool detailOpened = false;
    late BuildContext leaf;

    await tester.pumpWidget(MaterialApp(
      home: Actions(
        actions: <Type, Action<Intent>>{
          GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
            onInvoke: (GamepadButtonIntent intent) {
              outer.add(intent.button);
              return true;
            },
          ),
        },
        child: Builder(builder: (BuildContext cardHost) {
          return Actions(
            actions: <Type, Action<Intent>>{
              GamepadButtonIntent: GamepadButtonForwardingAction(
                ancestorContext: cardHost,
                handle: (GamepadButton button) {
                  if (button != GamepadButton.x) return false;
                  detailOpened = true;
                  return true;
                },
              ),
            },
            child: Builder(builder: (BuildContext context) {
              leaf = context;
              return const SizedBox.shrink();
            }),
          );
        }),
      ),
    ));

    Actions.maybeInvoke<GamepadButtonIntent>(
        leaf, const GamepadButtonIntent(GamepadButton.lt));
    Actions.maybeInvoke<GamepadButtonIntent>(
        leaf, const GamepadButtonIntent(GamepadButton.y));
    expect(outer, <GamepadButton>[GamepadButton.lt, GamepadButton.y],
        reason: 'LT 换 tab / Y 搜索必须穿过卡片层到达祖先，否则等于被静默吞掉');
    expect(detailOpened, isFalse);

    Actions.maybeInvoke<GamepadButtonIntent>(
        leaf, const GamepadButtonIntent(GamepadButton.x));
    expect(detailOpened, isTrue);
    expect(outer.length, 2, reason: 'X 被卡片消费，不应再冒泡');
  });
}
