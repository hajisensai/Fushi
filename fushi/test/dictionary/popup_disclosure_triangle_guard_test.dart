import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1337 守卫：查词弹窗「词典分组展开/收起三角」用纯 CSS 边框三角形，禁止回退到
/// 字体字形（旧: `content: '▶'` / `content: '▼'`）。
///
/// 根因：字体字形三角会继承弹窗当前字体——包括用户注入的自定义词典字体
/// (`html,body{font-family:<custom>,...}`)。若该字体缺 U+25B6/U+25BC 或按 emoji 呈现，
/// 某些平台/WebView（Android WebView、自定义词典字体、emoji 回退）下三角会渲染成
/// 空白/彩色 emoji/豆腐块，即用户报的「展开收起图标渲染不出来」。边框三角是纯几何、
/// 零字体依赖，全平台/全字体一致渲染（与 Niratan 的 `.entry-current::before` 同法）。
///
/// 三镜像同守：in-app 弹窗 + 两份浏览器扩展 vendor 副本（`popup_pitch_noselect_guard`
/// 另有「两 vendor 逐字节一致」守卫，此处只锁三角形状）。
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// 抽取 `<selector> { ... }` 规则块内容（popup 这些规则无嵌套花括号）。
  String ruleBody(String css, String selector) {
    final int start = css.indexOf('$selector {');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'rule "$selector" not found');
    final int open = css.indexOf('{', start);
    final int close = css.indexOf('}', open);
    expect(close, greaterThan(open), reason: 'rule "$selector" not closed');
    return css.substring(open + 1, close);
  }

  const Map<String, String> mirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.css',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.css',
  };

  mirrors.forEach((String name, String relPath) {
    group('[$name] 折叠三角为字体无关的边框三角形', () {
      late final String css;
      setUpAll(() => css = read(relPath));

      test('不再用字体字形 ▶ / ▼（旧的脆弱做法）', () {
        expect(css.contains("content: '▶"), isFalse,
            reason: '禁止用 ▶ 字体字形（缺字体/emoji 回退会渲染不出来）');
        expect(css.contains("content: '▼"), isFalse, reason: '禁止用 ▼ 字体字形');
      });

      test('收起态 = 右向边框三角（border-left currentColor）', () {
        final String body = ruleBody(css, '.glossary-group > summary::before');
        expect(body, contains("content: ''"),
            reason: '::before 需空 content 生成盒子承载边框三角');
        expect(body, contains('border-left: 5px solid currentColor'),
            reason: '收起态右向三角：左边框实心 currentColor（顶点朝右）');
        expect(body, contains('border-top: 4px solid transparent'),
            reason: '上/下边框透明夹出三角高度');
      });

      test('展开态 = 下向边框三角（border-top currentColor）', () {
        final String body =
            ruleBody(css, '.glossary-group[open] > summary::before');
        expect(body, contains('border-top: 5px solid currentColor'),
            reason: '展开态下向三角：上边框实心 currentColor（顶点朝下）');
        expect(body, contains('border-bottom: 0'),
            reason: '展开态显式重设下边框，避免残留收起态边框');
      });
    });
  });
}
