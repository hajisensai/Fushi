import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_session_edit_dialog.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 会话编辑弹窗（用户 2026-09-10：「里面的每个会话做成可编辑，日期和字符都能编辑」）。
///
/// 守的是三件事：
///  * 初值回填的是**这一条会话**的日历日与总字数（不是今天 / 不是 0）；
///  * 非法输入不许悄悄放过——保存按钮 `onPressed` 置 null 且字段下给出错误文案，
///    尤其 `2026-02-31` 这种 `DateTime.tryParse` 会溢出成 3 月 3 日的输入；
///  * 返回的 [StudySessionEdit] 只带**真改过**的项（没动的是 null，避免一次无谓的
///    整段平移写），两项都没动时 [showStatSessionEditDialog] 返回 null。
DateTime get _start => DateTime(2026, 9, 8, 14, 35);

String _fieldText(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

Finder get _saveButton => find.widgetWithText(FilledButton, t.dialog_save);

bool _saveEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_saveButton).onPressed != null;

/// 直接把弹窗挂在 Scaffold 上（只看渲染 / 校验，不点保存——那要 Navigator）。
Future<void> _pumpDialog(
  WidgetTester tester, {
  int chars = 1200,
}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: StatSessionEditDialog(
            itemTitle: '吾輩は猫である',
            startAt: _start.millisecondsSinceEpoch,
            chars: chars,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 走真入口 [showStatSessionEditDialog]：点开 → 改 → 保存，结果写进 [sink]。
Future<void> _pumpHost(
  WidgetTester tester, {
  required void Function(StudySessionEdit?) sink,
  int chars = 1200,
}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () async => sink(
                await showStatSessionEditDialog(
                  context,
                  itemTitle: '吾輩は猫である',
                  startAt: _start.millisecondsSinceEpoch,
                  chars: chars,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('初值回填：日期 = startAt 的日历日，字数 = 会话总字数', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);
    expect(tester.takeException(), isNull);
    expect(
      _fieldText(tester, 'stat-session-edit-date'),
      FushiDatabase.statCalendarDayKeyOf(_start),
    );
    expect(_fieldText(tester, 'stat-session-edit-chars'), '1200');
    expect(find.text('吾輩は猫である'), findsOneWidget);
    expect(_saveEnabled(tester), isTrue);
    expect(find.text(t.stat_session_edit_date_invalid), findsNothing);
    expect(find.text(t.stat_session_edit_chars_invalid), findsNothing);
  });

  testWidgets('非法日期：保存禁用 + 错误文案', (WidgetTester tester) async {
    await _pumpDialog(tester);
    for (final String bad in <String>[
      '2026-9-8',
      '今天',
      '',
      '2026-09-08T00:00'
    ]) {
      await tester.enterText(
        find.byKey(const ValueKey<String>('stat-session-edit-date')),
        bad,
      );
      await tester.pump();
      expect(
        _saveEnabled(tester),
        isFalse,
        reason: '「$bad」不是 YYYY-MM-DD，保存必须禁用',
      );
      expect(find.text(t.stat_session_edit_date_invalid), findsOneWidget);
    }
  });

  testWidgets('2026-02-31 判非法（tryParse 会把它溢出成 3 月 3 日）', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-session-edit-date')),
      '2026-02-31',
    );
    await tester.pump();
    expect(_saveEnabled(tester), isFalse);
    expect(find.text(t.stat_session_edit_date_invalid), findsOneWidget);
    // 同月的合法日照常通过（错误文案不是恒亮）。
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-session-edit-date')),
      '2026-02-28',
    );
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);
    expect(find.text(t.stat_session_edit_date_invalid), findsNothing);
  });

  testWidgets('负数 / 空 / 非整数字数：保存禁用 + 错误文案', (WidgetTester tester) async {
    await _pumpDialog(tester);
    for (final String bad in <String>['-5', '', '12.5', 'abc']) {
      await tester.enterText(
        find.byKey(const ValueKey<String>('stat-session-edit-chars')),
        bad,
      );
      await tester.pump();
      expect(_saveEnabled(tester), isFalse, reason: '「$bad」不是 ≥0 的整数');
      expect(find.text(t.stat_session_edit_chars_invalid), findsOneWidget);
    }
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-session-edit-chars')),
      '0',
    );
    await tester.pump();
    expect(_saveEnabled(tester), isTrue, reason: '0 是合法字数');
  });

  testWidgets('只改字数：返回的 edit 只带 chars，date 是 null', (
    WidgetTester tester,
  ) async {
    StudySessionEdit? edit;
    await _pumpHost(tester, sink: (StudySessionEdit? e) => edit = e);
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-session-edit-chars')),
      '900',
    );
    await tester.pump();
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();
    expect(edit, isNotNull);
    expect(edit!.chars, 900);
    expect(edit!.date, isNull, reason: '没动的项传 null，避免一次无谓的整段平移写');
  });

  testWidgets('只改日期：返回的 edit 只带 date，chars 是 null', (
    WidgetTester tester,
  ) async {
    StudySessionEdit? edit;
    await _pumpHost(tester, sink: (StudySessionEdit? e) => edit = e);
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-session-edit-date')),
      '2026-09-01',
    );
    await tester.pump();
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();
    expect(edit, isNotNull);
    expect(edit!.date, DateTime(2026, 9, 1));
    expect(edit!.chars, isNull);
  });

  testWidgets('两项都没动 → showStatSessionEditDialog 返回 null', (
    WidgetTester tester,
  ) async {
    int calls = 0;
    StudySessionEdit? edit;
    await _pumpHost(tester, sink: (StudySessionEdit? e) {
      calls++;
      edit = e;
    });
    await tester.tap(_saveButton);
    await tester.pumpAndSettle();
    expect(calls, 1, reason: '确实回来了，不是还卡在弹窗里');
    expect(edit, isNull, reason: '空编辑不该让调用页去写库 + 整页重聚合');
  });

  testWidgets('取消 → 返回 null，改过的输入不生效', (WidgetTester tester) async {
    StudySessionEdit? edit;
    int calls = 0;
    await _pumpHost(tester, sink: (StudySessionEdit? e) {
      calls++;
      edit = e;
    });
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-session-edit-chars')),
      '900',
    );
    await tester.pump();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(edit, isNull);
  });
}
