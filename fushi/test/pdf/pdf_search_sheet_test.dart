import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pdf/pdf_search_sheet.dart';
import 'package:fushi/src/pdf/pdf_text_search.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

/// PDF 搜索面板 / 命中导航胶囊（拍板台 KN4kdP4JB8）：提交查询列出按页结果、点结果
/// 回调下标；扫描版明确提示无文本层；导航胶囊显示「当前 / 总数」并回调上一个 / 下一个 /
/// 关闭。
NormalizedTextWithOffsets _identityNormalize(String s) {
  final StringBuffer text = StringBuffer();
  final List<int> starts = <int>[];
  final List<int> ends = <int>[];
  for (int i = 0; i < s.length; i++) {
    if (s[i] == '\n' || s[i] == ' ') continue;
    text.write(s[i]);
    starts.add(i);
    ends.add(i + 1);
  }
  return NormalizedTextWithOffsets(text.toString(), starts, ends);
}

PdfTextSearchController _controller(List<String> pages) {
  final PdfTextSearchController c = PdfTextSearchController(
    loadPage: (int page) async =>
        (fullText: pages[page], rectsFor: (int s, int e) => const <PdfRect>[]),
    normalize: _identityNormalize,
  );
  addTearDown(c.dispose);
  return c;
}

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: child),
);

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('提交查询：按页列结果，点结果回调下标', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final PdfTextSearchController c = _controller(<String>[
      'The cat sat.',
      'No match here.',
      'Another cat.',
    ]);
    final List<int> selected = <int>[];
    await tester.pumpWidget(
      _host(
        PdfSearchSheet(controller: c, pageCount: 3, onSelect: selected.add),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('pdf_search_field')).last,
      'cat',
    );
    await tester.tap(find.byKey(const ValueKey<String>('pdf_search_submit')));
    await tester.pumpAndSettle();

    expect(c.hits, hasLength(2));
    expect(find.text(t.pdf_search_page(page: 1)), findsOneWidget);
    expect(find.text(t.pdf_search_page(page: 3)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('pdf_search_result_1')));
    await tester.pump();
    expect(selected, <int>[1]);
  });

  testWidgets('扫描版（整本无文本层）明确提示搜不了', (WidgetTester tester) async {
    final PdfTextSearchController c = _controller(<String>['', '']);
    await tester.pumpWidget(
      _host(PdfSearchSheet(controller: c, pageCount: 2, onSelect: (_) {})),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('pdf_search_field')).last,
      'cat',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(c.status, PdfTextSearchStatus.noTextLayer);
    expect(
      find.byKey(const ValueKey<String>('pdf_search_no_text_layer')),
      findsOneWidget,
    );
    expect(find.text(t.pdf_search_no_text_layer), findsOneWidget);
  });

  testWidgets('有文本层但没命中：显示「没找到」而不是无文本层', (WidgetTester tester) async {
    final PdfTextSearchController c = _controller(<String>['dog']);
    await tester.pumpWidget(
      _host(PdfSearchSheet(controller: c, pageCount: 1, onSelect: (_) {})),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('pdf_search_field')).last,
      'cat',
    );
    await tester.tap(find.byKey(const ValueKey<String>('pdf_search_submit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('pdf_search_no_results')),
      findsOneWidget,
    );
  });

  testWidgets('命中导航胶囊：无结果时不露出；有结果显示位置并回调各按钮', (WidgetTester tester) async {
    final PdfTextSearchController c = _controller(<String>['cat cat cat']);
    final List<String> calls = <String>[];
    await tester.pumpWidget(
      _host(
        Align(
          alignment: Alignment.bottomCenter,
          child: PdfSearchNavigator(
            controller: c,
            visible: true,
            onPrevious: () => calls.add('prev'),
            onNext: () => calls.add('next'),
            onShowResults: () => calls.add('results'),
            onClose: () => calls.add('close'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('pdf_search_next')), findsNothing);

    await c.search('cat', pageCount: 1);
    c.select(1);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('pdf_search_next')));
    await tester.tap(find.byKey(const ValueKey<String>('pdf_search_previous')));
    await tester.tap(find.byKey(const ValueKey<String>('pdf_search_position')));
    await tester.tap(find.byKey(const ValueKey<String>('pdf_search_close')));
    await tester.pump();
    expect(calls, <String>['next', 'prev', 'results', 'close']);
  });
}
