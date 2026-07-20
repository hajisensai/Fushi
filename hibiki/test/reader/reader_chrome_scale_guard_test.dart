import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// 守卫：底栏高度必须经 appUiScale 缩放、且两条底栏都过 ReaderChromeScaler。
/// 防止未来有人把底栏高度写回硬编码常量或漏掉缩放器，导致界面大小不再吃到底栏、
/// 或视觉高度与 WebView 预留高度错位。
void main() {
  final File reader =
      File('lib/src/pages/implementations/reader_hibiki_page.dart');

  test('reader source file exists', () {
    expect(reader.existsSync(), isTrue, reason: '从 hibiki/ 目录跑 flutter test');
  });

  test('_readerChromeHeight is a scaled getter, not a const 56', () {
    final String src = readReaderPageSource();
    // 容忍 dart format 的换行/空白：用允许任意空白的正则匹配，而非脆弱的整串匹配。
    expect(
        RegExp(r'static\s+const\s+double\s+_readerChromeHeight\s*=\s*56')
            .hasMatch(src),
        isFalse,
        reason: '底栏高度必须随 appUiScale 缩放，不能写死 56');
    expect(
        RegExp(r'_readerChromeHeight\s*=>\s*ReaderChromeScaler\.scaledHeight\(\s*_readerChromeBaseHeight')
            .hasMatch(src),
        isTrue,
        reason:
            '_readerChromeHeight getter 必须走 ReaderChromeScaler.scaledHeight');
  });

  test('both bottom bars wrap content in ReaderChromeScaler', () {
    final String src = readReaderPageSource();
    final int count = 'ReaderChromeScaler('.allMatches(src).length;
    expect(count, greaterThanOrEqualTo(2),
        reason: '设置条 + 有声书播放条都必须套 ReaderChromeScaler');
  });

  // ─── merged verbatim from reader_popup_header_scale_guard_test.dart ───
  // 查词弹窗 header 工具栏 buildPopupAudioControls 必须套 ReaderChromeScaler，
  // 使按钮随 app UI scale 缩放（BUG-039/BUG-054 UI-scale-neutralizer 家族）。
  test('dictionary popup header toolbar uses the reader chrome scale', () {
    final String src = reader.readAsStringSync();
    final String toolbar = _functionSource(
      src,
      '  Widget? buildPopupAudioControls()',
    );

    expect(
      src,
      contains('static const double _readerPopupHeaderBaseHeight'),
      reason: 'lookup popup header buttons need a scaled base height',
    );
    expect(
      toolbar,
      contains('ReaderChromeScaler('),
      reason: 'lookup popup header buttons must scale under the neutralizer',
    );
    expect(
      toolbar,
      contains('scale: _readerChromeScale'),
      reason: 'lookup popup header buttons should use the reader chrome scale',
    );
    expect(
      toolbar,
      contains('baseHeight: _readerPopupHeaderBaseHeight'),
      reason: 'lookup popup header height must follow app UI scale',
    );
  });
}

String _functionSource(String source, String start) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int bodyStart = source.indexOf('{', startIndex + start.length);
  expect(bodyStart, isNonNegative, reason: 'Missing function body: $start');

  int depth = 0;
  for (int index = bodyStart; index < source.length; index++) {
    final String char = source[index];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(startIndex, index + 1);
      }
    }
  }

  fail('Missing function end: $start');
}
