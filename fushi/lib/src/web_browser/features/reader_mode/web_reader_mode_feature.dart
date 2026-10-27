import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/novel/web/web_novel_gate.dart';
import 'package:fushi/src/media/novel/web/web_novel_page_fetcher.dart';
import 'package:fushi/src/media/novel/web/web_novel_reader_launch.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/reader_mode/web_reader_mode_document.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/utils.dart';

/// 一个标签页的阅读模式状态。
class _ReaderModeState {
  _ReaderModeState({required this.url, required this.sourceHtml});

  /// 进阅读模式时的页面地址。
  final Uri url;

  /// 换掉之前的原页 HTML（「存进书架」要原页：下一章 / 目录链接都在里面）。
  final Uint8List sourceHtml;
}

/// 提取 + 渲染的测试缝。
typedef WebReaderModeExtractor =
    Future<WebArticle> Function(Uint8List html, Uri url);

/// 阅读模式：任意文章页一键换成干净排版（正文提取与网页小说同一个 Rust 提取器，
/// 见 [webReaderModeInstallScript]），查词照常；阅读模式里可「存进书架」，走
/// 网页小说既有的入书架路径 [readWebNovelPageInFushi]（含预览确认、并进已有作品）。
///
/// 合规：阅读模式本身只是把**当前已打开的页面**换个排版显示，与 Safari 阅读器同类，
/// 不抓别的页、不装在线源，不受 App Store 那三类限制——五端都有。「存进书架」把任意
/// 网站正文入库并支持追更，与 LNReader 在线小说源同一道门
/// （[webNovelReaderActionAvailable] → `StoreRestrictedCapability.onlineNovelSource`），
/// iOS 上不出现。
class WebBrowserReaderModeFeature extends WebBrowserFeature {
  WebBrowserReaderModeFeature({
    required WidgetRef ref,
    WebReaderModeExtractor? extractor,
    bool Function()? saveAvailable,
  }) : _ref = ref,
       _extract = extractor ?? _defaultExtract,
       _saveAvailable = saveAvailable ?? webNovelReaderActionAvailable;

  static Future<WebArticle> _defaultExtract(Uint8List html, Uri url) =>
      WebArticleExtractor.extract(html, url);

  final WidgetRef _ref;
  final WebReaderModeExtractor _extract;
  final bool Function() _saveAvailable;
  final Map<String, _ReaderModeState> _states = <String, _ReaderModeState>{};
  final Set<String> _busy = <String>{};
  final WebBrowserFeatureNotifier _changes = WebBrowserFeatureNotifier();

  @override
  String get id => 'reader-mode';

  bool isActive(WebBrowserTab tab) => _states.containsKey(tab.id);

  @override
  Listenable get actionsChanged => _changes;

  /// 主框架任何一次加载完成（导航 / 退出时的重载）都意味着原页回来了。阅读模式只在
  /// 页面加载完后才能进（见 [actions] 的禁用条件），换 body 不触发加载事件。
  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) async {
    if (_states.remove(tab.id) != null) _changes.notify();
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    _states.remove(tab.id);
    _busy.remove(tab.id);
  }

  Future<void> _enter(BuildContext context, WebBrowserTab tab) async {
    final InAppWebViewController? controller = tab.controller;
    final Uri? url = tab.url;
    if (controller == null || url == null || !_busy.add(tab.id)) return;
    _changes.notify();
    try {
      final Uint8List html = await webNovelPageHtml(controller);
      final WebArticle article = await _extract(html, url);
      if (!webReaderModeAccepts(article)) {
        FushiToast.show(
          msg: t.web_browser_reader_mode_empty,
          severity: ToastSeverity.warning,
        );
        return;
      }
      if (!context.mounted) return;
      final WebReaderModeTheme theme = webReaderModeThemeOf(context);
      await controller.evaluateJavascript(
        source: webReaderModeInstallScript(
          bodyHtml: buildWebReaderModeBody(article, siteName: url.host),
          css: buildWebReaderModeCss(theme),
        ),
      );
      // 换 body 期间用户导航走了：原页已不在，不记状态。
      if (tab.url != url) return;
      _states[tab.id] = _ReaderModeState(url: url, sourceHtml: html);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('WebBrowserReaderMode.enter', e, st);
      FushiToast.show(
        msg: t.web_browser_reader_mode_empty,
        severity: ToastSeverity.warning,
      );
    } finally {
      _busy.remove(tab.id);
      _changes.notify();
    }
  }

  Future<void> _exit(WebBrowserTab tab) async {
    _states.remove(tab.id);
    _changes.notify();
    try {
      await tab.controller?.reload();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('WebBrowserReaderMode.exit', e, st);
    }
  }

  Future<void> _save(BuildContext context, WebBrowserTab tab) async {
    final _ReaderModeState? state = _states[tab.id];
    final InAppWebViewController? controller = tab.controller;
    if (state == null || controller == null) return;
    await readWebNovelPageInFushi(
      context: context,
      ref: _ref,
      controller: controller,
      pageUrl: state.url,
      pageHtml: state.sourceHtml,
    );
  }

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    final bool active = isActive(tab);
    final bool busy = _busy.contains(tab.id);
    final bool canEnter =
        !busy &&
        !tab.loading &&
        tab.controller != null &&
        webReaderModeSupportsUrl(tab.url);
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'reader-mode',
        icon: FushiIcons.readerMode,
        label: active
            ? t.web_browser_reader_mode_exit
            : t.web_browser_reader_mode,
        selected: active,
        placement: WebBrowserActionPlacement.toolbar,
        priority: 60,
        onPressed: active
            ? () => unawaited(_exit(tab))
            : canEnter
            ? () => unawaited(_enter(context, tab))
            : null,
      ),
      if (active && _saveAvailable())
        WebBrowserAction(
          id: 'reader-mode-save',
          icon: FushiIcons.libraryAdd,
          label: t.web_browser_reader_mode_save,
          priority: 40,
          onPressed: () => unawaited(_save(context, tab)),
        ),
    ];
  }

  @override
  void dispose() {
    _states.clear();
    _changes.dispose();
  }
}

/// 只对普通网页开放（`about:` / `file:` / 内部页没有可提取的文章）。
bool webReaderModeSupportsUrl(Uri? url) =>
    url != null && (url.scheme == 'http' || url.scheme == 'https');

/// 阅读模式配色跟随 app 当前主题。
WebReaderModeTheme webReaderModeThemeOf(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme s = theme.colorScheme;
  return WebReaderModeTheme(
    background: webCssColor(s.surface),
    text: webCssColor(s.onSurface),
    muted: webCssColor(s.onSurfaceVariant),
    accent: webCssColor(s.primary),
    dark: theme.brightness == Brightness.dark,
  );
}

/// [Color] → CSS `#rrggbb`（不带透明度：脚本自己按需混透明）。
String webCssColor(Color c) {
  String hex(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${hex(c.r)}${hex(c.g)}${hex(c.b)}';
}
