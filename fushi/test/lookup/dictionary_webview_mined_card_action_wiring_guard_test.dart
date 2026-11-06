import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反馈 -xJWu33WgJ / pcBy9h7D3_：查词页结果区点 ✓（这个词以前就制过卡）静默无反应。
///
/// app 内的弹窗 WebView 一律注入 `window.__fushiMinedCardActionNative = true`
/// （`popup_settings_injection.dart`，取 `!globalLookup`），popup.js 据此把 ✓ 的点击
/// 交给宿主 `minedCardAction` 桥、不再画页内面板。宿主没接 `onMinedCardAction` 时桥回
/// 空的 `MinePopupResult`——操作单不弹、卡不覆写，以前制的那张没有句子的卡永远改不了。
///
/// 不变量：只要某个 `DictionaryPopupWebView(...)` 能制卡（接了 `onMineEntry`），就必须
/// 同时接 `onMinedCardAction`、`onOpenInAnki`、`onFavoriteEntry` / `onFavoriteCheck`
/// （☆ / ↗ 两颗按钮 app 内恒画，宿主不接同样是静默无反应）。
void main() {
  /// [source] 里每个 `DictionaryPopupWebView(` 调用的实参全文（括号配平）。
  List<String> constructorArgs(String source) {
    final List<String> out = <String>[];
    const String needle = 'DictionaryPopupWebView(';
    int from = 0;
    while (true) {
      final int at = source.indexOf(needle, from);
      if (at < 0) break;
      int depth = 0;
      int i = at + needle.length - 1;
      for (; i < source.length; i++) {
        final String c = source[i];
        if (c == '(') depth++;
        if (c == ')') {
          depth--;
          if (depth == 0) break;
        }
      }
      out.add(source.substring(at, i + 1));
      from = i + 1;
    }
    return out;
  }

  test('能制卡的 app 内弹窗 WebView 都接了 ✓ / ☆ / ↗ 的宿主回调', () {
    final List<String> violations = <String>[];
    int mining = 0;
    for (final FileSystemEntity f in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String source = f.readAsStringSync();
      for (final String args in constructorArgs(source)) {
        // 类自身的构造函数声明（`const DictionaryPopupWebView({`）不是调用点。
        if (args.startsWith('DictionaryPopupWebView({')) continue;
        if (!args.contains('onMineEntry:')) continue;
        mining++;
        for (final String cb in const <String>[
          'onMinedCardAction:',
          'onOpenInAnki:',
          'onFavoriteEntry:',
          'onFavoriteCheck:',
        ]) {
          if (!args.contains(cb)) violations.add('${f.path}: 缺 $cb');
        }
      }
    }
    expect(mining, greaterThan(0), reason: '守卫没扫到任何制卡表面，扫描规则失效');
    expect(violations, isEmpty);
  });

  test('查词页结果区：✓ 操作单与覆写 / 新制同一份源文本例句', () {
    final String source = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('onMinedCardAction(_withSourceSentence(fields))'),
      reason: '从 ✓ 操作单覆写 / 新增重复卡也要带上源文本那一句',
    );
    expect(source, contains('advancedMiningOpenerFor('));
  });
}
