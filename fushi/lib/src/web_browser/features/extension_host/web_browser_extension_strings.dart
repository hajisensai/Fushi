import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:fushi/i18n/strings.g.dart' show LocaleSettings;
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_bundle.dart';

/// 解析扩展的英文源字典 `locales/en.js`（对象字面量，`key: '…',` 一行一条）。
Map<String, String> parseWebBrowserExtensionEnglishLocale(String source) {
  final Map<String, String> out = <String, String>{};
  final RegExp line = RegExp(
    r"^\s*([A-Za-z0-9_]+):\s*'((?:[^'\\]|\\.)*)',?\s*$",
    multiLine: true,
  );
  for (final RegExpMatch m in line.allMatches(source)) {
    out[m.group(1)!] = m
        .group(2)!
        .replaceAllMapped(RegExp(r'\\(.)'), (Match e) => e.group(1)!);
  }
  return out;
}

/// 读扩展界面字典：[languageTag] 的 `locales/<tag>.json`，缺的键回落英文源字典。
Future<Map<String, String>> loadWebBrowserExtensionStrings({
  String? languageTag,
  Future<String> Function(String asset)? loadString,
}) async {
  final Future<String> Function(String) load =
      loadString ?? rootBundle.loadString;
  final Map<String, String> out = <String, String>{};
  try {
    out.addAll(
      parseWebBrowserExtensionEnglishLocale(
        await load('${kWebBrowserExtensionRoot}locales/en.js'),
      ),
    );
  } catch (_) {
    // 没有英文字典：文案退回键名。
  }
  final String tag = languageTag ?? LocaleSettings.currentLocale.languageTag;
  if (tag != 'en') {
    try {
      final Object? decoded = jsonDecode(
        await load('${kWebBrowserExtensionRoot}locales/$tag.json'),
      );
      if (decoded is Map<String, dynamic>) {
        for (final MapEntry<String, dynamic> e in decoded.entries) {
          if (e.value is String) out[e.key] = e.value as String;
        }
      }
    } catch (_) {
      // 该语言没有扩展字典：用英文。
    }
  }
  return out;
}

/// 扩展界面字典的进程内缓存（按 app 当前界面语言）。
///
/// 浏览器设置里扩展那几组的文案直接用扩展自己的字典——同一个开关在扩展设置页、
/// 页内播放器菜单、app 里叫同一个名字，17 种语言的译文也只维护扩展那一份。设置
/// schema 的标题在构造期求值，所以打开那几组之前先 [ensureLoaded]；没读到的键退回
/// 键名本身（只在资产缺失时出现）。
class WebBrowserExtensionStrings {
  WebBrowserExtensionStrings._();

  static final WebBrowserExtensionStrings instance =
      WebBrowserExtensionStrings._();

  String? _tag;
  Map<String, String> _strings = const <String, String>{};
  Future<void>? _loading;
  String? _loadingTag;

  /// 测试注入：替换字典读取（资产名 → 文本）。
  @visibleForTesting
  static Future<String> Function(String asset)? debugLoadString;

  /// 当前语言的字典是否已就绪。
  bool get isLoaded => _tag == LocaleSettings.currentLocale.languageTag;

  /// 读入当前语言的字典（已就绪立即返回；并发调用共用同一次读取）。
  Future<void> ensureLoaded() {
    final String tag = LocaleSettings.currentLocale.languageTag;
    if (_tag == tag) return Future<void>.value();
    if (_loading != null && _loadingTag == tag) return _loading!;
    _loadingTag = tag;
    return _loading = () async {
      final Map<String, String> next = await loadWebBrowserExtensionStrings(
        languageTag: tag,
        loadString: debugLoadString,
      );
      if (_loadingTag != tag) return;
      _strings = next;
      _tag = tag;
      _loading = null;
    }();
  }

  /// 测试用：直接装入字典（视作当前语言已就绪）。
  @visibleForTesting
  void debugSet(Map<String, String> strings) {
    _strings = strings;
    _tag = LocaleSettings.currentLocale.languageTag;
    _loading = null;
    _loadingTag = null;
  }

  /// 测试用：清空缓存。
  @visibleForTesting
  void debugReset() {
    _strings = const <String, String>{};
    _tag = null;
    _loading = null;
    _loadingTag = null;
  }

  /// 文案；`{name}` 形占位按 [params] 替换。
  String tr(String key, [Map<String, String>? params]) {
    String s = _strings[key] ?? key;
    if (params != null) {
      for (final MapEntry<String, String> e in params.entries) {
        s = s.replaceAll('{${e.key}}', e.value);
      }
    }
    return s;
  }

  /// 说明文案：扩展字典里有 `<kbd>` 等内联标记（扩展设置页按 HTML 渲染），这里去标记
  /// 成纯文本。没有这个键返回 null。
  String? plain(String key) {
    final String? s = _strings[key];
    if (s == null) return null;
    return s.replaceAll(RegExp('<[^>]+>'), '');
  }
}
