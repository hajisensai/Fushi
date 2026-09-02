import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词弹窗「词典分组展开/收起三角」的两条几何不变式守卫。
///
/// TODO-1337（原始不变式）：三角必须是**纯 CSS 边框几何**，禁止回退到字体字形
/// （旧: `content: '▶'` / `content: '▼'`）。字体字形三角会继承弹窗当前字体——包括用户
/// 注入的自定义词典字体 (`html,body{font-family:<custom>,...}`)。若该字体缺 U+25B6/
/// U+25BC 或按 emoji 呈现，某些平台/WebView（Android WebView、自定义词典字体、emoji
/// 回退）下三角会渲染成空白/彩色 emoji/豆腐块，即用户报的「展开收起图标渲染不出来」。
///
/// BUG-2049（本轮加强）：**切换展开/收起不得改变任何布局几何**。TODO-1337 的修法给
/// `[open]` 重设了四条边框，而边框三角的布局盒尺寸就是它两组对边之和——换朝向即换盒子：
/// 收起 5px 宽 × 8px 高，展开 8px 宽 × 5px 高。盒宽 5→8 把后面的词典名整体右推 3px，
/// 用户报「展开没展开高度和词典头位置会变动」。同一根因的第二处：卡头与释义之间的 2px
/// 间距原本挂在 `div[data-dictionary]` 的 `padding-top` 上，而那个 div 只在展开态参与
/// 布局，于是展开一本没有可见释义的词典也会凭空长高 2px。
///
/// headless Edge 实测（真 popup.css，Noto CJK / Yu Gothic / Meiryo / 默认 四种字体
/// 结论一致），`.dict-name` 相对 summary 的左偏移 与 卡片高度：
///   修前  收起 10px / 29px  →  展开 13px / 31px   （横跳 3px、凭空高 2px）
///   修后  收起 10px / 31px  →  展开 10px / 31px   （四项 delta 全 0）
/// 有真实释义的卡片高度修前修后同为 50.594px，观感不变。
///
/// 五镜像同守：in-app 弹窗 popup.css + 两份扩展 vendor popup.css + 两份**生成的**
/// content.css。把生成产物一起纳入扫描面，才抓得到「改了真源忘了重新跑
/// generate-content-css.mjs」（`popup_pitch_noselect_guard` 另有逐字节一致守卫，
/// 此处只锁三角与间距的几何不变式）。
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// 剥掉 `/* ... */` 注释再做规则匹配。注释里天然会出现被禁的字面量（本文件锁的
  /// `padding-top` / `border-top` 在修复说明里都被提到），不剥就会把解释文字当成
  /// 真声明命中，守卫恒红或恒绿都可能。
  String stripComments(String css) =>
      css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');

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

  /// 把规则体拆成 `属性名` 列表，用于「只允许出现哪些属性」这类白名单断言。
  List<String> declaredProperties(String body) => body
      .split(';')
      .map((String d) => d.trim())
      .where((String d) => d.isNotEmpty)
      .map((String d) => d.split(':').first.trim())
      .toList();

  const Map<String, String> mirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.css',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.css',
    'extension content (assets)': 'assets/browser_extension/vendor/content.css',
    'extension content (tools)':
        '../tools/browser-extension/vendor/content.css',
  };

  mirrors.forEach((String name, String relPath) {
    group('[$name] 折叠三角：字体无关 + 展开收起零布局变化', () {
      late final String css;
      setUpAll(() => css = stripComments(read(relPath)));

      test('TODO-1337 不再用字体字形 ▶ / ▼（旧的脆弱做法）', () {
        expect(css.contains("content: '▶"), isFalse,
            reason: '禁止用 ▶ 字体字形（缺字体/emoji 回退会渲染不出来）');
        expect(css.contains("content: '▼"), isFalse, reason: '禁止用 ▼ 字体字形');
      });

      test('TODO-1337 收起态 = 右向边框三角（border-left currentColor）', () {
        final String body = ruleBody(css, '.glossary-group > summary::before');
        expect(body, contains("content: ''"),
            reason: '::before 需空 content 生成盒子承载边框三角');
        expect(body, contains('border-left: 5px solid currentColor'),
            reason: '收起态右向三角：左边框实心 currentColor（顶点朝右）');
        expect(body, contains('border-top: 4px solid transparent'),
            reason: '上/下边框透明夹出三角高度');
      });

      test('BUG-2049 展开态只旋转，不声明任何影响布局盒的属性', () {
        final List<String> props = declaredProperties(
            ruleBody(css, '.glossary-group[open] > summary::before'));
        expect(props, isNotEmpty, reason: '展开态必须有朝向声明，否则三角不会变成指下');
        expect(props, contains('transform'),
            reason: '展开态朝向必须靠 transform 旋转（transform 不参与布局）');
        expect(ruleBody(css, '.glossary-group[open] > summary::before'),
            contains('transform: rotate(90deg)'),
            reason: '展开态必须是绕盒心旋转 90° 的下向三角；'
                '只声明 transform 属性名不够——transform: none / rotate(0deg) 会让两态图标同形');
        // 白名单而非黑名单：任何新属性都得先想清楚它会不会改盒子。border-* 会（边框
        // 三角的盒尺寸=两组对边之和），width/height/margin/padding/display/font-size
        // 也会——它们一旦出现，词典名就会随展开状态横向跳动（BUG-2049 原始症状）。
        expect(props, everyElement(anyOf('transform', 'transform-origin')),
            reason: '展开态只允许 transform / transform-origin；'
                '出现 $props 中的其它属性说明布局盒又随状态变了');
      });

      test('BUG-2049 卡头与释义的间距不挂在「只在展开态存在」的内容 div 上', () {
        final List<String> contentProps = declaredProperties(
            ruleBody(css, '.glossary-group > div[data-dictionary]'));
        expect(contentProps.contains('padding-top'), isFalse,
            reason: 'div[data-dictionary] 只在展开态参与布局，挂在它上面的固定上间距'
                '会让「展开一本没有可见释义的词典」凭空长高');
        expect(contentProps.contains('margin-top'), isFalse,
            reason: 'margin-top 与 padding-top 同病：状态相关的上间距');

        final String summaryBody = ruleBody(css, '.glossary-group > summary');
        expect(summaryBody, contains('padding-bottom: 2px'),
            reason: '间距的拥有者必须是恒存在的卡头，卡片基线高度才与展开状态无关');
      });
    });
  });
}
