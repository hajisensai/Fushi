import 'dart:convert';

import 'package:fushi_server/src/admin/web_ui.dart';
import 'package:fushi_server/src/admin/web_ui_en.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:test/test.dart';

/// 中日文字符（含全角标点）；出现即视为待翻译文案。
final RegExp _cjk = RegExp('[　-〿一-鿿＀-￯]');
final RegExp _placeholder = RegExp(r'\{\d+\}');

String _between(String s, String start, String end) {
  final int a = s.indexOf(start);
  final int b = s.indexOf(end, a);
  expect(a, isNonNegative, reason: '找不到 $start');
  expect(b, greaterThan(a), reason: '找不到 $end');
  return s.substring(a, b);
}

String _unescapeJs(String s) => s.replaceAllMapped(
  RegExp(r'\\(.)'),
  (Match m) => m.group(1) == 'n' ? '\n' : m.group(1)!,
);

/// 页面里所有要查表的中文：静态文本节点、placeholder / title、脚本 `T('…')` 字面量、
/// 登录页 `__T_…__` 占位，以及登录失败提示。
List<String> _pageKeys() {
  final Set<String> keys = <String>{};
  final String markup = _between(adminWebUiHtml, '<body>', '<script>');
  for (final Match m in RegExp(r'>([^<]+)<').allMatches(markup)) {
    final String t = m.group(1)!.trim();
    if (_cjk.hasMatch(t)) keys.add(t);
  }
  for (final Match m in RegExp(
    r'(?:placeholder|title)="([^"]*)"',
  ).allMatches(markup)) {
    if (_cjk.hasMatch(m.group(1)!)) keys.add(m.group(1)!);
  }
  final String script = _between(adminWebUiHtml, '<script>', '</script>');
  for (final Match m in RegExp(
    r"\bT\('((?:[^'\\]|\\.)*)'",
  ).allMatches(script)) {
    keys.add(_unescapeJs(m.group(1)!));
  }
  for (final Match m in RegExp(
    r'__T_(.+?)__',
    dotAll: true,
  ).allMatches(adminLoginHtml)) {
    keys.add(m.group(1)!);
  }
  keys.add('Token 不正确');
  return keys.toList();
}

void main() {
  group('WebUI 英文表', () {
    test('页面里每条中文都有英文，且表里没有多余的键', () {
      final List<String> keys = _pageKeys();
      expect(keys.length, greaterThan(300), reason: '抽取规则失效了');
      final List<String> missing = keys
          .where((String k) => !kWebUiEnglish.containsKey(k))
          .toList();
      final Set<String> keySet = keys.toSet();
      final List<String> extra = kWebUiEnglish.keys
          .where((String k) => !keySet.contains(k))
          .toList();
      expect(missing, isEmpty, reason: '缺英文');
      expect(extra, isEmpty, reason: '页面已不用的键');
    });

    test('英文里的 {n} 参数位与中文一致，英文不含中文', () {
      kWebUiEnglish.forEach((String zh, String en) {
        final List<String> a =
            _placeholder.allMatches(zh).map((Match m) => m[0]!).toList()
              ..sort();
        final List<String> b =
            _placeholder.allMatches(en).map((Match m) => m[0]!).toList()
              ..sort();
        expect(b, a, reason: zh);
        expect(en.trim(), isNotEmpty, reason: zh);
      });
      // 唯一允许的中文：语言下拉里「界面语言」的中文提示（给读不懂英文的人找回中文）。
      final List<String> withCjk = kWebUiEnglish.entries
          .where((MapEntry<String, String> e) => _cjk.hasMatch(e.value))
          .map((MapEntry<String, String> e) => e.key)
          .toList();
      expect(withCjk, <String>['界面语言（Language）']);
    });

    test('脚本里的中文全包在 T() 里（注释与语言名除外）', () {
      final String script = _between(adminWebUiHtml, '<script>', '</script>');
      final List<String> stray = <String>[];
      for (final String raw in const LineSplitter().convert(script)) {
        String line = raw;
        final int comment = line.indexOf('// ');
        if (comment >= 0 && !line.substring(0, comment).contains("'")) {
          line = line.substring(0, comment);
        }
        line = line
            .replaceAll(RegExp(r"\bT\('(?:[^'\\]|\\.)*'"), "T(''")
            .replaceAll(RegExp(r'/\*.*?\*/'), '')
            .replaceAll("zh:'中文'", '');
        if (line.trimLeft().startsWith('//')) continue;
        if (_cjk.hasMatch(line)) stray.add(raw.trim());
      }
      expect(stray, isEmpty);
    });
  });

  group('按语言出页', () {
    test('英文：填好 lang / LANG / EN，不留占位', () {
      final String html = renderAdminWebUi(ServerConfig.languageEnglish);
      expect(html, contains('<html lang="en">'));
      expect(html, contains('const LANG = "en";'));
      expect(html, contains(jsonEncode(kWebUiEnglish)));
      expect(html, isNot(contains('__FUSHI_')));
    });

    test('中文：EN 为空表', () {
      final String html = renderAdminWebUi(ServerConfig.languageChinese);
      expect(html, contains('<html lang="zh-CN">'));
      expect(html, contains('const LANG = "zh";'));
      expect(html, contains('const EN = {};'));
      expect(html, isNot(contains('__FUSHI_')));
    });

    test('登录页按语言出文案与错误提示', () {
      final String en = renderAdminLogin(
        ServerConfig.languageEnglish,
        tokenError: true,
      );
      expect(en, contains('<html lang="en">'));
      expect(en, contains('>Sign in</button>'));
      expect(en, contains('Wrong token'));
      expect(en, isNot(contains('__T_')));
      expect(en, isNot(contains('__FUSHI_')));
      expect(_cjk.hasMatch(en), isFalse);

      final String zh = renderAdminLogin(ServerConfig.languageChinese);
      expect(zh, contains('<html lang="zh-CN">'));
      expect(zh, contains('>登录</button>'));
      expect(zh, isNot(contains('Token 不正确')));
      expect(zh, isNot(contains('__T_')));
    });
  });
}
