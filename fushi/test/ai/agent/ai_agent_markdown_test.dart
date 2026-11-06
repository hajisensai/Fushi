import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:material_ui/material_ui.dart';

/// AI 助手的回复按 Markdown 渲染：`**粗体**` 不再原样露出星号，列表 / 引用照常排。
void main() {
  // selectable 时 flutter_markdown 用的是旧 SDK 的 SelectableText（未迁
  // material_ui），按类型名找、读它的 textSpan。
  final Finder selectables = find.byWidgetPredicate(
    (Widget w) => w.runtimeType.toString() == 'SelectableText',
  );
  List<TextSpan> spansOf(WidgetTester tester) => <TextSpan>[
    for (final Widget w in tester.widgetList(selectables))
      if ((w as dynamic).textSpan case final TextSpan span) span,
  ];
  String renderedText(WidgetTester tester) =>
      spansOf(tester).map((TextSpan s) => s.toPlainText()).join('\n');

  testWidgets('粗体、列表、引用按 Markdown 排，不露出标记', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiAgentMarkdown(
            text:
                '**中文大意**：米利根话音刚落。\n\n'
                '> ミリガンが告げると同時に\n\n'
                '- **告げると同時に**：刚一……就……\n'
                '- 目を瞠る',
            color: Colors.black,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
    final String text = renderedText(tester);
    expect(text, contains('中文大意'));
    expect(text, contains('ミリガンが告げると同時に'));
    expect(text, contains('目を瞠る'));
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('> ')));

    final List<TextSpan> bold = <TextSpan>[];
    for (final TextSpan root in spansOf(tester)) {
      root.visitChildren((InlineSpan span) {
        if (span is TextSpan &&
            span.text == '中文大意' &&
            span.style?.fontWeight == FontWeight.w700) {
          bold.add(span);
        }
        return true;
      });
    }
    expect(bold, isNotEmpty, reason: '「中文大意」要渲染成粗体');
  });

  testWidgets('选中文本不崩（flutter_markdown selectable 的空回调约定）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        // 与生产根同构：选中后的工具栏是旧 SDK 的，靠根上的桥拿到本地化。
        builder: (BuildContext context, Widget? child) =>
            LegacyDesignCompatibility(child: child!),
        home: const Scaffold(
          body: AiAgentMarkdown(text: '一段可以选中的回复', color: Colors.black),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(selectables, findsWidgets);
    await tester.longPress(selectables.first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
