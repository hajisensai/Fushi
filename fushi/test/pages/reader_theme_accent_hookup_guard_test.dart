import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 自定义主题「未接入颜色」补齐的源码守卫（2026-09 审计）：
/// - 词典弹窗配色不再拿阅读器纸色当 seed 重造 ColorScheme（那样弹窗里的按钮 /
///   查到词高亮 / 描边全由纸色派生，与用户主题色脱钩），改为 app 真实 ColorScheme
///   + `deriveSurfaceRolesFrom(纸色)` 推出的中性角色；
/// - 歌词模式高亮与 caret 焦点环在深色纸底下不再硬编码高亮黄，两档都取当前明暗的
///   主题 primary。
void main() {
  final String chrome = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  ).readAsStringSync();
  final String lyrics = File(
    'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
  ).readAsStringSync();
  final String caret = File(
    'lib/src/pages/implementations/reader_fushi/caret.part.dart',
  ).readAsStringSync();

  test('词典弹窗：app ColorScheme 为基底 + 纸色中性梯度，不再 fromSeed(纸色)', () {
    final int start = chrome.indexOf('void _syncDictionaryTheme()');
    expect(start, greaterThanOrEqualTo(0));
    final String body = chrome.substring(
      start,
      chrome.indexOf('\n  }\n', start),
    );
    expect(body.contains('ColorScheme.fromSeed('), isFalse);
    expect(
      RegExp(r'appModel\s*\.buildColorScheme\(brightness\)').hasMatch(body),
      isTrue,
    );
    expect(body.contains('deriveSurfaceRolesFrom(bg)'), isTrue);
    expect(body.contains('onSurface: textColor'), isTrue);
  });

  test('歌词高亮 / caret 焦点环：两档都跟主题 primary，无硬编码高亮黄', () {
    expect(lyrics.contains('FushiColor.defaultHighlightYellow'), isFalse);
    expect(caret.contains('FushiColor.defaultHighlightYellow'), isFalse);
    expect(
      lyrics.contains(
        '_isReaderThemeDark ? Brightness.dark : Brightness.light',
      ),
      isTrue,
    );
    expect(
      caret.contains('_isReaderThemeDark ? Brightness.dark : Brightness.light'),
      isTrue,
    );
  });
}
