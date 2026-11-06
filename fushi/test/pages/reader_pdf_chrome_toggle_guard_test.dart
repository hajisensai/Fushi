import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// PDF 阅读页的顶栏 / 翻页胶囊必须能收起：此前两条栏无条件常驻，手机上永远
/// 盖着正文。PdfViewer 依赖 pdfium 原生库，widget 测试起不来真实文档，故钉代码形状：
/// ① 顶栏包在 `FushiChromeReveal(visible: _chromeShown)` 里；② 翻页胶囊的显示条件
/// 含 `_chromeVisible`；③ 点背景 / 正文未命中字会走 `_toggleChrome`；④ 文档未就绪时
/// chrome 恒显示（iOS 上返回键是唯一出口）。
void main() {
  final String code = maskComments(
    File(
      'lib/src/pages/implementations/reader_pdf_page.dart',
    ).readAsStringSync(),
  );

  test('顶栏随 _chromeShown 显隐', () {
    expect(
      RegExp(
        r'FushiChromeReveal\(\s*visible: _chromeShown,\s*child: FushiFloatingTopBar\(',
      ).hasMatch(code),
      isTrue,
    );
  });

  test('翻页胶囊显示条件含 _chromeVisible', () {
    expect(code.contains('ready && pageCount > 1 && _chromeVisible'), isTrue);
  });

  test('点背景与正文未命中字都切换 chrome', () {
    expect(
      RegExp(
        r'PdfViewerPart\.background\)\s*\{\s*_toggleChrome\(\);',
      ).hasMatch(code),
      isTrue,
    );
    expect(
      RegExp(
        r'if \(lookedUp \|\| !mounted\) return;\s*_toggleChrome\(\);',
      ).hasMatch(code),
      isTrue,
    );
  });

  test('文档未就绪时 chrome 恒显示（返回键不能被收走）', () {
    expect(
      code.contains(
        'bool get _chromeShown => _chromeVisible || !_pdfController.isReady;',
      ),
      isTrue,
    );
  });
}
