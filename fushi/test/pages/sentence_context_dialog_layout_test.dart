import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/sentence_context_dialog.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiDialogHeroIcon;
import 'package:material_ui/material_ui.dart';

/// BUG-3087 续：「选择句子上下文」对话框在 360dp 窄屏上的版式。
///
/// - 顶部不再放 hero 图标（引号字形被用户读成「99」，还把标题拉成居中）。
/// - ±上下文四颗按钮的文案必须完整可见：以前前文 / 后文各占半宽，英文
///   「Remove previous」折成两行后第二行被 32 高的 XS 胶囊裁掉。
void main() {
  Future<void> open(WidgetTester tester, AppLocale locale) async {
    LocaleSettings.setLocale(locale);
    addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => SentenceContextDialog(
                    matched: '同級生',
                    fetchPreview: () async => <String, Object?>{
                      'prev': <String>['前文。'],
                      'current': '同級生に対して。',
                      'currentOffset': 0,
                      'next': <String>['後文。'],
                      'prevRemoved': <bool>[false],
                      'total': 2,
                    },
                    setContext: (int p, int n) async => p + n,
                    onConfirm: () async => true,
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

  for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
    testWidgets('360dp 宽：±上下文按钮文案完整显示、无顶部 hero 图标（$locale）', (
      WidgetTester tester,
    ) async {
      await open(tester, locale);
      expect(find.byType(FushiDialogHeroIcon), findsNothing);
      for (final String label in <String>[
        t.popup_ctx_prev_minus,
        t.popup_ctx_prev_plus,
        t.popup_ctx_next_minus,
        t.popup_ctx_next_plus,
      ]) {
        final Finder text = find.text(label);
        expect(text, findsOneWidget, reason: label);
        final Finder button = find.ancestor(
          of: text,
          matching: find.byWidgetPredicate(
            (Widget w) => w is ButtonStyleButton,
          ),
        );
        final Rect textRect = tester.getRect(text);
        final Rect buttonRect = tester.getRect(button.first);
        expect(
          buttonRect.top <= textRect.top &&
              textRect.bottom <= buttonRect.bottom,
          isTrue,
          reason: '「$label」的文字不得超出按钮（被裁掉）：$textRect vs $buttonRect',
        );
        expect(
          tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
          isFalse,
          reason: label,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
