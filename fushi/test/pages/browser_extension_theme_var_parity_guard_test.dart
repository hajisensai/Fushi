import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-736 防回归守卫：浏览器扩展查词弹窗的主题变量必须与 app 内弹窗注入的**同一套** CSS
/// 变量对齐。
///
/// 根因：扩展弹窗不吃 Flutter 直接注入，而是靠查词响应 `theme` 字段
/// （[AppModel.browserExtensionThemeColors]）下发，content.js 只把该 map 里**有的** key
/// `setProperty` 到 `#entries-container`。app 内两个注入器（popup_settings_injection /
/// dictionary_popup_webview）设了 `--fushi-primary-highlight` / `--md-on-primary` /
/// `--fushi-radius-card` / `--fushi-card-bg-rgb`，但服务器 map 漏发 → 扩展退化成灰高亮 /
/// 白字 / 直角 / 纯白底，肉眼「和 app 不一样」。
///
/// 本守卫钉死：popup_settings_injection.dart 每一个 `setProperty('--x', …)` 的变量，都必须
/// 作为 key 出现在 `browserExtensionThemeColors()` 返回的 map 里（服务器 ⊇ in-app）。将来谁
/// 给 in-app 加了主题变量却忘了同步扩展，本测试转红。
void main() {
  String read(String p) {
    final File f = File(p);
    expect(f.existsSync(), isTrue, reason: 'missing $p');
    return f.readAsStringSync();
  }

  /// popup_settings_injection.dart 里所有 `setProperty('--x', …)` 的变量名。
  Set<String> inAppInjectedVars() {
    final String src =
        read('lib/src/pages/implementations/popup_settings_injection.dart');
    return RegExp(r"setProperty\('(--[a-z0-9-]+)'")
        .allMatches(src)
        .map((Match m) => m.group(1)!)
        .toSet();
  }

  /// `browserExtensionThemeColors()` 返回 map 里的所有 `'--x':` key。
  Set<String> serverThemeVars() {
    final String src = read('lib/src/models/app_model.dart');
    final int start = src.indexOf('browserExtensionThemeColors()');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'browserExtensionThemeColors() not found in app_model.dart');
    // 方法体到第一个 `};`（map 字面量的结束）。
    final int mapEnd = src.indexOf('};', start);
    expect(mapEnd, greaterThan(start));
    final String body = src.substring(start, mapEnd);
    return RegExp(r"'(--[a-z0-9-]+)':")
        .allMatches(body)
        .map((Match m) => m.group(1)!)
        .toSet();
  }

  test('server theme map ships every var the in-app popup injects (BUG-736)',
      () {
    final Set<String> inApp = inAppInjectedVars();
    final Set<String> server = serverThemeVars();
    expect(inApp, isNotEmpty, reason: 'sanity: in-app injector parse failed');
    final List<String> missing =
        inApp.where((String v) => !server.contains(v)).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason: 'browserExtensionThemeColors() 漏发了 in-app 弹窗注入的主题变量 '
          '$missing —— 扩展弹窗会在这些变量上退化成 CSS 兜底值，和 app 不一致（BUG-736）。'
          '在 app_model.dart 的 map 里补上同源的值。',
    );
  });

  test('the four BUG-736 vars are explicitly present (regression pin)', () {
    final Set<String> server = serverThemeVars();
    for (final String v in const <String>[
      '--fushi-primary-highlight',
      '--md-on-primary',
      '--fushi-radius-card',
      '--fushi-card-bg-rgb',
    ]) {
      expect(server.contains(v), isTrue,
          reason: 'BUG-736 修复不得回退：server theme map 必须含 $v');
    }
  });
}
