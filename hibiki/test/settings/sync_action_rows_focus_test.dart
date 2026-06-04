import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import '../widgets/widget_test_helpers.dart';

// BUG-016 regression. 同步设置里「立即同步 / 导出备份 / 导入备份」的动作落在行内的
// 尾部按钮上，而这些行（AdaptiveSettingsRow）当时没有 onTap —— 于是整行不会注册成
// HibikiFocusTarget（只有带 onTap 的行才注册，见 settings_shared.dart），裸 Material
// 按钮也不是 Hibiki 焦点目标。方向导航只走已注册目标，结果：① 「立即同步」根本到不了；
// ② 焦点在「Compare Data」按下，因为同面板下方没有可达目标，落到了左侧导航面板。
//
// 这个测试用真实的 AdaptiveSettingsRow 重建该布局（左导航面板 + 右详情面板），驱动
// 方向导航逐行下移：detail-top → Compare 行 → Sync 行（controlBelow + 尾部按钮 +
// onTap）。每到一行用 ActivateIntent 验证落点确为该行。修复前第二次 Down 会跳到导航
// 面板，syncActivated 永远为 false。
Widget _syncLikeTwoPane({
  required GlobalKey rootKey,
  required VoidCallback onCompare,
  required VoidCallback onSync,
}) {
  Widget navTarget(String id) => HibikiFocusTarget(
        id: HibikiFocusId(id),
        child: const SizedBox(width: 200, height: 56),
      );
  return buildTestApp(
    HibikiFocusRoot(
      child: Row(
        key: rootKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 左：导航面板（独立 ListView）。
          SizedBox(
            width: 200,
            height: 400,
            child: ListView(
              children: <Widget>[
                navTarget('nav-0'),
                navTarget('nav-1'),
                navTarget('nav-2'),
              ],
            ),
          ),
          // 右：详情面板（独立 ListView）。detail-top 是一个已知起点，下面是两行
          // 真实 AdaptiveSettingsRow：Compare（行内 onTap，类比 Compare Data）与
          // Sync（controlBelow + 尾部按钮 + onTap，类比「立即同步」——本次修复点）。
          SizedBox(
            width: 400,
            height: 400,
            child: ListView(
              children: <Widget>[
                const HibikiFocusTarget(
                  id: HibikiFocusId('detail-top'),
                  child: SizedBox(width: 400, height: 48),
                ),
                AdaptiveSettingsRow(
                  title: 'Compare',
                  icon: Icons.compare_arrows,
                  onTap: onCompare,
                ),
                AdaptiveSettingsRow(
                  title: 'Sync now',
                  icon: Icons.sync,
                  controlBelow: true,
                  onTap: onSync,
                  trailing: FilledButton(
                    onPressed: onSync,
                    child: const Text('Sync now'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets(
      'directional Down walks Compare → Sync row without skipping the '
      'trailing-button action row (BUG-016)', (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    bool compareActivated = false;
    bool syncActivated = false;

    await tester.pumpWidget(_syncLikeTwoPane(
      rootKey: rootKey,
      onCompare: () => compareActivated = true,
      onSync: () => syncActivated = true,
    ));
    await tester.pump();

    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('detail-top')), isTrue);
    await tester.pump();

    // Down 一步：落到 Compare 行，Activate 触发它（证明落点正确）。
    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(compareActivated, isTrue, reason: 'first Down lands on Compare row');

    // Down 再一步：必须落到 Sync 行（同面板、下一行）——这正是修复点。修复前 Sync
    // 行未注册，这一步会跳到左侧导航面板，syncActivated 保持 false。
    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(
      syncActivated,
      isTrue,
      reason: 'the trailing-button Sync row is now a reachable focus stop; '
          'Down must land on it (same pane), not jump to the nav rail',
    );
  });
}
