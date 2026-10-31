import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';

/// 反馈 R8duEiqRuy：删除类动作可以「画出来但不可用」（[DialogDangerAction.disabledReason]），
/// 例如对端离线时的「同时从远端删除」。三种容器（抽屉宫格 / 宽对话框双栏 / 右键菜单）
/// 都必须：照常显示动作名、点了不触发、把原因写在旁边（触屏没有悬停 tooltip）。
void main() {
  const String reason = 'Host is offline';

  Future<List<String>> pumpFrame(
    WidgetTester tester,
    MediaItemActionsLayout layout,
  ) async {
    final List<String> fired = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaItemActionsHost(
              layout: layout,
              child: MediaItemDialogFrame(
                title: 'Remote Book',
                showLaunchAction: false,
                dangerActions: <DialogDangerAction>[
                  DialogDangerAction(
                    label: 'Hide here',
                    muted: true,
                    onPressed: () => fired.add('hide'),
                  ),
                  DialogDangerAction(
                    label: 'Delete on host',
                    disabledReason: reason,
                    onPressed: () => fired.add('delete'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fired;
  }

  for (final MediaItemActionsLayout layout in MediaItemActionsLayout.values) {
    testWidgets('$layout：禁用项显示原因、点了不触发；可用项照常触发', (WidgetTester tester) async {
      final List<String> fired = await pumpFrame(tester, layout);

      expect(find.text('Delete on host'), findsOneWidget);
      expect(find.text(reason), findsOneWidget, reason: '禁用必须写明原因');

      await tester.tap(find.text('Delete on host'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(fired, isEmpty, reason: '禁用项不能触发删除');

      await tester.tap(find.text('Hide here'));
      await tester.pumpAndSettle();
      expect(fired, <String>['hide']);
    });
  }

  test('disabledReason 为 null 即可用', () {
    final DialogDangerAction action = DialogDangerAction(
      label: 'x',
      onPressed: () {},
    );
    expect(action.enabled, isTrue);
    expect(
      DialogDangerAction(
        label: 'x',
        disabledReason: 'r',
        onPressed: () {},
      ).enabled,
      isFalse,
    );
  });
}
