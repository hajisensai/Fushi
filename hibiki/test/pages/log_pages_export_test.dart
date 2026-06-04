import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/debug_log_page.dart';
import 'package:hibiki/src/pages/implementations/error_log_page.dart';
import 'package:hibiki/src/utils/misc/log_exporter.dart';

// 守住「桌面端日志页有『另存为』按钮、移动端没有（仍有现成分享）」这条
// 不变式。`showSaveLogAction` 读 dart:io 的 host 平台，无法在 widget 测试
// 里 override，因此断言跟随当前 host：桌面 host 应渲染该按钮，移动 host 不应。
// HibikiIconButton 用 Semantics(label) 而非 Tooltip，故按图标定位。
const IconData _kSaveIcon = Icons.save_alt_outlined;
const IconData _kShareIcon = Icons.share_outlined;

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: child),
    );
  }

  testWidgets('DebugLogPage shows save-as action iff on desktop',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const DebugLogPage()));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(_kSaveIcon),
      showSaveLogAction ? findsOneWidget : findsNothing,
    );
    // 现有分享按钮始终在，未被破坏。
    expect(find.byIcon(_kShareIcon), findsOneWidget);
  });

  testWidgets('ErrorLogPage shows save-as action iff on desktop',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const ErrorLogPage()));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(_kSaveIcon),
      showSaveLogAction ? findsOneWidget : findsNothing,
    );
    expect(find.byIcon(_kShareIcon), findsOneWidget);
  });
}
