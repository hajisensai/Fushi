/// 把可视化样式规则表编译成注入弹窗的 CSS。
///
/// 与 `dictionary_font_css.dart` / `dictionary_language_css.dart` 同范式：UI 设置
/// → 生成 CSS 文本 → 经既有 `globalDictCSS` / `customDictCSS` 通道下发。popup.js
/// 一行不用改，三个消费面（app 内 / Android 独立弹窗 / 浏览器扩展）自动吃到。
library;

import 'package:fushi/src/dictionary/dict_style_rules.dart';

/// 编译全局规则（[DictStyleRule.dictionaryName] == null）。
///
/// 产物拼在用户手写全局 CSS **之前**，让手写的能覆盖可视化的。
String buildGlobalDictStyleCss(List<DictStyleRule> rules) {
  final StringBuffer out = StringBuffer();
  for (final DictStyleRule rule in rules) {
    if (rule.dictionaryName != null) continue;
    final String body = _declarations(rule.props);
    if (body.isEmpty) continue;
    out.writeln('${dictStylePartSelector(rule.part)} { $body }');
  }
  return out.toString();
}

/// 编译某本词典的 per-dictionary 规则。
///
/// 返回的选择器**不带** `[data-dictionary]` 前缀——下发通道会把整段交给
/// `constructDictCss()`（`assets/popup/dict-media.js`）统一加作用域前缀，与用户
/// 手写的 per-dict CSS 走完全相同的路径。在这里自己再加一次前缀会变成
/// `[data-dictionary="X"] [data-dictionary="X"] .foo`，一条都命中不了。
String buildPerDictionaryStyleCss(
  List<DictStyleRule> rules,
  String dictionaryName,
) {
  if (dictionaryName.isEmpty) return '';
  final StringBuffer out = StringBuffer();
  for (final DictStyleRule rule in rules) {
    if (rule.dictionaryName != dictionaryName) continue;
    // 解码期已经抹平过非法组合，这里是第二道闸：直接构造对象的调用方
    // （测试、未来的导入路径）不该绕过约束。
    if (!dictStylePartSupportsPerDictionary(rule.part)) continue;
    final String body = _declarations(rule.props);
    if (body.isEmpty) continue;
    out.writeln('${dictStylePartSelector(rule.part)} { $body }');
  }
  return out.toString();
}

/// 规则表里出现过的所有词典名（用于决定要给哪几本拼 per-dict CSS）。
Set<String> dictionariesWithStyleRules(List<DictStyleRule> rules) => <String>{
      for (final DictStyleRule rule in rules)
        if (rule.dictionaryName != null &&
            dictStylePartSupportsPerDictionary(rule.part))
          rule.dictionaryName!,
    };

/// 把编译产物与用户手写 CSS 拼成最终下发文本。
///
/// 顺序即优先级：产物在前、手写在后。同特异度下后者胜出，用户手写永远能覆盖
/// 可视化面板设的值。
String mergeGeneratedAndAuthoredCss(String generated, String authored) {
  final String g = generated.trim();
  final String a = authored.trim();
  if (g.isEmpty) return authored;
  if (a.isEmpty) return generated;
  return '$g\n$a';
}

/// 生成一条规则的声明串。
///
/// 全部带 `!important`：词典自带的 `styles.css` 是**同特异度**（同样被
/// `constructDictCss` 加了 `[data-dictionary="X"]` 前缀）且注入位置不确定，全局
/// 规则的特异度还更低（`.expression` 打不过 `[data-dictionary="X"] .expression`）。
/// 不加就是「设了没反应」。字体链 `dictionary_language_css.dart` 同样处理。
String _declarations(DictStyleProps props) {
  final List<String> decls = <String>[];
  if (props.textColor != null) {
    decls.add('color: ${_cssColor(props.textColor!)} !important');
  }
  if (props.backgroundColor != null) {
    decls.add(
      'background-color: ${_cssColor(props.backgroundColor!)} !important',
    );
  }
  if (props.bold != null) {
    decls.add('font-weight: ${props.bold! ? 'bold' : 'normal'} !important');
  }
  if (props.italic != null) {
    decls.add('font-style: ${props.italic! ? 'italic' : 'normal'} !important');
  }
  if (props.underline != null) {
    decls.add(
      'text-decoration: ${props.underline! ? 'underline' : 'none'} !important',
    );
  }
  if (props.fontScale != null) {
    decls.add('font-size: ${_num(props.fontScale!)}em !important');
  }
  if (props.cornerRadius != null) {
    decls.add('border-radius: ${_num(props.cornerRadius!)}px !important');
    // 圆角只对 inline 元素（词头/标签）无效——它们没有盒子。给个最小 padding
    // 让背景色+圆角在 inline 上也看得见，否则用户设了圆角却「没反应」。
    decls.add('display: inline-block !important');
  }
  return decls.join('; ');
}

/// 0xAARRGGBB → `rgba(r, g, b, a)`。
///
/// 不用 `#RRGGBBAA`：Android WebView 老版本对八位 hex 支持不一致，rgba() 到处都认。
String _cssColor(int argb) {
  final int a = (argb >> 24) & 0xFF;
  final int r = (argb >> 16) & 0xFF;
  final int g = (argb >> 8) & 0xFF;
  final int b = argb & 0xFF;
  final String alpha = _num(a / 255.0);
  return 'rgba($r, $g, $b, $alpha)';
}

/// 去掉浮点尾巴：`1.0` → `1`，`1.20` → `1.2`。CSS 里 `1.0em` 合法但难读，且会让
/// 编译产物的字节比对（守卫测试）对无意义的格式差异敏感。
String _num(double v) {
  final String s = v.toStringAsFixed(3);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}
