// BUG-3267：同一次查词的源文本条与结果卡命中高亮必须同色。
//
// M3E（Material、非玻璃、非墨水屏）下源文本条走 primaryContainer（tonalHighlight），
// 结果 WebView 挂 html.fushi-m3e；popup.css 必须在该层把命中高亮同样换成
// primaryContainer，两个宿主（app 外查词窗、首页词典 tab）都必须按同一判据传
// tonalHighlight。任一侧漂移，同一个窗口里就又是两种颜色。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// 压掉空白，便于跨换行匹配。
String _squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

void main() {
  test('popup.css 在 M3E 层把两种命中高亮都换成 primaryContainer', () {
    final String css = _squash(_read('assets/popup/popup.css'));
    for (final String selector in <String>[
      'html.fushi-m3e ::highlight(fushi-selection) {',
      'html.fushi-m3e .fushi-dict-highlight {',
    ]) {
      final int at = css.indexOf(selector);
      expect(at, isNonNegative, reason: '缺少 $selector');
      final String body = css.substring(at, css.indexOf('}', at));
      expect(body, contains('background-color: var(--md-primary-container'));
      expect(body, contains('color: var(--md-on-primary-container'));
    }
  });

  test('两个源文本条宿主都按 M3E 判据传 tonalHighlight', () {
    const String predicate = '!isGlassDesign(context) && !isEinkTheme(context)';
    final String home = _squash(
      _read('lib/src/pages/implementations/home_dictionary_page.dart'),
    );
    expect(home, contains('tonalHighlight: $predicate'));
    final String popup = _squash(
      _read('lib/src/pages/implementations/popup_dictionary_page.dart'),
    );
    expect(popup, contains('final bool m3e = $predicate;'));
    expect(popup, contains('tonalHighlight: m3e'));
  });
}
