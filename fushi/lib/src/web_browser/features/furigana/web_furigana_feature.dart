import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/furigana/web_furigana_annotator.dart';
import 'package:fushi/src/web_browser/features/furigana/web_furigana_script.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';
import 'package:fushi/utils.dart' show ErrorLogService;

/// 「整页注音」开关（bool，默认关）。设备本地：要不要给网页注音看的是这台设备上
/// 的阅读习惯与性能，不随备份 / 同步 / Profile 走。
const String kWebBrowserFuriganaPrefKey = 'web_browser_furigana';

/// 整页注音（见 [webFuriganaInstallSource] 与 [WebFuriganaAnnotator]）。
///
/// 开关是全局的（对所有标签页生效）、设备本地持久化；切换时立即重配所有活着的
/// 标签页，新文档在主框架加载完时按当前开关安装。
class WebBrowserFuriganaFeature extends WebBrowserFeature {
  WebBrowserFuriganaFeature({
    required PrefStore prefs,
    WebFuriganaTokenizer? tokenizer,
  }) : _prefs = prefs,
       _furigana =
           prefs.getPref(kWebBrowserFuriganaPrefKey, defaultValue: false) ==
           true,
       _tokenizer =
           tokenizer ??
           JapaneseLanguage.instance.textsToWordsWithReadingsInBackground;

  final PrefStore _prefs;
  final WebBrowserFeatureNotifier _changes = WebBrowserFeatureNotifier();
  final WebFuriganaTokenizer _tokenizer;
  final Set<WebBrowserTab> _tabs = <WebBrowserTab>{};
  bool _furigana;

  late final WebFuriganaAnnotator _annotator = WebFuriganaAnnotator(
    tokenizer: _tokenizer,
  );

  @override
  String get id => 'furigana';

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    _tabs.add(tab);
    controller.addJavaScriptHandler(
      handlerName: kWebFuriganaHandler,
      callback: limitWebPayload(
        kWebFuriganaHandler,
        kWebPayloadSmallMaxChars,
        _onAnnotate,
      ),
    );
  }

  /// 页内一批文本 → 注音词序列。开关关着时（网页自己调这个 handler）一律回 null：
  /// 不给未开功能的页面暴露分词。
  Future<Object?> _onAnnotate(List<dynamic> args) async {
    final List<String>? texts = parseWebFuriganaRequest(args);
    if (texts == null || !_furigana) return null;
    try {
      return await _annotator.annotate(texts);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('WebBrowserFurigana.annotate', e, st);
      return null;
    }
  }

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) async {
    if (!_furigana) return;
    await _configure(controller);
  }

  @override
  void onTabClosed(WebBrowserTab tab) => _tabs.remove(tab);

  Future<void> _configure(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: webFuriganaConfigureInvocation(enabled: _furigana),
      );
    } on Object catch (e, st) {
      ErrorLogService.instance.log('WebBrowserFurigana.configure', e, st);
    }
  }

  /// 改开关：落偏好并立即重配所有活着的标签页。
  Future<void> setFurigana(bool furigana) async {
    if (furigana == _furigana) return;
    _furigana = furigana;
    unawaited(_prefs.setPref(kWebBrowserFuriganaPrefKey, furigana));
    _changes.notify();
    await Future.wait(<Future<void>>[
      for (final WebBrowserTab tab in _tabs.toList())
        if (tab.controller != null) _configure(tab.controller!),
    ]);
  }

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'furigana',
        icon: FushiIcons.textFields,
        label: t.web_browser_furigana,
        selected: _furigana,
        priority: 30,
        onPressed: () => unawaited(setFurigana(!_furigana)),
      ),
    ];
  }

  @override
  Listenable get actionsChanged => _changes;

  @override
  void dispose() {
    _tabs.clear();
    _changes.dispose();
  }
}

/// [Color] → CSS `#rrggbb`（不带透明度：脚本自己按需混透明）。
String webCssColor(Color c) {
  String hex(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${hex(c.r)}${hex(c.g)}${hex(c.b)}';
}
