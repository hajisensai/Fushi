import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-308：批量打标签的三段意图原来用 keep=`horizontal_rule`、remove=`remove`
/// 两个几乎一样的横杠（语义相反却长得一样）+ 纯图标（tooltip 桌面悬停才出，手机/
/// 手柄看不到）。修复后三段各有可见文字标签 + 语义区分的图标 + 颜色，一眼可辨。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  BookTagRow tag() => const BookTagRow(
        id: 1,
        name: 'Anime',
        colorValue: 0xFF2196F3,
        sortOrder: 0,
        createdAt: 0,
      );

  Widget host(Widget child) => TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            // 宽一点的窗口，确认三段图标 + 文字在常规布局下不溢出。
            body: SizedBox(width: 600, child: child),
          ),
        ),
      );

  testWidgets('三段都有可见文字标签（Keep / Add / Remove）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(buildBatchTagIntentRowForTesting(tag: tag())));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 修复前三段纯图标无可见文字；现在三段文字都该渲染出来。
    expect(find.text(t.batch_tag_keep), findsOneWidget);
    expect(find.text(t.batch_tag_add), findsOneWidget);
    expect(find.text(t.batch_tag_remove), findsOneWidget);
  });

  testWidgets('三段图标语义区分（不再是两个一样的横杠）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(buildBatchTagIntentRowForTesting(tag: tag())));
    await tester.pumpAndSettle();

    final Iterable<IconData> icons = tester
        .widgetList<Icon>(find.byType(Icon))
        .map((Icon i) => i.icon)
        .whereType<IconData>()
        .toSet();

    // 三段意图图标都该出现，且三者互不相同。
    expect(icons.contains(Icons.remove_circle_outline), isTrue,
        reason: 'keep 段应是中性「圈内横杠」');
    expect(icons.contains(Icons.add_circle), isTrue,
        reason: 'add 段应是主色「实心加号圈」');
    expect(icons.contains(Icons.do_not_disturb_on), isTrue,
        reason: 'remove 段应是错误红「禁止圈」');
    // 修复前 keep 用 horizontal_rule_outlined、remove 用 remove（都是横杠）。
    expect(icons.contains(Icons.horizontal_rule_outlined), isFalse,
        reason: 'keep 不再用与 remove 几乎一样的横杠');
  });

  testWidgets('选中 remove 时图标与文字一起染成错误红（整段染红，非只图标）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(buildBatchTagIntentRowForTesting(tag: tag(), selectedIndex: 2)),
    );
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.text(t.batch_tag_remove));
    final Color errorColor = Theme.of(context).colorScheme.error;

    final Icon removeIcon = tester.widget<Icon>(
      find.byIcon(Icons.do_not_disturb_on),
    );
    expect(removeIcon.color, errorColor, reason: '选中 remove 图标应为错误红');

    final Text removeLabel = tester.widget<Text>(find.text(t.batch_tag_remove));
    expect(removeLabel.style?.color, errorColor, reason: '红色应扩到整段（含文字标签），不只图标');
  });

  test('源码守卫：三段不再用同款横杠且 remove 文字也染错误红', () {
    final String src = readReaderHistorySource();

    final int rowStart = src.indexOf('class _BatchTagIntentRow');
    expect(rowStart, isNonNegative);
    final int rowEnd = src.indexOf('buildBatchTagIntentRowForTesting');
    expect(rowEnd, greaterThan(rowStart));
    final String row = src.substring(rowStart, rowEnd);

    // 三段各有可见文字标签（label）。
    expect('label: segmentLabel('.allMatches(row).length, 3,
        reason: '三段都应配可见文字标签');
    // 文字标签会随选中切换颜色（不只图标）。
    expect(row, contains('color: selected == intent ? color : null'),
        reason: 'segmentLabel 选中时染对应语义色（remove=错误红）');
    // keep/remove 不再用同款横杠。
    expect(row, isNot(contains('Icons.horizontal_rule_outlined')));
    expect(row, contains('Icons.remove_circle_outline'));
    expect(row, contains('Icons.add_circle'));
    expect(row, contains('Icons.do_not_disturb_on'));
  });
}
