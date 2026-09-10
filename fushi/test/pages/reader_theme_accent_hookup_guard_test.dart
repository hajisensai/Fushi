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
  // BUG-2434：弹窗覆盖主题的决策已抽成纯函数，断言面跟着搬到这里。
  final String popupTheme = File(
    'lib/src/pages/implementations/dictionary_popup_theme.dart',
  ).readAsStringSync();

  test('词典弹窗：app ColorScheme 为基底 + 纸色中性梯度，不再 fromSeed(纸色)', () {
    // 决策住在纯函数 resolveDictionaryPopupTheme 里（BUG-2434 从
    // chrome.part.dart 抽出），断言面因此在 dictionary_popup_theme.dart。
    expect(popupTheme.contains('ColorScheme.fromSeed('), isFalse,
        reason: '纸色重造 ColorScheme 会让按钮/高亮/描边与用户主题色脱钩');
    expect(
      RegExp(r'buildColorScheme\(brightness\)').hasMatch(popupTheme),
      isTrue,
      reason: 'app 真实 ColorScheme 必须是基底',
    );
    expect(popupTheme.contains('deriveSurfaceRolesFrom(bg)'), isTrue,
        reason: '纸色只贡献中性角色梯度');
  });

  test('词典弹窗：chrome.part 仍然只是把当前取值喂给那个纯函数', () {
    // 上一条搬去了纯函数，这条守住「决策没有偷偷搬回 chrome.part」——
    // 两条一起才等价于原先那一条的覆盖面。
    final int start = chrome.indexOf('void _syncDictionaryTheme()');
    expect(start, greaterThanOrEqualTo(0));
    final String body = chrome.substring(
      start,
      chrome.indexOf('\n  }\n', start),
    );
    expect(body.contains('resolveDictionaryPopupTheme('), isTrue,
        reason: '决策必须仍然经由纯函数，否则上一条守卫就看不见它了');
    expect(body.contains('ColorScheme.fromSeed('), isFalse);
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
