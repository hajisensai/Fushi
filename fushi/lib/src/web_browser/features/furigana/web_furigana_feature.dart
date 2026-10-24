import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/furigana/web_furigana_annotator.dart';
import 'package:fushi/src/web_browser/features/furigana/web_furigana_script.dart';
import 'package:fushi/src/web_browser/features/furigana/web_known_word_lookup.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';
import 'package:fushi/utils.dart' show ErrorLogService;

/// 「整页注音」开关（bool，默认关）。设备本地：要不要给网页注音看的是这台设备上
/// 的阅读习惯与性能，不随备份 / 同步 / Profile 走。
const String kWebBrowserFuriganaPrefKey = 'web_browser_furigana';

/// 「生词高亮」开关（bool，默认关）。设备本地，理由同上。
const String kWebBrowserKnownWordsPrefKey = 'web_browser_known_words';

/// 整页注音 + 已知词高亮（见 [webFuriganaInstallSource] 与 [WebFuriganaAnnotator]）。
///
/// 两个开关是全局的（对所有标签页生效）、设备本地持久化；切换时立即重配所有活着的
/// 标签页，新文档在主框架加载完时按当前开关安装。「生词高亮」只在复习模块开着时
/// 出现（没有复习库就没有「已知」可言）。
class WebBrowserFuriganaFeature extends WebBrowserFeature {
  WebBrowserFuriganaFeature({
    required PrefStore prefs,
    WebFuriganaTokenizer? tokenizer,
    Future<SrsDbStore?> Function()? srsStore,
    bool Function()? srsAvailable,
  }) : _prefs = prefs,
       _srsStore = srsStore ?? _currentSrsStore,
       _srsAvailableProbe = srsAvailable ?? _currentSrsAvailable,
       _furigana =
           prefs.getPref(kWebBrowserFuriganaPrefKey, defaultValue: false) ==
           true,
       _highlight =
           prefs.getPref(kWebBrowserKnownWordsPrefKey, defaultValue: false) ==
           true,
       _tokenizer =
           tokenizer ??
           JapaneseLanguage.instance.textsToWordsWithReadingsInBackground;

  static Future<SrsDbStore?> _currentSrsStore() async =>
      SrsAppHost.current?.readStore();

  static bool _currentSrsAvailable() => SrsAppHost.current != null;

  final PrefStore _prefs;
  final Future<SrsDbStore?> Function() _srsStore;
  final bool Function() _srsAvailableProbe;
  final WebBrowserFeatureNotifier _changes = WebBrowserFeatureNotifier();
  final WebFuriganaTokenizer _tokenizer;
  final Set<WebBrowserTab> _tabs = <WebBrowserTab>{};
  bool _furigana;
  bool _highlight;
  String _unknownColor = '#3b82f6';
  String _learningColor = '#f59e0b';

  late final WebFuriganaAnnotator _annotator = WebFuriganaAnnotator(
    tokenizer: _tokenizer,
    knownWords: _lookupKnownWords,
  );

  bool get furiganaEnabled => _furigana;
  bool get highlightEnabled => _highlight && _srsAvailable;

  bool get _srsAvailable => _srsAvailableProbe();

  @override
  String get id => 'furigana';

  WebFuriganaPageConfig get pageConfig => WebFuriganaPageConfig(
    furigana: _furigana,
    highlight: highlightEnabled,
    unknownColor: _unknownColor,
    learningColor: _learningColor,
  );

  Future<Map<String, WebKnownWordStatus>> _lookupKnownWords(
    Set<String> surfaces,
  ) async {
    final SrsDbStore? store = await _srsStore();
    if (store == null) return const <String, WebKnownWordStatus>{};
    return lookupWebKnownWords(store, surfaces);
  }

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

  /// 页内一批文本 → 注音词序列。开关都关着时（网页自己调这个 handler）一律回 null：
  /// 不给未开功能的页面暴露分词与复习状态。
  Future<Object?> _onAnnotate(List<dynamic> args) async {
    final ({List<String> texts, bool furigana, bool highlight})? req =
        parseWebFuriganaRequest(args);
    if (req == null || !pageConfig.enabled) return null;
    try {
      return await _annotator.annotate(
        req.texts,
        furigana: req.furigana && _furigana,
        highlight: req.highlight && highlightEnabled,
      );
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
    if (!pageConfig.enabled) return;
    await _configure(controller);
  }

  @override
  void onTabClosed(WebBrowserTab tab) => _tabs.remove(tab);

  Future<void> _configure(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: webFuriganaConfigureInvocation(pageConfig),
      );
    } on Object catch (e, st) {
      ErrorLogService.instance.log('WebBrowserFurigana.configure', e, st);
    }
  }

  /// 改开关：落偏好并立即重配所有活着的标签页。
  Future<void> setFlags({bool? furigana, bool? highlight}) async {
    final bool wasEnabled = pageConfig.enabled;
    if (furigana != null && furigana != _furigana) {
      _furigana = furigana;
      unawaited(_prefs.setPref(kWebBrowserFuriganaPrefKey, furigana));
    }
    if (highlight != null && highlight != _highlight) {
      _highlight = highlight;
      unawaited(_prefs.setPref(kWebBrowserKnownWordsPrefKey, highlight));
    }
    _changes.notify();
    // 从没开过的页面没装脚本，关着再关不必注入。
    if (!wasEnabled && !pageConfig.enabled) return;
    await Future.wait(<Future<void>>[
      for (final WebBrowserTab tab in _tabs.toList())
        if (tab.controller != null) _configure(tab.controller!),
    ]);
  }

  void _captureColors(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    _unknownColor = webCssColor(scheme.primary);
    _learningColor = webCssColor(scheme.tertiary);
  }

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    _captureColors(context);
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'furigana',
        icon: FushiIcons.textFields,
        label: t.web_browser_furigana,
        selected: _furigana,
        priority: 30,
        onPressed: () => unawaited(setFlags(furigana: !_furigana)),
      ),
      if (_srsAvailable)
        WebBrowserAction(
          id: 'known-words',
          icon: FushiIcons.outlineColor,
          label: t.web_browser_known_words,
          selected: _highlight,
          priority: 25,
          onPressed: () => unawaited(setFlags(highlight: !_highlight)),
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
