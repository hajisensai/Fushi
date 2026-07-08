import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1325 #7 / #5 part1 + TODO-1338 三镜像守卫：查词弹窗的样式/脚本改动必须三端一致
/// （in-app 弹窗 + 两份浏览器扩展 vendor 副本；byte-parity 由
/// `browser_extension_popup_parity_guard` 另锁，此处锁语义约束防回退）。
///
///   #7 词典卡片：`.glossary-group` 是玻璃卡片（圆角走 token + 分层投影 + inset 内高光）。
///   #5 词条导航：popup.js 暴露 `hoshiFocusDictionaryEntry/Move/Reset`，当前词条走
///      `.entry-current` 的 #1a73e8 纯 CSS 边框蓝三角（零字体依赖）。
///   #1338 制卡图标乱码：制卡按钮保留 ✓/✓↩ 文本标记（应用户要求不走 SVG），但用
///      `.mine-button` 单色符号字体栈切断对注入词典字体的继承，且 ↩ 追加 VS15(U+FE0E)
///      强制文本呈现——两处合力杜绝制卡后乱码。
///
/// flutter test cwd 是 hibiki 包根。
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// 抽取 `<selector> { ... }` 规则块（行首锚定，避免命中后代规则）。
  String ruleBody(String css, String selectorPattern) {
    final RegExp re = RegExp(r'(?:^|\n)' + selectorPattern + r'\s*\{([^}]*)\}');
    final RegExpMatch? m = re.firstMatch(css);
    expect(m, isNotNull, reason: 'rule "$selectorPattern" not found');
    return m!.group(1)!;
  }

  const Map<String, String> cssMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.css',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.css',
  };
  const Map<String, String> jsMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };

  cssMirrors.forEach((String name, String relPath) {
    group('[$name] popup.css 语义约束', () {
      late final String css;
      setUpAll(() => css = read(relPath));

      test('#7 词典卡片：.glossary-group 圆角(token)+投影+inset 内高光', () {
        final String body = ruleBody(css, r'\.glossary-group');
        expect(body.contains('var(--hibiki-radius-card'), isTrue,
            reason: '卡片圆角走 --hibiki-radius-card token，与弹窗其余卡片统一');
        expect(RegExp(r'box-shadow\s*:').hasMatch(body), isTrue,
            reason: '卡片要有分层投影');
        expect(body.contains('inset'), isTrue,
            reason: 'box-shadow 含 inset 顶部内高光（玻璃质感）');
      });

      test('#5 当前词条蓝三角 = 纯 CSS 边框三角 #1a73e8（零字体依赖）', () {
        final String body =
            ruleBody(css, r'\.entry-current \.entry-header::before');
        expect(body, contains("content: ''"),
            reason: '::before 空 content 承载纯边框三角，不用字体字形');
        expect(body.contains('#1a73e8'), isTrue,
            reason: '当前词条指示用 Niratan 同款蓝 #1a73e8');
        expect(RegExp(r'border-left\s*:\s*7px solid #1a73e8').hasMatch(body),
            isTrue,
            reason: '右向三角：左边框实心蓝（顶点朝右指向词条）');
      });

      test('#1338 制卡按钮钉单色符号字体栈，切断注入词典字体继承', () {
        // 直接找「含 font-family 的独立 .mine-button 规则块」——不能用通用 ruleBody，因为
        // 它会先命中 `.audio-button,.favorite-button,.mine-button` 合并块（无 font-family）。
        final RegExp rule = RegExp(
            r'\.mine-button\s*\{[^}]*font-family[^}]*Segoe UI Symbol[^}]*!important');
        expect(rule.hasMatch(css), isTrue,
            reason: '.mine-button 显式声明单色符号字体栈(含 Segoe UI Symbol)+!important，'
                '切断对 html,body 注入词典字体的继承（否则制卡后 ✓/✓↩ 缺码位乱码）');
        // 不得含彩色 emoji 字体（否则 ↩ 又走 emoji 呈现）。
        final Match? m = rule.firstMatch(css);
        expect(m!.group(0)!.contains('Emoji'), isFalse,
            reason: '字体栈不含彩色 emoji 字体');
      });
    });
  });

  jsMirrors.forEach((String name, String relPath) {
    group('[$name] popup.js 语义约束', () {
      late final String js;
      setUpAll(() => js = read(relPath));

      test(
          '#5 暴露 hoshiFocusDictionaryEntry/Move/Reset + data-hoshi-entry-index',
          () {
        expect(js.contains('window.hoshiFocusDictionaryEntry ='), isTrue,
            reason: '聚焦指定下标词条 API');
        expect(js.contains('window.hoshiFocusDictionaryEntryMove ='), isTrue,
            reason: '相对上/下一条词条 API（Dart 焦点驱动调用点）');
        expect(js.contains('window.hoshiFocusDictionaryEntryReset ='), isTrue,
            reason: '清除当前词条焦点 API');
        expect(js.contains('data-hoshi-entry-index'), isTrue,
            reason: '词条打索引属性，DOM 可观测');
      });

      test('#1338 制卡按钮保留 ✓/✓↩ 文本标记且 ↩ 带 VS15（不回退字体乱码）', () {
        // 保留文本标记（应用户要求不走 SVG）。
        expect(js.contains('\u{2713}'), isTrue, reason: '制卡态仍用 ✓(U+2713) 文本标记');
        // ↩ 后必须紧跟 VS15(U+FE0E) 强制文本呈现，杜绝 emoji 回退乱码。
        expect(js.contains('\u{21A9}\u{FE0E}'), isTrue,
            reason: '↩(U+21A9) 后必须追加 VS15(U+FE0E) 强制文本呈现');
      });
    });
  });
}
