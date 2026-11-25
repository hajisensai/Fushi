import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// PDF 阅读页的全文搜索接线（拍板台 KN4kdP4JB8）。PdfViewer 依赖 pdfium 原生库，
/// widget 测试起不来真实文档（搜索逻辑与面板另有单测），这里钉接线形状：
/// ① 顶栏有搜索按钮、打开搜索面板；② 命中高亮登记在 pdfrx 的页绘制回调里；
/// ③ 选结果 / 上一个 / 下一个都经同一个 `_revealSearchHit` 跳页露出；
/// ④ 命中导航胶囊在底部栏里，搜索会话随页面销毁。
void main() {
  final String code = maskComments(
    File(
      'lib/src/pages/implementations/reader_pdf_page.dart',
    ).readAsStringSync(),
  );

  test('顶栏搜索按钮打开搜索面板', () {
    expect(
      RegExp(
        r"key: const ValueKey<String>\('pdf_search'\),\s*icon: FushiIcons\.search,\s*label: t\.pdf_search,\s*onPressed: \(\) => unawaited\(_openSearch\(\)\),",
      ).hasMatch(code),
      isTrue,
    );
    expect(code.contains('PdfSearchSheet('), isTrue);
  });

  test('命中高亮画在 pdfrx 页绘制回调里', () {
    expect(
      RegExp(
        r'<PdfViewerPagePaintCallback>\[[^\]]*_paintSearchHighlight[^\]]*\]',
      ).hasMatch(code),
      isTrue,
    );
  });

  test('选结果 / 上一个 / 下一个都跳页露出命中', () {
    expect(code.contains('_revealSearchHit(_search.select(index))'), isTrue);
    expect(code.contains('_revealSearchHit(_search.previous())'), isTrue);
    expect(code.contains('_revealSearchHit(_search.next())'), isTrue);
  });

  test('命中导航胶囊在底部栏，搜索会话随页销毁', () {
    expect(code.contains('PdfSearchNavigator('), isTrue);
    expect(
      RegExp(
        r'_search\s*\.\.removeListener\(_onSearchChanged\)\s*\.\.dispose\(\);',
      ).hasMatch(code),
      isTrue,
    );
  });
}
