import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 紧贴在 [declaration] 之上的连续 `///` 注释块（没有则为空串）。
String _docAbove(String source, String declaration) {
  final List<String> lines = source.split('\n');
  final int at = lines.indexWhere(
    (String l) => l.trimLeft().startsWith(declaration),
  );
  expect(at, greaterThan(0), reason: '找不到声明：$declaration');
  final List<String> doc = <String>[];
  for (int i = at - 1; i >= 0; i--) {
    final String l = lines[i].trimLeft();
    if (!l.startsWith('///')) break;
    doc.insert(0, l);
  }
  return doc.join('\n');
}

/// PR #2086 审查：新加的 `_outlinedText` 曾插在 `_clampDistance` 的 doc 注释与函数
/// 之间，注释被 dartdoc / IDE 悬停挂到了 `_outlinedText` 上，`_clampDistance` 反而
/// 没了说明。钉住两条注释各归其主。
void main() {
  final String source = File(
    'lib/src/media/video/subtitle_style_preview.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('_clampDistance 的 doc 注释紧贴它自己', () {
    final String doc = _docAbove(source, 'static double _clampDistance(');
    expect(doc, contains('kVideoSubtitleMaxPadding'));
  });

  test('_outlinedText 的 doc 注释只讲它自己，不夹带 _clampDistance 的说明', () {
    final String doc = _docAbove(source, 'static Widget _outlinedText(');
    expect(doc, contains('描边'));
    expect(doc, isNot(contains('kVideoSubtitleMaxPadding')));
  });
}
