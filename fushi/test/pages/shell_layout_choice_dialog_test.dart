// G1 新旧 UI 选择：升级上来、从没选过库页布局的老用户首页弹一次「选一种库页
// 布局」。框里两张预览卡复用设置页的 ShellLayoutChoiceCards，默认高亮拼贴；
// 「用这个」交回所选布局，「稍后再说」交回 null（ThemeNotifier 侧的落库与不再弹
// 由 test/settings/shell_style_settings_effect_test.dart 咬住）。交互一律焦点驱动。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/shell_layout_choice_dialog.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:material_ui/material_ui.dart';

import '../../integration_test/helpers/focus_driver.dart';

void main() {
  Widget host({
    required ValueChanged<ShellContentLayout> onConfirm,
    required VoidCallback onLater,
  }) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: ShellLayoutChoiceDialog(
            arrangement: ShellBlockArrangement.aligned,
            onConfirm: onConfirm,
            onLater: onLater,
          ),
        ),
      ),
    ),
  );

  bool selectedOf(WidgetTester tester, String key) {
    final Semantics semantics = tester.widget<Semantics>(
      find
          .descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(Semantics),
          )
          .first,
    );
    return semantics.properties.selected ?? false;
  }

  testWidgets('默认高亮拼贴；焦点选封面网格后「用这个」交回网格', (WidgetTester tester) async {
    ShellContentLayout? confirmed;
    bool later = false;
    await tester.pumpWidget(
      host(
        onConfirm: (ShellContentLayout layout) => confirmed = layout,
        onLater: () => later = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.byKey(const ValueKey<String>('shell_layout_choice')),
      findsOneWidget,
    );
    expect(selectedOf(tester, 'shell-layout-collage'), isTrue);
    expect(selectedOf(tester, 'shell-layout-grid'), isFalse);
    expect(find.text(t.library_layout_collage_new_label), findsOneWidget);
    expect(find.text(t.library_layout_grid_classic_label), findsOneWidget);

    final FocusDriver driver = FocusDriver(tester);
    expect(
      await driver.focusWidget(
        find.byKey(const ValueKey<String>('shell-layout-grid')),
      ),
      isTrue,
    );
    await driver.activate();
    expect(selectedOf(tester, 'shell-layout-grid'), isTrue);
    expect(selectedOf(tester, 'shell-layout-collage'), isFalse);

    expect(
      await driver.focusWidget(
        find.byKey(const ValueKey<String>('shell_layout_choice_confirm')),
      ),
      isTrue,
    );
    await driver.activate();
    expect(confirmed, ShellContentLayout.grid);
    expect(later, isFalse);
  });

  testWidgets('「稍后再说」不交回布局', (WidgetTester tester) async {
    ShellContentLayout? confirmed;
    bool later = false;
    await tester.pumpWidget(
      host(
        onConfirm: (ShellContentLayout layout) => confirmed = layout,
        onLater: () => later = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    final FocusDriver driver = FocusDriver(tester);
    expect(
      await driver.focusWidget(
        find.byKey(const ValueKey<String>('shell_layout_choice_later')),
      ),
      isTrue,
    );
    await driver.activate();
    expect(later, isTrue);
    expect(confirmed, isNull);
  });

  test('只在待处理且重设计外壳生效时弹（墨水屏留到离开后再问）', () {
    expect(
      shouldShowShellLayoutChoice(pending: true, redesignActive: true),
      isTrue,
    );
    expect(
      shouldShowShellLayoutChoice(pending: true, redesignActive: false),
      isFalse,
    );
    expect(
      shouldShowShellLayoutChoice(pending: false, redesignActive: true),
      isFalse,
    );
  });

  test('首页首帧只有这一个库页布局提示（BUG-5060）', () {
    // 此前首帧在这个选择框之后还串着 pr3454 的「库页现在默认封面网格」一次性提示：
    // 在框里点「稍后再说」不写布局，那条提示紧接着又弹，且对「哪个是新默认」的
    // 说法与本框相反。G1 已覆盖「升级用户被告知拼贴可选」，那条提示整体删除。
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(
      RegExp(r'await maybeShowShellLayoutChoice\(').allMatches(source).length,
      1,
    );
    expect(source, isNot(contains('LibraryLayoutDefaultNotice')));
    expect(
      File(
        'lib/src/pages/implementations/library_layout_default_notice.dart',
      ).existsSync(),
      isFalse,
    );
  });
}
