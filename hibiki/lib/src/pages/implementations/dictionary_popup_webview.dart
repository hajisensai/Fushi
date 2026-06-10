import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

class DictionaryPopupWebView extends ConsumerStatefulWidget {
  const DictionaryPopupWebView({
    required this.result,
    super.key,
    this.onTextSelected,
    this.onLinkClick,
    this.onTapOutside,
    this.onMineEntry,
    this.onDuplicateCheck,
    this.onFavoriteEntry,
    this.onFavoriteCheck,
    this.onScrolledToBottom,
    this.onTopPullReleased,
    this.onRendered,
  });

  final DictionarySearchResult result;
  final void Function(String text, Rect localRect)? onTextSelected;
  final void Function(String query, Rect localRect)? onLinkClick;
  final VoidCallback? onTapOutside;
  final Future<bool> Function(Map<String, String> fields)? onMineEntry;
  final Future<bool> Function(String expression, String reading)?
      onDuplicateCheck;

  /// 切换收藏：返回切换后的新状态（true=已收藏）。供弹窗「☆/★」按钮回调。
  final Future<bool> Function(Map<String, String> fields)? onFavoriteEntry;

  /// 查询某词条当前是否已收藏，用于按钮初始 ☆/★ 状态。
  final Future<bool> Function(String expression, String reading)?
      onFavoriteCheck;
  final VoidCallback? onScrolledToBottom;
  final VoidCallback? onTopPullReleased;

  /// Fired after the popup content finishes rendering (the `popupRendered` JS
  /// handler). Used by the reader to hand the char-level cursor to this popup.
  final VoidCallback? onRendered;

  @override
  ConsumerState<DictionaryPopupWebView> createState() =>
      DictionaryPopupWebViewState();
}

class DictionaryPopupWebViewState
    extends ConsumerState<DictionaryPopupWebView> {
  InAppWebViewController? _controller;

  /// Debug eval on THIS popup's WebView. The reader routes through its
  /// `topPopupState` (gated behind its own @visibleForTesting hook + assert) so
  /// integration tests reach the top visible popup with production's lazy
  /// resolution, avoiding a stale last-writer static.
  Future<dynamic> debugEval(String source) async =>
      _controller?.evaluateJavascript(source: source);
  bool _ready = false;
  String? _lastSearchTerm;
  int _lastEntryCount = 0;

  /// The theme-derived CSS variable JS last pushed to the WebView. Used to
  /// re-inject (and only re-inject) when the app theme actually changes while
  /// the popup is open — see [didChangeDependencies].
  String? _lastThemeVarsJs;

  /// 划词弹窗内容缩放的字号基准。CSS 写死的 px 字号对应「词典字号=16」的视觉，
  /// 故 zoom = appUiScale × (dictionaryFontSize / 16)：默认(16, 100%)时 zoom=1，
  /// 与改动前观感一致；调大词典字号或界面大小时按比例放大。CSS zoom 会按放大尺寸
  /// 重新排版栅格化（不像 FittedBox 拉位图），所以在中和器的原生密度下依旧清晰。
  static const double _popupFontBaseline = 16.0;

  /// 划词弹窗内容 CSS `zoom` 系数：跟随「界面大小」与「词典字号」一起放大，
  /// 与 Dart 侧盒子尺寸（base_source_page / dictionary_page_mixin 乘 appUiScale）一致。
  /// 默认 (appUiScale=1, fontSize=16) → 1.0，保持改动前观感。clamp 防御非法输入。
  static double popupContentZoom({
    required double appUiScale,
    required double dictionaryFontSize,
  }) {
    final double raw = appUiScale * (dictionaryFontSize / _popupFontBaseline);
    if (!raw.isFinite || raw <= 0) return 1.0;
    return raw.clamp(0.3, 8.0).toDouble();
  }

  static const String _scrollCheckJs = '''
(function(){
  if(!window.__hoshiScrollInstalled){
    window.__hoshiScrollInstalled=true;
    var t=0;
    function check(force){
      var now=Date.now();
      if(!force&&now-t<500) return;
      var sh=document.documentElement.scrollHeight;
      var st=window.scrollY||document.documentElement.scrollTop;
      var ch=window.innerHeight;
      if(sh>0&&sh-st-ch<200){
        t=now;
        window.flutter_inappwebview.callHandler('scrolledToBottom');
      }
    }
    window.__hoshiScrollCheck=check;
    window.addEventListener('scroll',function(){check(false);},true);
  }
  setTimeout(function(){window.__hoshiScrollCheck(true);},0);
  setTimeout(function(){window.__hoshiScrollCheck(true);},150);
})();
''';

  static const String _topPullReleaseJs = '''
(function(){
  if(window.__hoshiTopPullInstalled) return;
  window.__hoshiTopPullInstalled = true;
  var startY = null;
  var pulled = false;
  function atTop(){
    var st = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
    return st <= 0;
  }
  window.addEventListener('touchstart', function(e){
    if(!e.touches || e.touches.length !== 1) return;
    startY = e.touches[0].clientY;
    pulled = false;
  }, {passive: true});
  window.addEventListener('touchmove', function(e){
    if(startY === null || !e.touches || e.touches.length !== 1) return;
    if(atTop() && e.touches[0].clientY - startY > 48) {
      pulled = true;
    }
  }, {passive: true});
  window.addEventListener('touchend', function(){
    if(pulled) {
      window.flutter_inappwebview.callHandler('topPullReleased');
    }
    startY = null;
    pulled = false;
  }, {passive: true});
})();
''';

  void highlightSelection(int charCount) {
    _controller?.evaluateJavascript(
      source: 'window.hoshiSelection.highlightSelection($charCount)',
    );
  }

  void clearSelection() {
    _controller?.evaluateJavascript(
      source: 'window.hoshiSelection.clearSelection()',
    );
  }

  // ── Char-level reading cursor (driven from the reader page) ──────────
  // The same window.hoshiCaret as the reader, injected on load and scoped to the
  // definition body. The popup has no chrome insets (the WebView IS the popup)
  // and no hoshiReader, so the cursor runs in horizontal + continuous-scroll
  // mode automatically. The reader reaches these via the popup's webViewKey.

  String _caretRingColorCss() {
    final Color accent = Theme.of(context).colorScheme.primary;
    return 'rgba(${(accent.r * 255).round()},${(accent.g * 255).round()},'
        '${(accent.b * 255).round()},0.98)';
  }

  Future<void> caretInit() async {
    if (!mounted) return;
    await _pushInstantScrollPreference();
    // No scopeSelector: the cursor navigates the whole popup (definition body,
    // headword, tags, and interactive controls), so gamepad users can reach
    // every kanji and every clickable control, not just the definition body.
    await _controller?.evaluateJavascript(
      source: ReaderCaretScripts.initInvocation(
        color: _caretRingColorCss(),
        insetTop: 0,
        insetBottom: 0,
      ),
    );
  }

  Future<String> caretEnter() async {
    final Object? raw = await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.enterInvocation());
    return ReaderCaretScripts.moveStatus(raw);
  }

  void caretExit() {
    _controller?.evaluateJavascript(
        source: ReaderCaretScripts.exitInvocation());
  }

  /// Hide the caret ring without dropping it (user switched to the mouse).
  void caretSuspend() {
    _controller?.evaluateJavascript(
        source: ReaderCaretScripts.suspendInvocation());
  }

  /// Re-show the caret ring (user switched back to keyboard/gamepad).
  void caretResume() {
    _controller?.evaluateJavascript(
        source: ReaderCaretScripts.resumeInvocation());
  }

  Future<String> caretMove(String dir) async {
    final Object? raw = await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.moveInvocation(dir));
    return ReaderCaretScripts.moveStatus(raw);
  }

  Future<String> caretReanchor(String edge) async {
    final Object? raw = await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.reanchorInvocation(edge));
    return ReaderCaretScripts.moveStatus(raw);
  }

  /// LB/RB whole-page scroll of the popup content, re-anchoring the caret ring
  /// to the next line so the cursor follows the view. Popups never paginate, so
  /// the status is only ever 'moved'/'blocked'.
  Future<String> caretScrollPage(bool forward) async {
    final Object? raw = await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.scrollPageInvocation(forward));
    return ReaderCaretScripts.moveStatus(raw);
  }

  Future<void> caretLookup() async {
    await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.lookupInvocation());
  }

  /// A / Enter "context click" at the cursor: follow a cross-reference link,
  /// click an interactive control, or look up plain text — decided by
  /// [ReaderCaretScripts.activate].
  Future<void> caretActivate() async {
    await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.activateInvocation());
  }

  Future<void> caretLongPress() async {
    await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.longPressInvocation());
  }

  Future<void> caretRefresh() async {
    await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.refreshInvocation());
  }

  Future<String?> _resolveWordAudio(String expression, String reading) async {
    final appModel = ref.read(appProvider);
    final WordAudioResolver resolver = WordAudioResolver(
      queryLocalAudio: (expression, reading) async {
        try {
          return await TtsChannel.instance
              .queryLocalAudio(expression, reading)
              .timeout(const Duration(milliseconds: 500));
        } on TimeoutException {
          return null;
        }
      },
      queryLocalAudioByDbIndex: (expression, reading, dbIndex) async {
        try {
          return await TtsChannel.instance
              .queryLocalAudio(expression, reading, dbIndex: dbIndex)
              .timeout(const Duration(milliseconds: 500));
        } on TimeoutException {
          return null;
        }
      },
      extractLocalAudio: TtsChannel.instance.extractLocalAudio,
      queryRemoteAudio: (expression, reading) => appModel.lookupRemoteAudio(
        expression,
        reading,
      ),
    );
    return resolver.resolveConfigured(
      expression: expression,
      reading: reading,
      sources: appModel.audioSourceConfigs,
    );
  }

  // No dispose() override that disposes _controller here.
  //
  // The InAppWebView widget owns its InAppWebViewController and disposes it
  // during its OWN unmount. Since build() returns InAppWebView directly, that
  // widget is a child element of this State, and Flutter unmounts children
  // before their parent — so the controller is already disposed by the time
  // this State would dispose. Calling _controller!.dispose() here was a double
  // dispose: a harmless no-op on Android/iOS, but a hard FlutterError on the
  // Windows fork, whose disposeChannel() asserts the channel isn't already
  // disposed ("WindowsInAppWebViewController was used after being disposed").
  // Let the widget own the controller lifecycle on every platform.

  @override
  void didUpdateWidget(DictionaryPopupWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _pushResults();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-push the theme CSS when the app theme changes while the popup is open
    // (light/dark toggle or seed-colour change rebuilds the inherited Theme).
    // Without this the WebView keeps the colours captured when results were
    // last rendered. CSS variables apply live to the existing DOM, so we only
    // re-inject the variables — no entry re-render. The string compare dedupes
    // unrelated dependency changes (MediaQuery, locale, …).
    if (!_ready || _controller == null) return;
    unawaited(_pushInstantScrollPreference());
    final String themeVarsJs = _themeVariablesJs();
    if (themeVarsJs == _lastThemeVarsJs) return;
    _lastThemeVarsJs = themeVarsJs;
    _controller!.evaluateJavascript(source: themeVarsJs);
  }

  Future<void> _pushInstantScrollPreference() async {
    if (_controller == null || !mounted) return;
    final bool enabled = ref.read(appProvider).popupInstantScroll;
    await _controller!.evaluateJavascript(
      source: ReaderCaretScripts.instantScrollInvocation(enabled),
    );
  }

  /// JS that pushes the theme-derived CSS custom properties + `data-theme`
  /// onto the popup document. Kept separate from entry rendering so it can be
  /// re-evaluated on a theme switch without rebuilding the result list.
  String _themeVariablesJs() {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final ColorScheme scheme = theme.colorScheme;
    String cssRgb(Color c) => 'rgb(${(c.r * 255.0).round().clamp(0, 255)}, '
        '${(c.g * 255.0).round().clamp(0, 255)}, '
        '${(c.b * 255.0).round().clamp(0, 255)})';
    final Color primary = scheme.primary;
    final String primaryRgba =
        'rgba(${(primary.r * 255.0).round().clamp(0, 255)}, '
        '${(primary.g * 255.0).round().clamp(0, 255)}, '
        '${(primary.b * 255.0).round().clamp(0, 255)}, 0.35)';
    final String textRgba = cssRgb(scheme.onSurface);
    final Color bgColor =
        ref.read(appProvider).overrideDictionaryColor ?? scheme.surface;
    final String bgRgb = cssRgb(bgColor);
    return '''
      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      document.documentElement.style.setProperty('--hoshi-primary-highlight', '$primaryRgba');
      document.documentElement.style.setProperty('--text-color', '$textRgba');
      document.documentElement.style.setProperty('--background-color', '$bgRgb');
      document.documentElement.style.setProperty('--md-surface-container', '${cssRgb(scheme.surfaceContainer)}');
      document.documentElement.style.setProperty('--md-surface-container-high', '${cssRgb(scheme.surfaceContainerHigh)}');
      document.documentElement.style.setProperty('--md-outline-variant', '${cssRgb(scheme.outlineVariant)}');
      document.documentElement.style.setProperty('--md-on-surface-variant', '${cssRgb(scheme.onSurfaceVariant)}');
      document.documentElement.style.setProperty('--md-primary', '${cssRgb(scheme.primary)}');
''';
  }

  void _pushResults() {
    if (_controller == null || !_ready) return;
    if (widget.result.entries.isEmpty) return;

    final bool isLoadMore = _lastSearchTerm == widget.result.searchTerm &&
        widget.result.entries.length > _lastEntryCount;
    _lastSearchTerm = widget.result.searchTerm;
    _lastEntryCount = widget.result.entries.length;

    final swJson = Stopwatch()..start();
    final String entriesJson;
    if (widget.result.popupJson != null) {
      entriesJson = widget.result.popupJson!;
      swJson.stop();
      debugPrint(
          '[dict-perf] popupJson (pre-built): ${swJson.elapsedMilliseconds}ms len=${entriesJson.length} loadMore=$isLoadMore');
    } else {
      entriesJson = buildLookupEntriesJson(widget.result);
      swJson.stop();
      debugPrint(
          '[dict-perf] buildLookupEntriesJson (fallback): ${swJson.elapsedMilliseconds}ms len=${entriesJson.length} loadMore=$isLoadMore');
    }

    final stylesJson = _getStylesJson();

    final appModel = ref.read(appProvider);
    // 内容缩放：跟随「词典字号」与「界面大小」。盒子尺寸在 Dart 侧已乘 appUiScale
    // （base_source_page / dictionary_page_mixin），这里把内容也等比放大，二者一致。
    final double popupZoom = popupContentZoom(
      appUiScale: appModel.appUiScale,
      dictionaryFontSize: appModel.dictionaryFontSize,
    );
    final deduplicatePitch = appModel.deduplicatePitchAccents;
    final harmonicFreq = appModel.harmonicFrequency;
    final collapseDict = appModel.collapseDictionaries;
    final showExprTags = appModel.showExpressionTags;
    final popupInstantScroll = appModel.popupInstantScroll;
    final audioSourcesJson = jsonEncode(appModel.enabledAudioSources);

    // MD3 tonal roles + base colours injected so the WebView result surfaces
    // follow the app's ColorScheme (dark mode / dynamic color / user theme)
    // instead of the hardcoded grey/green fallbacks baked into popup.css.
    // Shared with the live theme-switch path in didChangeDependencies.
    final String themeVarsJs = _themeVariablesJs();
    _lastThemeVarsJs = themeVarsJs;

    final bool needsScrollCheck = widget.onScrolledToBottom != null;
    final String beforeRenderJs = isLoadMore
        ? 'window.updatePopupIncremental();'
        : '''
          window.__hoshiResetPopupScroll();
          window.renderPopup();
        ''';
    final swInject = Stopwatch()..start();
    _controller!.evaluateJavascript(source: '''
      $themeVarsJs
      document.documentElement.style.zoom = '${popupZoom.toStringAsFixed(4)}';
      ${ReaderCaretScripts.instantScrollInvocation(popupInstantScroll)};
      window.__hoshiResetPopupScroll = function() {
        window.scrollTo(0, 0);
        document.documentElement.scrollTop = 0;
        document.body.scrollTop = 0;
      };
      window.audioSources = $audioSourcesJson;
      window.needsAudio = true;
      // 启用制卡时词典媒体（gaiji 外字）嵌入：popup.js 据此把外字渲染成
      // <img src="hoshi_dict_N.ext"> 并登记到 dictionaryMedia 负载，制卡处理器
      // (mineEntry handler) 再 writeDictionaryMediaCache 落盘供 repo 嵌进卡片。
      // 此前该 flag 全代码库从未注入→恒 falsy→外字恒退化成 alt 文本（明鏡义项序号
      // 显示成烂 alt「3分の2」）。
      window.embedMedia = true;
      window.deduplicatePitchAccents = $deduplicatePitch;
      window.harmonicFrequency = $harmonicFreq;
      window.showExpressionTags = $showExprTags;
      window.collapseDictionaries = $collapseDict;
      window.collapsedDictionaryNames = ${jsonEncode(appModel.dictionaries.where((d) => d.isCollapsed(appModel.targetLanguage)).map((d) => d.name).toList())};
      try { window.lookupEntries = $entriesJson; } catch(e) {
        console.error('[popup] lookupEntries parse error', e);
        window.lookupEntries = [];
      }
      window.dictionaryStyles = $stylesJson;
      window.globalDictCSS = ${jsonEncode(appModel.globalDictCSS)};
      window.customDictCSS = ${jsonEncode(appModel.customDictCSS)};
      $beforeRenderJs
      ${needsScrollCheck ? _scrollCheckJs : ""}
    ''').then((_) {
      swInject.stop();
      debugPrint(
          '[dict-perf] evaluateJavascript: ${swInject.elapsedMilliseconds}ms');
    });
  }

  static String _colorToHex(Color c) {
    final int r = (c.r * 255).round().clamp(0, 255);
    final int g = (c.g * 255).round().clamp(0, 255);
    final int b = (c.b * 255).round().clamp(0, 255);
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  // NavigateToString() uses about:blank origin — relative URLs can't resolve.
  // Read popup assets from disk once, embed inline in the HTML string.
  static String? _winCss;
  static String? _winDictMediaJs;
  static String? _winSelectionJs;
  static String? _winPopupJs;
  static bool _winAssetsLoadFailed = false;

  static void _ensureWindowsAssetsLoaded() {
    if (_winCss != null || _winAssetsLoadFailed) return;
    try {
      _winCss = _readPopupAsset('popup.css');
      _winDictMediaJs = _readPopupAsset('dict-media.js');
      _winSelectionJs = _readPopupAsset('selection.js');
      _winPopupJs = _readPopupAsset('popup.js');
    } catch (e, stack) {
      _winAssetsLoadFailed = true;
      debugPrint('[PopupWebView] Windows asset inlining failed, '
          'falling back to file:// URL loading: $e');
      ErrorLogService.instance
          .log('PopupWebView._ensureWindowsAssetsLoaded', e, stack);
    }
  }

  static String _readPopupAsset(String name) {
    final content = File(
      Uri.parse(webViewAssetUrl('assets/popup/$name')).toFilePath(),
    ).readAsStringSync();
    return content.replaceAll('</script', r'<\/script');
  }

  @override
  Widget build(BuildContext context) {
    // 不变式（根因守卫，BUG-039/054 同因）：词典 WebView 必须在「净缩放=1」的原生
    // 密度空间里渲染。全局「界面大小」用 FittedBox 把整棵树当一张画布拉伸，WebView
    // 是平台视图纹理、被拉大必糊；唯一干净解法是让它永远在原生密度渲染（内容大小走
    // WebView 自带字号），即必须处在 HibikiAppUiScaleNeutralizer 之下。
    // of()==defaultScale 同时覆盖「全局未缩放」与「已被中和器中和」两种合法情形；
    // 唯一会触发的是「被全局缩放且未中和」——正是发糊的精确条件。任何新增词典
    // WebView 表面若忘了套中和器，会在此 debug/集成测试里立刻炸，而非等用户撞糊。
    final double appUiScale = HibikiAppUiScale.of(context);
    assert(
      appUiScale == HibikiAppUiScale.defaultScale,
      'DictionaryPopupWebView 必须渲染在 HibikiAppUiScaleNeutralizer 之下'
      '（净缩放=1），否则会被全局界面缩放的 FittedBox 拉糊。'
      '当前 scale=$appUiScale。'
      '修法：把承载本 WebView 及其同坐标系弹窗的整块区域用 '
      'HibikiAppUiScaleNeutralizer 包裹（参见 reader_hibiki_source / '
      'home_dictionary_page / popup_dictionary_page）。',
    );
    final t = Translations.of(context);
    final appModel = ref.read(appProvider);
    final Color bgColor = appModel.overrideDictionaryColor ??
        Theme.of(context).colorScheme.surface;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final String bgHex = _colorToHex(bgColor);
    final String themeAttr = isDark ? 'dark' : 'light';

    InAppWebViewInitialData? winData;
    if (isWindowsPlatform) {
      _ensureWindowsAssetsLoaded();
      if (_winCss != null) {
        winData = InAppWebViewInitialData(
          data: '<!DOCTYPE html>'
              '<html data-theme="$themeAttr" style="--background-color:$bgHex">'
              '<head>'
              '<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">'
              '<style>${_winCss!.replaceAll('</style', r'<\/style')}</style>'
              '<script>$_winDictMediaJs</script>'
              '<script>$_winSelectionJs</script>'
              '<script>$_winPopupJs</script>'
              '</head>'
              '<body>'
              '<div id="entries-container"></div>'
              '<div class="overlay">'
              '<div class="overlay-close" onclick="closeOverlay()">×</div>'
              '<div class="overlay-content"></div>'
              '</div>'
              '</body></html>',
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }
    }

    return InAppWebView(
      initialData: winData,
      initialUrlRequest: winData != null
          ? null
          : URLRequest(
              url: WebUri(webViewAssetUrl('assets/popup/popup.html')),
            ),
      contextMenu: ContextMenu(
        settings: ContextMenuSettings(
          hideDefaultSystemContextMenuItems: false,
        ),
        menuItems: [
          ContextMenuItem(
            id: 1,
            title: t.search,
            action: () async {
              final text = await _controller?.getSelectedText();
              if (text != null && text.isNotEmpty) {
                widget.onTextSelected?.call(text, Rect.zero);
              }
            },
          ),
        ],
      ),
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<LongPressGestureRecognizer>(() => LongPressGestureRecognizer()),
        Factory<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer()),
      },
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        supportZoom: false,
        horizontalScrollBarEnabled: false,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        useShouldInterceptRequest: true,
        resourceCustomSchemes: dictionaryMediaCustomSchemes,
      ),
      shouldInterceptRequest: (controller, request) async {
        return dictionaryMediaWebResourceResponse(request.url);
      },
      onWebViewCreated: (controller) {
        _controller = controller;

        controller.addJavaScriptHandler(
          handlerName: 'tapOutside',
          callback: (_) {
            widget.onTapOutside?.call();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'scrolledToBottom',
          callback: (_) {
            widget.onScrolledToBottom?.call();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'topPullReleased',
          callback: (_) {
            widget.onTopPullReleased?.call();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'popupRendered',
          callback: (_) {
            widget.onRendered?.call();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'mineEntry',
          callback: (args) async {
            if (args.isNotEmpty &&
                args[0] is Map &&
                widget.onMineEntry != null) {
              final fields = Map<String, String>.from(
                (args[0] as Map)
                    .map((k, v) => MapEntry(k.toString(), v.toString())),
              );
              // 落盘词典媒体（gaiji）字节供 repo 嵌进卡片；必须在 onMineEntry
              // （→repo.mineEntry 读缓存）之前完成。空/无媒体时内部直接返回。
              await writeDictionaryMediaCache(fields['dictionaryMedia'] ?? '');
              return widget.onMineEntry!(fields);
            }
            return false;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'duplicateCheck',
          callback: (args) async {
            if (args.isNotEmpty &&
                args[0] is Map &&
                widget.onDuplicateCheck != null) {
              final data = args[0] as Map;
              final expression = data['expression']?.toString() ?? '';
              final reading = data['reading']?.toString() ?? '';
              if (expression.isEmpty) return false;
              return widget.onDuplicateCheck!(expression, reading);
            }
            return false;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'favoriteEntry',
          callback: (args) async {
            if (args.isNotEmpty &&
                args[0] is Map &&
                widget.onFavoriteEntry != null) {
              final fields = Map<String, String>.from(
                (args[0] as Map)
                    .map((k, v) => MapEntry(k.toString(), v.toString())),
              );
              if ((fields['expression'] ?? '').isEmpty) return false;
              return widget.onFavoriteEntry!(fields);
            }
            return false;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'favoriteCheck',
          callback: (args) async {
            if (args.isNotEmpty &&
                args[0] is Map &&
                widget.onFavoriteCheck != null) {
              final data = args[0] as Map;
              final expression = data['expression']?.toString() ?? '';
              final reading = data['reading']?.toString() ?? '';
              if (expression.isEmpty) return false;
              return widget.onFavoriteCheck!(expression, reading);
            }
            return false;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'textSelected',
          callback: (args) async {
            if (args.isNotEmpty && args[0] is String) {
              final text = args[0] as String;
              if (text.isNotEmpty) {
                Rect localRect = Rect.zero;
                if (args.length > 1 && args[1] is Map) {
                  final r = args[1] as Map;
                  localRect = Rect.fromLTWH(
                    (r['x'] as num?)?.toDouble() ?? 0,
                    (r['y'] as num?)?.toDouble() ?? 0,
                    (r['width'] as num?)?.toDouble() ?? 1,
                    (r['height'] as num?)?.toDouble() ?? 1,
                  );
                }
                widget.onTextSelected?.call(text, localRect);
              }
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'openLink',
          callback: (args) async {
            if (args.isNotEmpty) {
              await _openExternalLink(args[0].toString());
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onLinkClick',
          callback: (args) {
            if (args.isNotEmpty) {
              final text = args[0].toString();
              if (text.isNotEmpty) {
                Rect localRect = Rect.zero;
                if (args.length > 1 && args[1] is Map) {
                  final r = args[1] as Map;
                  localRect = Rect.fromLTWH(
                    (r['x'] as num?)?.toDouble() ?? 0,
                    (r['y'] as num?)?.toDouble() ?? 0,
                    (r['width'] as num?)?.toDouble() ?? 1,
                    (r['height'] as num?)?.toDouble() ?? 1,
                  );
                }
                widget.onLinkClick?.call(text, localRect);
              }
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'queryLocalAudio',
          callback: (args) async {
            if (args.isEmpty || args[0] is! Map) return null;
            final data = args[0] as Map;
            final expression = data['expression']?.toString() ?? '';
            final reading = data['reading']?.toString() ?? '';
            if (expression.isEmpty) return null;
            return _resolveWordAudio(expression, reading);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'resolveWordAudio',
          callback: (args) async {
            if (args.isEmpty || args[0] is! Map) return null;
            final data = args[0] as Map;
            final expression = data['expression']?.toString() ?? '';
            final reading = data['reading']?.toString() ?? '';
            if (expression.isEmpty) return null;
            return _resolveWordAudio(expression, reading);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'playWordAudio',
          callback: (args) async {
            String url = '';
            if (args.isNotEmpty && args[0] is Map) {
              final data = args[0] as Map;
              url = data['url']?.toString() ?? '';
            }
            // Plays remote URLs and local file paths uniformly, including
            // Windows drive-letter paths (BUG-046).
            return TtsChannel.instance.playAudioRef(
              url,
              volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
            );
          },
        );
      },
      onLoadStop: (controller, url) {
        _ready = true;
        // Inject the same char caret as the reader (selection.js, a head script,
        // has already defined window.hoshiSelection by load-stop). It stays
        // dormant until the reader hands it the cursor on lookup.
        controller.evaluateJavascript(source: _topPullReleaseJs);
        controller
            .evaluateJavascript(source: ReaderCaretScripts.source())
            .then((_) {
          if (!mounted) return;
          unawaited(_pushInstantScrollPreference());
          _pushResults();
        });
      },
      onConsoleMessage: (controller, consoleMessage) {
        final msg = consoleMessage.message;
        debugPrint('[PopupWebView] $msg');
        if (msg.startsWith('[LONGPRESS]')) {
          ErrorLogService.instance.log('PopupLongPress', msg);
        } else if (msg.startsWith('[RENDER_CONTENT]') ||
            msg.startsWith('[RICHTEXT]') ||
            msg.startsWith('[GLOSS_SECTION]') ||
            msg.startsWith('[RICHTEXT_HTML]')) {
          ErrorLogService.instance.log('PopupDebug', msg);
        }
      },
      onLoadResourceWithCustomScheme: (controller, request) async {
        return dictionaryMediaCustomSchemeResponse(request.url);
      },
    );
  }

  static String? _cachedStylesJson;
  static Map<String, String>? _cachedStylesRef;

  // _rebuildStylesCache() always assigns a new Map, so identity change == content change.
  static String _getStylesJson() {
    final Map<String, String> styles = HoshiDicts.dictionaryStyles;
    if (!identical(styles, _cachedStylesRef)) {
      _cachedStylesJson = jsonEncode(styles);
      _cachedStylesRef = styles;
    }
    return _cachedStylesJson!;
  }

  static String buildLookupEntriesJson(DictionarySearchResult result) {
    final List<DictionaryEntry> entries = result.entries;
    if (entries.isEmpty) return '[]';

    final List<String> groupKeys = [];
    final Map<String, Map<String, dynamic>> groups = {};
    final Map<String, Set<String>> seenFrequencies = {};
    final Map<String, Set<String>> seenPitches = {};
    final Map<
        String,
        List<
            ({
              String dictionary,
              String contentJson,
              String defTags,
              String termTags,
            })>> rawGlossaries = {};

    for (final entry in entries) {
      final key = '${entry.word}\n${entry.reading}';
      final extraData = _decodeExtra(entry);
      if (!groups.containsKey(key)) {
        groupKeys.add(key);
        groups[key] = {
          'expression': entry.word,
          'reading': entry.reading,
          'matched': extraData?['matched'] ?? entry.word,
          'deinflectionTrace': <Map<String, String>>[],
          'frequencies': <Map<String, dynamic>>[],
          'pitches': <Map<String, dynamic>>[],
        };
        seenFrequencies[key] = <String>{};
        seenPitches[key] = <String>{};
        rawGlossaries[key] = [];
      }

      _mergeLookupMetadata(
        group: groups[key]!,
        extraData: extraData,
        seenFrequencies: seenFrequencies[key]!,
        seenPitches: seenPitches[key]!,
      );

      // entry.meaning from hoshidicts FFI is valid JSON (structured content).
      // Embed raw to skip the jsonDecode + jsonEncode roundtrip.
      final String m = entry.meaning;
      final String contentJson =
          (m.isNotEmpty && (m[0] == '[' || m[0] == '{')) ? m : jsonEncode(m);

      rawGlossaries[key]!.add((
        dictionary: entry.dictionaryName,
        contentJson: contentJson,
        defTags: extraData?['definitionTags']?.toString() ?? '',
        termTags: extraData?['termTags']?.toString() ?? '',
      ));
    }

    final sb = StringBuffer('[');
    for (var i = 0; i < groupKeys.length; i++) {
      if (i > 0) sb.write(',');
      final key = groupKeys[i];
      final g = groups[key]!;
      sb.write('{"expression":');
      sb.write(jsonEncode(g['expression']));
      sb.write(',"reading":');
      sb.write(jsonEncode(g['reading']));
      sb.write(',"matched":');
      sb.write(jsonEncode(g['matched']));
      sb.write(',"rules":[],"deinflectionTrace":');
      sb.write(jsonEncode(g['deinflectionTrace']));
      sb.write(',"glossaries":[');
      final gl = rawGlossaries[key]!;
      for (var j = 0; j < gl.length; j++) {
        if (j > 0) sb.write(',');
        sb.write('{"dictionary":');
        sb.write(jsonEncode(gl[j].dictionary));
        sb.write(',"content":');
        sb.write(gl[j].contentJson);
        sb.write(',"definitionTags":');
        sb.write(jsonEncode(gl[j].defTags));
        sb.write(',"termTags":');
        sb.write(jsonEncode(gl[j].termTags));
        sb.write('}');
      }
      sb.write('],"frequencies":');
      sb.write(jsonEncode(g['frequencies']));
      sb.write(',"pitches":');
      sb.write(jsonEncode(g['pitches']));
      sb.write('}');
    }
    sb.write(']');
    return sb.toString();
  }

  static Map<String, dynamic>? _decodeExtra(DictionaryEntry entry) {
    if (entry.extra.isEmpty) return null;
    try {
      return jsonDecode(entry.extra) as Map<String, dynamic>;
    } catch (e, stack) {
      ErrorLogService.instance.log('DictPopupWebview.extraData', e, stack);
      return null;
    }
  }

  static void _mergeLookupMetadata({
    required Map<String, dynamic> group,
    required Map<String, dynamic>? extraData,
    required Set<String> seenFrequencies,
    required Set<String> seenPitches,
  }) {
    if (extraData == null) return;

    final matched = extraData['matched'] as String?;
    if (matched != null &&
        matched.isNotEmpty &&
        group['matched'] == group['expression']) {
      group['matched'] = matched;
    }

    final trace = group['deinflectionTrace'] as List<Map<String, String>>;
    if (trace.isEmpty && extraData.containsKey('deinflected')) {
      final traceMatched = matched ?? '';
      final deinflected = extraData['deinflected'] as String? ?? '';
      if (traceMatched != deinflected && deinflected.isNotEmpty) {
        trace.add({'name': '$traceMatched → $deinflected', 'description': ''});
      }
    }

    _appendUniqueMetadata(
      target: group['frequencies'] as List<Map<String, dynamic>>,
      values: _convertFrequencies(extraData),
      seen: seenFrequencies,
    );
    _appendUniqueMetadata(
      target: group['pitches'] as List<Map<String, dynamic>>,
      values: _convertPitches(extraData),
      seen: seenPitches,
    );
  }

  static void _appendUniqueMetadata({
    required List<Map<String, dynamic>> target,
    required List<Map<String, dynamic>> values,
    required Set<String> seen,
  }) {
    for (final value in values) {
      final key = jsonEncode(value);
      if (seen.add(key)) {
        target.add(value);
      }
    }
  }

  static List<Map<String, dynamic>> _convertFrequencies(
      Map<String, dynamic>? extraData) {
    if (extraData == null || !extraData.containsKey('frequencies')) return [];
    final freqs = extraData['frequencies'] as List<dynamic>? ?? [];
    return freqs.map((f) {
      final values = f['values'] as List<dynamic>? ?? [];
      return {
        'dictionary': f['dictName'] ?? '',
        'frequencies': values
            .map((v) => {
                  'value': v['value'] ?? 0,
                  'displayValue': v['display']?.toString() ?? '',
                })
            .toList(),
      };
    }).toList();
  }

  static List<Map<String, dynamic>> _convertPitches(
      Map<String, dynamic>? extraData) {
    if (extraData == null || !extraData.containsKey('pitches')) return [];
    final pitches = extraData['pitches'] as List<dynamic>? ?? [];
    return pitches.map((p) {
      return {
        'dictionary': p['dictName'] ?? '',
        'pitchPositions': p['positions'] ?? [],
      };
    }).toList();
  }

  static Future<void> _openExternalLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
