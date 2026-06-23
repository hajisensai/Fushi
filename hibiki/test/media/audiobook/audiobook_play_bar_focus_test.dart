import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';

/// TODO-712 守卫：阅读器有声书播放控制条的所有可点按钮必须注册为应用焦点目标
/// （[HibikiFocusTarget]），否则在 `experimentalFocusNavigation` 下方向键 / 手柄
/// 方向只在已注册的 [HibikiFocusTarget] 之间移动，永远跳不到播放条这几个按钮
/// （用户报「这三个按钮好像没焦点」）。
///
/// 同时验证 A / Enter 能真正按动按钮：[HibikiFocusTarget] 持有焦点节点，
/// [ActivateIntent] 须从该焦点节点**向上**走 Actions 链命中按钮回调，所以每个
/// 按钮在 [HibikiFocusTarget] 之上挂了 `Actions{ActivateIntent → onPressed}`。
void main() {
  testWidgets('play bar buttons are all registered HibikiFocusTargets',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () {},
          ),
        ),
      ),
    );

    // 每个 IconButton 必须有一个 HibikiFocusTarget 祖先。
    final Iterable<IconButton> buttons =
        tester.widgetList<IconButton>(find.byType(IconButton));
    expect(buttons.length, 5, reason: '播放条应有 5 个图标按钮：上一句/播放/下一句/follow/设置');
    for (final Element el in find.byType(IconButton).evaluate()) {
      final Finder target = find.ancestor(
        of: find.byWidget(el.widget),
        matching: find.byType(HibikiFocusTarget),
      );
      expect(target, findsOneWidget,
          reason: '每个播放条按钮都必须被 HibikiFocusTarget 包裹（TODO-712）');
    }

    // 五个稳定的焦点 id 都在场。
    final Set<String> ids = tester
        .widgetList<HibikiFocusTarget>(find.byType(HibikiFocusTarget))
        .map((HibikiFocusTarget w) => w.id.value)
        .toSet();
    expect(
      ids,
      containsAll(<String>[
        'audiobook_prev',
        'audiobook_play',
        'audiobook_next',
        'audiobook_follow',
        'audiobook_settings',
      ]),
    );
  });

  testWidgets('ActivateIntent above the focus target presses the button',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    int settingsTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () => settingsTaps++,
          ),
        ),
      ),
    );

    // 定位「设置」按钮对应的焦点目标。手柄 A / 键盘 Enter 走
    // `Actions.maybeInvoke<ActivateIntent>(primaryFocus.context, ...)`，即从
    // 焦点目标自身的 context **向上**走 Actions 链——所以这里直接在焦点目标的
    // element context 上发 ActivateIntent，复刻真实派发路径。
    final Finder settingsTarget = find.byWidgetPredicate(
      (Widget w) =>
          w is HibikiFocusTarget && w.id.value == 'audiobook_settings',
    );
    expect(settingsTarget, findsOneWidget);

    // 起点取 HibikiFocusTarget 自身的 element（真实焦点落在它内部的 Focus
    // 节点上）。ActivateIntent 从这里向上走 Actions 链，会命中我们在
    // HibikiFocusTarget **之上**显式挂的 `Actions{ActivateIntent → onPressed}`
    // ——而不会经过 IconButton 内部（在子树下方）。CallbackAction.onInvoke 返回
    // null 属正常（intent 已被处理），故断言改看副作用是否发生，而非返回值。
    final BuildContext targetContext = tester.element(settingsTarget);
    Actions.maybeInvoke<ActivateIntent>(
      targetContext,
      const ActivateIntent(),
    );
    await tester.pump();

    expect(settingsTaps, 1,
        reason: 'A / Enter（ActivateIntent）应触发设置按钮的 onPressed（TODO-712）');
  });
}
