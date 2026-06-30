import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';
import 'package:hibiki/src/pages/implementations/popup_settings_injection.dart';
import 'package:hibiki/src/reader/popup_swipe_close_script.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// TODO-426：暂时砍掉查词弹窗的「上 N 句 / 下 N 句」句子上下文选择器（用户要求暂时移除，
/// 后面想到好方案再弄回来）。整条后端链路（[MiningSentenceDraft]、reader/video 的
/// `onSetSentenceContextToDraft`、`getSurroundingSentences`、制卡时 `composeText` /
/// `composeAudioRange` 合并）原样保留，制卡照常工作——草稿恒空时合并退化为「只制当前句」
/// （`composeText` 单句直接 trim 返回）。这里只切断 UI 入口：弹窗注入的
/// `window.sentenceDraftEnabled` 在该常量为 false 时恒 false，popup.js 据此不渲染上下文
/// 选择器与清空按钮（见 popup.js `if (window.sentenceDraftEnabled)`）。
///
/// 将来恢复：把本常量改回 true 即可——回调链、JS 处理器、i18n 注入都还在，零重连。
const bool kSentenceContextPickerEnabled = false;

/// TODO-270 D：制卡（mineEntry）回传给弹窗 JS 的结构化结果。
///
/// [ankiConnect] 沿用旧的 `Future<bool>` 字段名，但现在作为「制卡成功，可立即
/// 刷新 Anki 真实状态」信号；false 表示失败/重复/未配置/不确定，popup.js 不再安排
/// 延时 duplicateCheck 把失败后验改成成功。新增 [noteId] 带回后端 note id（仅
/// AnkiConnect 成功制卡时非空），供 popup.js 把刚制的这张标记为「最新可改」第三态，
/// 再点 ✓ 时按 id 走 `updateEntry` 覆盖而非新建。AnkiDroid 恒 `null` → 永远进不了
/// 第三态（优雅降级）。失败/重复/未配置时 [noteId] 为 `null`。
class MinePopupResult {
  const MinePopupResult({this.ankiConnect = false, this.noteId});

  /// 旧 `isAnkiConnect` 语义：true 表示制卡后可同步刷新 ✓ 状态。
  final bool ankiConnect;

  /// 后端返回的 note id；仅 AnkiConnect 成功制卡时非空。
  final int? noteId;

  /// 序列化成 JS 可读的 Map（经 inappwebview callHandler 回传）。
  Map<String, Object?> toJson() => <String, Object?>{
        'ankiConnect': ankiConnect,
        'noteId': noteId,
      };
}

/// TODO-896 症状②：Windows 桌面右键 Flutter 上下文菜单的动作枚举（替代被禁用的
/// WebView2 原生菜单）。两项：查词（平移自原 WebView2 自定义项）+ 复制（自补，BUG-402）。
enum _PopupContextMenuAction { search, copy }

class DictionaryPopupWebView extends ConsumerStatefulWidget {
  const DictionaryPopupWebView({
    required this.result,
    super.key,
    this.hasChildPopup = false,
    this.onTextSelected,
    this.onLinkClick,
    this.onTapOutside,
    this.onMineEntry,
    this.onUpdateEntry,
    this.onDuplicateCheck,
    this.onOverwriteTargetNoteId,
    this.onFavoriteEntry,
    this.onFavoriteCheck,
    this.onAppendSentence,
    this.onSetSentenceContext,
    this.onClearSentenceDraft,
    this.onScrolledToBottom,
    this.onTopPullReleased,
    this.onRendered,
    this.onRenderError,
  });

  final DictionarySearchResult result;

  /// TODO-869：本层弹窗是否有子（后代）弹窗。注入 `window.__hasChildPopup`，让
  /// popup.js 在点卡片本体留白时据此决定是否发 `tapOutside`（有子层才关后代，叶子层
  /// 不发，保持 TODO-859）。宿主按 `index < entries.length - 1` 派生传入。
  final bool hasChildPopup;
  final void Function(String text, Rect localRect)? onTextSelected;
  final void Function(String query, Rect localRect)? onLinkClick;
  final VoidCallback? onTapOutside;
  final Future<MinePopupResult> Function(Map<String, String> fields)?
      onMineEntry;

  /// TODO-270 D：覆盖「最新制的那张卡」。[noteId] 是要覆盖的卡片 id，[fields] 是新
  /// 内容。返回 [MinePopupResult]（成功时带回同一 [noteId]，保持 ✓ 第三态）。
  final Future<MinePopupResult> Function(
      int noteId, Map<String, String> fields)? onUpdateEntry;
  final Future<bool> Function(String expression, String reading)?
      onDuplicateCheck;

  /// TODO-614：覆写范围=「全部」时，按与查重同一条件反查一张可覆写的已存在 note id
  /// （多张取最近一张），供 popup.js 把更早的卡也标成「最新可改」✓↩ 态。范围为默认
  /// latest 或后端拿不到 id 时返回 `null` → 弹窗维持旧两态行为（Never break userspace）。
  final Future<int?> Function(String expression, String reading)?
      onOverwriteTargetNoteId;

  /// 切换收藏：返回切换后的新状态（true=已收藏）。供弹窗「☆/★」按钮回调。
  final Future<bool> Function(Map<String, String> fields)? onFavoriteEntry;

  /// 查询某词条当前是否已收藏，用于按钮初始 ☆/★ 状态。
  final Future<bool> Function(String expression, String reading)?
      onFavoriteCheck;

  /// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：把当前正查的这一句追加进会话级
  /// 制卡草稿缓冲。popup 点「+句」按钮经 `appendSentence` JS 处理器触发本回调；宿主
  /// 把当前句（+句子音频区间）推入草稿，并返回草稿现累积的句数（含本句）。返回值给
  /// popup 更新「已攒 N 句」角标。非空才在 popup 渲染「+句」按钮（书籍/有声书启用；
  /// 视频 E 后续复用同一入口）。
  final Future<int> Function()? onAppendSentence;

  /// TODO-393「上 N 句 / 下 N 句」上下文选择：popup 点「上 N 句 / 下 N 句」经
  /// `setSentenceContext` JS 处理器触发本回调，[prevCount]/[nextCount] 是当前句之前/
  /// 之后想纳入制卡的句数。宿主解析出那些上下文句（+各自音频区间）**整体替换**草稿，
  /// 返回上下文句总数（上 N + 下 N），供 popup 更新角标。非空才在 popup 渲染上下文
  /// 选择器（与 [onAppendSentence] 同生命周期；reader/视频启用）。
  final Future<int> Function(int prevCount, int nextCount)?
      onSetSentenceContext;

  /// TODO-382「+句」可撤销：popup 点「清空已加句子」经 `clearSentenceDraft` JS
  /// 处理器触发本回调，宿主清空草稿并回传清空后句数（恒 0），popup 据此把所有「+句」
  /// 角标归零。非空才在 popup 渲染清空入口（与 [onAppendSentence] 同生命周期）。
  final Future<int> Function()? onClearSentenceDraft;
  final VoidCallback? onScrolledToBottom;
  final VoidCallback? onTopPullReleased;

  /// Fired after the popup content finishes rendering (the `popupRendered` JS
  /// handler). Used by the reader to hand the char-level cursor to this popup.
  final VoidCallback? onRendered;

  /// TODO-058 fail-safe：主框架加载失败（`onReceivedError`）时触发。挂起到
  /// `popupRendered` 才显示的冷层若加载失败，`popupRendered` 永不会发；宿主据此
  /// 立即把该层翻可见（加载失败也显示空壳，至少不卡死「点查词什么都不出」）。
  final VoidCallback? onRenderError;

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

  Future<T> _guardJsBridge<T>(
    String logTag,
    T fallback,
    ErrorLogService errorLogService,
    FutureOr<T> Function() callback,
  ) async {
    try {
      return await callback();
    } catch (e, stack) {
      errorLogService.log(logTag, e, stack);
      return fallback;
    }
  }

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

  // TODO-854 M1a-2：下滑关闭弹窗的注入 JS 收口到 kPopupTopPullReleaseJs（单一真相，
  // 桌面 in-app 弹窗与 Windows 全局查词覆盖窗共用）。touch + pointer/mouse 两套识别，
  // 解决桌面 WebView2 不触发 touch 导致下滑关闭失效。
  static const String _topPullReleaseJs = kPopupTopPullReleaseJs;

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

  /// Jump the popup caret to the next/previous dictionary section header
  /// (Yomitan-style "go to dictionary"). [forward] true jumps to the dictionary
  /// below the cursor, false above. Returns 'moved' when a header was reached or
  /// 'blocked' when there is no further dictionary (single-dictionary results or
  /// already at the last/first section).
  Future<String> caretJumpDict(bool forward) async {
    final Object? raw = await _controller?.evaluateJavascript(
        source: ReaderCaretScripts.jumpDictInvocation(forward));
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

  Future<void> mineFirstVisibleEntry() async {
    await _controller?.evaluateJavascript(
      source: 'window.hoshiPopupMineFirstEntry'
          ' ? window.hoshiPopupMineFirstEntry() : false',
    );
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
    // TODO-869：独立比较，不搭 result 便车——子弹窗增减时 result 可能没变（卡片内容
    // 不变），但 hasChildPopup 翻转必须重新注入，否则父窗点卡片关不掉刚 push 的子窗。
    if (oldWidget.hasChildPopup != widget.hasChildPopup) {
      _setHasChildPopupJs(widget.hasChildPopup);
    }
  }

  /// TODO-869：把本层是否有子弹窗注入 WebView 的 `window.__hasChildPopup`。门控与
  /// [_pushResults] 同步（controller 就绪且页面 loadStop 后才下发），未就绪时由
  /// onLoadStop 旁的种子调用补发当前值。
  void _setHasChildPopupJs(bool hasChild) {
    if (_controller == null || !_ready) return;
    _controller!
        .evaluateJavascript(source: 'window.__hasChildPopup = $hasChild;');
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
    final appModel = ref.read(appProvider);
    final Color bgColor = appModel.overrideDictionaryColor ?? scheme.surface;
    final String bgRgb = cssRgb(bgColor);
    // TODO-776: drive the per-row dictionary-count grid (experimental). Injected
    // alongside the theme vars so a live theme switch re-applies it; the popup
    // CSS falls back to 1 when the property is absent (untouched default).
    final int dictColumns = appModel.popupDictionaryColumns;
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
      document.documentElement.style.setProperty('--dict-columns', '$dictColumns');
''';
  }

  void _pushResults() {
    if (_controller == null || !_ready) return;

    final bool isLoadMore = _lastSearchTerm == widget.result.searchTerm &&
        widget.result.entries.length > _lastEntryCount;
    _lastSearchTerm = widget.result.searchTerm;
    _lastEntryCount = widget.result.entries.length;

    // TODO-895: entries / kanji / styles serialization now lives inside the single
    // source of truth buildPopupSettingsJs (shared with the app-outside window), so
    // _pushResults no longer pre-builds them here.

    final appModel = ref.read(appProvider);
    // TODO-895: the SHARED settings body (theme vars + dictionary font + content
    // zoom + every window.* flag, incl. autoExpandDictionaries) is produced by the
    // single source of truth buildPopupSettingsJs — the SAME builder the app-outside
    // global-lookup window uses (options.globalLookup:false here). The in-app-only
    // wiring (instant-scroll pref, __hoshiResetPopupScroll hook, sentence-context
    // i18n labels, load-more vs scroll-reset beforeRenderJs, scroll-check) layers
    // around it below. _lastThemeVarsJs still tracks the in-app theme-vars string
    // for the live theme-switch dedup in didChangeDependencies.
    final String sharedSettingsJs = buildPopupSettingsJs(
      appModel: appModel,
      theme: Theme.of(context),
      result: widget.result,
      options: PopupSettingsOptions(
        sentenceDraftEnabled: kSentenceContextPickerEnabled &&
            widget.onSetSentenceContext != null,
      ),
    );
    _lastThemeVarsJs = _themeVariablesJs();
    final bool popupInstantScroll = appModel.popupInstantScroll;

    final bool needsScrollCheck = widget.onScrolledToBottom != null;
    final String beforeRenderJs = isLoadMore
        ? 'window.updatePopupIncremental();'
        : '''
          window.__hoshiResetPopupScroll();
          // BUG-297 / TODO-393：换词复用常驻热槽 WebView 时只重注入 lookupEntries 不重载
          // 页面，popup.js 句子上下文镜像标量（sentenceCtxPrev/Next）不会自动归零。宿主
          // 已在换词处清空草稿（reader/video 的 _miningDraft.clear()），这里同步把 JS 镜像
          // 归零，使 renderPopup() 重建的「上 N / 下 N」选择器回到 0/0 默认态、清空按钮隐藏，
          // 与已清的草稿一致——杜绝视觉显示「已选上 2 句」但实际只制当前句的串味。
          window.resetSentenceContextMirror();
          // TODO-645 / BUG-358：词典选择（{selected-glossary}）同样一次性。换词复用热槽
          // WebView 时 selectedDictionaries 不像页面刷新那样自动归零，renderPopup 重建 DOM 后
          // 残留的 summary label 引用已失效，必须整体清空回到无选中态，否则下一张卡静默带上
          // 一个词选的词典。
          window.resetSelectedDictionaries();
          window.renderPopup();
        ''';
    final swInject = Stopwatch()..start();
    _controller!.evaluateJavascript(source: '''
      $sharedSettingsJs
      ${ReaderCaretScripts.instantScrollInvocation(popupInstantScroll)};
      window.__hoshiResetPopupScroll = function() {
        window.scrollTo(0, 0);
        document.documentElement.scrollTop = 0;
        document.body.scrollTop = 0;
      };
      // TODO-382/393：注入「上 N 句 / 下 N 句」选择器的方向标签与「清空」tooltip
      // （popup.js 无自带 i18n 机制，按钮文字硬编码；文案走宿主 i18n 注入）。仅 in-app
      // 路径需要（app 外 sentenceDraftEnabled 恒 false，不渲染选择器）。
      window.i18nAppendSentenceTooltip = ${jsonEncode(t.popup_append_sentence_tooltip)};
      window.i18nClearSentenceDraftTooltip = ${jsonEncode(t.popup_clear_sentence_draft_tooltip)};
      window.i18nContextPrevLabel = ${jsonEncode(t.popup_sentence_context_prev_label)};
      window.i18nContextNextLabel = ${jsonEncode(t.popup_sentence_context_next_label)};
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

    final Widget webView = InAppWebView(
      initialData: winData,
      initialUrlRequest: winData != null
          ? null
          : URLRequest(
              url: WebUri(webViewAssetUrl('assets/popup/popup.html')),
            ),
      contextMenu: ContextMenu(
        settings: ContextMenuSettings(
          // TODO-896 症状②：Windows 上禁掉 WebView2 的原生上下文菜单——它是独立的
          // top-level Win32 popup，按「WebView 内部未拉伸的逻辑光标坐标 + HWND 原点」
          // 定位，而用户的真实鼠标在被 FittedBox（界面大小 appUiScale）拉伸后的空间，
          // 故离 WebView 左上角越远菜单偏得越狠（用户报「跑到很远」）。改走下面
          // [_showWindowsContextMenu] 的 Flutter showMenu（BUG-261 锚点范式，吃掉缩放
          // 残差）。非 Windows 平台保持原生菜单不变（false）。
          hideDefaultSystemContextMenuItems: isWindowsPlatform,
        ),
        // 非 Windows：保留原生菜单 + 自定义「查词」项（原行为）。Windows 下原生菜单已
        // 被上面禁用，这里的 menuItems 不渲染，右键改由 [_showWindowsContextMenu] 接管。
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
      // TODO-896 症状①：WebView 在手势竞技场必须争得正文区的「水平拖」，否则
      // 用户在正文里左键拖动框选（一个水平位移序列）时，包住整张 surface 的
      // [_BodySwipeDismissDetector]（dictionary_popup_layer.dart，TODO-880 本体横拖关）
      // 会赢走横拖、累加位移过阈→误关弹窗（BUG-299 隔离被 TODO-880 重新打穿）。新增
      // [HorizontalDragGestureRecognizer] 让 WebView 吃掉正文区水平拖（转给原生选区
      // 扩展），detector 只在非 WebView 区（顶栏 / 外框留白）收到横拖关窗——TODO-880
      // 的「顶栏/留白横拖关」保留，仅正文区让位给框选。边界由「谁渲染谁吃手势」自然
      // 划定，无坐标特判。
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<LongPressGestureRecognizer>(() => LongPressGestureRecognizer()),
        Factory<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer()),
        Factory<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer()),
      },
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        supportZoom: false,
        horizontalScrollBarEnabled: false,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        useShouldInterceptRequest: true,
        resourceCustomSchemes: dictionaryMediaCustomSchemes,
        // BUG-477（BUG-468 同根，弹窗 WebView 漏修）：Windows 上压制 WebView2 原生右键
        // 菜单的唯一真值是 `disableContextMenu`→`put_AreDefaultContextMenusEnabled`；
        // 上面 `ContextMenu` 的 `hideDefaultSystemContextMenuItems` 是跨平台 API，在
        // flutter_inappwebview_windows fork 上**不接到**原生菜单开关，故弹窗里右键仍同时
        // 弹原生菜单（返回/刷新/另存为/打印/更多工具）与自定义 [_showWindowsContextMenu]
        // 的搜索/复制菜单（用户报「右键出现清空」=双菜单）。Windows 关原生菜单只留 Flutter
        // 菜单；移动端为 false 不动原生 ContextMenu（查词项），不回归。
        disableContextMenu: isWindowsPlatform,
      ),
      shouldInterceptRequest: (controller, request) async {
        return dictionaryMediaWebResourceResponse(request.url);
      },
      onWebViewCreated: (controller) {
        _controller = controller;

        controller.addJavaScriptHandler(
          handlerName: 'tapOutside',
          callback: (_) {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.tapOutside',
              null,
              ErrorLogService.instance,
              () {
                widget.onTapOutside?.call();
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'scrolledToBottom',
          callback: (_) {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.scrolledToBottom',
              null,
              ErrorLogService.instance,
              () {
                widget.onScrolledToBottom?.call();
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'topPullReleased',
          callback: (_) {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.topPullReleased',
              null,
              ErrorLogService.instance,
              () {
                widget.onTopPullReleased?.call();
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'popupRendered',
          callback: (_) {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.popupRendered',
              null,
              ErrorLogService.instance,
              () {
                widget.onRendered?.call();
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'mineEntry',
          callback: (args) async {
            // BUG-293: the mine/update bridge handlers MUST always return a
            // MinePopupResult JSON and never let an exception escape into the
            // native inappwebview JS-handler bridge. An override
            // (e.g. VideoHibikiPage._mineVideoCard) or writeDictionaryMediaCache
            // can throw during the re-mine media-capture path (ffmpeg / window
            // screenshot / WebView2 frame); an unhandled exception crossing the
            // Dart->native JS-handler boundary takes the whole process down
            // (crash). Honour the same "return, never throw" contract BUG-077
            // established for the repository layer and surface the cause
            // (BUG-089) instead of crashing.
            try {
              if (args.isNotEmpty &&
                  args[0] is Map &&
                  widget.onMineEntry != null) {
                final fields = Map<String, String>.from(
                  (args[0] as Map)
                      .map((k, v) => MapEntry(k.toString(), v.toString())),
                );
                // 落盘词典媒体（gaiji）字节供 repo 嵌进卡片；必须在 onMineEntry
                // （->repo.mineEntry 读缓存）之前完成。空/无媒体时内部直接返回。
                await writeDictionaryMediaCache(
                    fields['dictionaryMedia'] ?? '');
                final MinePopupResult result =
                    await widget.onMineEntry!(fields);
                // TODO-270 D：回传结构化结果（ankiConnect + noteId）给 popup.js，
                // 让它把刚制的这张标记为「最新可改」第三态。
                return result.toJson();
              }
            } catch (e, stack) {
              ErrorLogService.instance
                  .log('DictPopupWebview.mineEntry', e, stack);
            }
            return const MinePopupResult().toJson();
          },
        );

        // TODO-270 D：覆盖「最新制的那张卡」——popup.js 点绿 ✓ 时带 noteId+新字段
        // 调本处理器，走 repo.updateMinedNote 按 id 真实覆盖（不删旧建新、不查重）。
        controller.addJavaScriptHandler(
          handlerName: 'updateEntry',
          callback: (args) async {
            // BUG-293: same boundary contract as mineEntry above — an escaping
            // exception from the update-in-place override (re-mining the just-
            // mined word after deleting its Anki card hits this green check path)
            // must become a logged failure, not an unhandled exception across
            // the native bridge that crashes the app.
            try {
              if (args.isNotEmpty &&
                  args[0] is Map &&
                  widget.onUpdateEntry != null) {
                final data = args[0] as Map;
                final int? noteId = (data['noteId'] as num?)?.toInt();
                final fieldsRaw = data['fields'];
                if (noteId == null || fieldsRaw is! Map) {
                  return const MinePopupResult().toJson();
                }
                final fields = Map<String, String>.from(
                  fieldsRaw.map((k, v) => MapEntry(k.toString(), v.toString())),
                );
                // 与制卡同链路：先落盘词典媒体字节，再覆盖卡片（repo 从缓存读外字）。
                await writeDictionaryMediaCache(
                    fields['dictionaryMedia'] ?? '');
                final MinePopupResult result =
                    await widget.onUpdateEntry!(noteId, fields);
                return result.toJson();
              }
            } catch (e, stack) {
              ErrorLogService.instance
                  .log('DictPopupWebview.updateEntry', e, stack);
            }
            return const MinePopupResult().toJson();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'duplicateCheck',
          callback: (args) async {
            return _guardJsBridge<bool>(
              'DictPopupWebview.duplicateCheck',
              false,
              ErrorLogService.instance,
              () async {
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
          },
        );

        // TODO-614：覆写范围=「全部」时，popup.js 在 lookup-time 探测到已制卡且不是
        // 本会话最近一张时调本处理器，按与查重同一条件反查一张可覆写的已存在 note id
        // （多张取最近一张）。回 null（默认 latest / 无匹配 / 后端拿不到 id）时 popup.js
        // 不改态，维持旧两态行为。
        controller.addJavaScriptHandler(
          handlerName: 'overwriteTargetNoteId',
          callback: (args) async {
            return _guardJsBridge<int?>(
              'DictPopupWebview.overwriteTargetNoteId',
              null,
              ErrorLogService.instance,
              () async {
                if (args.isNotEmpty &&
                    args[0] is Map &&
                    widget.onOverwriteTargetNoteId != null) {
                  final data = args[0] as Map;
                  final expression = data['expression']?.toString() ?? '';
                  final reading = data['reading']?.toString() ?? '';
                  if (expression.isEmpty) return null;
                  return widget.onOverwriteTargetNoteId!(expression, reading);
                }
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'favoriteEntry',
          callback: (args) async {
            return _guardJsBridge<bool>(
              'DictPopupWebview.favoriteEntry',
              false,
              ErrorLogService.instance,
              () async {
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
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'favoriteCheck',
          callback: (args) async {
            return _guardJsBridge<bool>(
              'DictPopupWebview.favoriteCheck',
              false,
              ErrorLogService.instance,
              () async {
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
          },
        );

        // TODO-270 F/G：弹窗「+句」追加当前句到本卡草稿（乙方案）。不碰 mineEntry
        // 字段契约——只发「append 当前句」信号给宿主，宿主把当前句推进草稿并回传
        // 草稿现有句数（含本句），popup 据此更新「已攒 N 句」角标。三表面共用入口。
        // 已废弃（TODO-393 用「上 N 句 / 下 N 句」方向选择器取代单按钮逐句追加）：popup.js
        // 不再调用 appendSentence，onAppendSentence 链路成死码；保留待 TODO-393 稳定后清理。
        controller.addJavaScriptHandler(
          handlerName: 'appendSentence',
          callback: (_) async {
            return _guardJsBridge<int>(
              'DictPopupWebview.appendSentence',
              0,
              ErrorLogService.instance,
              () async {
                if (widget.onAppendSentence != null) {
                  return widget.onAppendSentence!();
                }
                return 0;
              },
            );
          },
        );

        // TODO-393：popup 点「上 N 句 / 下 N 句」把当前句前/后 N 句作上下文整体设进
        // 宿主草稿（不掺历史累积），回传上下文句总数（上 N + 下 N）供 popup 更新角标。
        controller.addJavaScriptHandler(
          handlerName: 'setSentenceContext',
          callback: (args) async {
            return _guardJsBridge<int>(
              'DictPopupWebview.setSentenceContext',
              0,
              ErrorLogService.instance,
              () async {
                if (widget.onSetSentenceContext == null) return 0;
                int prevCount = 0;
                int nextCount = 0;
                if (args.isNotEmpty && args[0] is Map) {
                  final Map<dynamic, dynamic> data = args[0] as Map;
                  prevCount = (data['prev'] as num?)?.toInt() ?? 0;
                  nextCount = (data['next'] as num?)?.toInt() ?? 0;
                }
                return widget.onSetSentenceContext!(prevCount, nextCount);
              },
            );
          },
        );

        // TODO-382「+句」可撤销：popup 点「清空已加句子」清空宿主草稿，回传清空后句数
        // （恒 0）。与 appendSentence 对称——只发「清空草稿」信号，不碰 mineEntry 字段契约。
        controller.addJavaScriptHandler(
          handlerName: 'clearSentenceDraft',
          callback: (_) async {
            return _guardJsBridge<int>(
              'DictPopupWebview.clearSentenceDraft',
              0,
              ErrorLogService.instance,
              () async {
                if (widget.onClearSentenceDraft != null) {
                  return widget.onClearSentenceDraft!();
                }
                return 0;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'textSelected',
          callback: (args) async {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.textSelected',
              null,
              ErrorLogService.instance,
              () {
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
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'openLink',
          callback: (args) async {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.openLink',
              null,
              ErrorLogService.instance,
              () async {
                if (args.isNotEmpty) {
                  await _openExternalLink(args[0].toString());
                }
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onLinkClick',
          callback: (args) async {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.onLinkClick',
              null,
              ErrorLogService.instance,
              () {
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
                return null;
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'queryLocalAudio',
          callback: (args) async {
            return _guardJsBridge<String?>(
              'DictPopupWebview.queryLocalAudio',
              null,
              ErrorLogService.instance,
              () async {
                if (args.isEmpty || args[0] is! Map) return null;
                final data = args[0] as Map;
                final expression = data['expression']?.toString() ?? '';
                final reading = data['reading']?.toString() ?? '';
                if (expression.isEmpty) return null;
                return _resolveWordAudio(expression, reading);
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'resolveWordAudio',
          callback: (args) async {
            return _guardJsBridge<String?>(
              'DictPopupWebview.resolveWordAudio',
              null,
              ErrorLogService.instance,
              () async {
                if (args.isEmpty || args[0] is! Map) return null;
                final data = args[0] as Map;
                final expression = data['expression']?.toString() ?? '';
                final reading = data['reading']?.toString() ?? '';
                if (expression.isEmpty) return null;
                return _resolveWordAudio(expression, reading);
              },
            );
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'playWordAudio',
          callback: (args) async {
            return _guardJsBridge<bool>(
              'DictPopupWebview.playWordAudio',
              false,
              ErrorLogService.instance,
              () async {
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
        );
      },
      onLoadStop: (controller, url) {
        _ready = true;
        debugPrint('[popup-perf] webview loadStop $url');
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
          // TODO-869：冷加载就绪后显式下发一次当前 hasChildPopup（默认 false 也下发，
          // 保证叶子层 __hasChildPopup 明确为 false）。
          _setHasChildPopupJs(widget.hasChildPopup);
        });
      },
      onReceivedError: (controller, request, error) {
        // TODO-058 fail-safe：主框架加载失败（弹窗 WebView 进程异常 / 资源拦截
        // 失败等）时 `popupRendered` 永不会发，挂起的冷层会永久不可见（点查词什么
        // 都不出）。这里通知宿主立即把该层翻可见（revealRendered），加载失败也至少
        // 显示空壳，不卡死。仅主框架失败触发，子资源失败不影响整体可见性。
        if (request.isForMainFrame ?? false) {
          debugPrint('[PopupWebView] onReceivedError: ${error.description} '
              'url=${request.url}');
          widget.onRenderError?.call();
        }
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

    // TODO-896 症状②：Windows 上原生 WebView2 菜单已禁（hideDefaultSystemContextMenuItems
    // = isWindowsPlatform），右键改由 Flutter 层 [showMenu] 接管，锚点经 BUG-261 范式映射到
    // appUiScale 空间。非 Windows 平台不包 GestureDetector，保持原生菜单行为不变。
    // [HitTestBehavior.translucent] 让右键之外的所有指针事件照常落到 WebView（不抢左键
    // 框选 / 滚动 / 点击）。
    if (isWindowsPlatform) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (TapDownDetails details) =>
            _showWindowsContextMenu(context, details.globalPosition),
        child: webView,
      );
    }
    return webView;
  }

  /// TODO-896 症状②：Windows 桌面右键弹 Flutter [showMenu]（替代偏移的 WebView2 原生
  /// 菜单）。锚点用 BUG-260/261 已验证范式——把右键的 [globalPosition] 沿真实渲染变换链
  /// 映射到 showMenu 所用 [Overlay] 的 [RenderBox] 坐标系（`localToGlobal(..., ancestor:
  /// overlayObject)`），界面大小（appUiScale）的 FittedBox 缩放残差被 ancestor 变换自动
  /// 吸收，菜单对准鼠标。菜单项：「查词」（平移自原 WebView2 自定义项）+「复制」（原是
  /// WebView2 原生项，禁原生后用 BUG-402 范式 `getSelectedText` + [Clipboard.setData] 自补）。
  Future<void> _showWindowsContextMenu(
      BuildContext context, Offset globalPosition) async {
    final RenderObject? overlayObject =
        Overlay.of(context).context.findRenderObject();
    if (overlayObject is! RenderBox || !overlayObject.hasSize) return;
    final Offset anchor = overlayObject.globalToLocal(globalPosition);
    final Size overlaySize = overlayObject.size;
    final RelativeRect position = RelativeRect.fromLTRB(
      anchor.dx,
      anchor.dy,
      overlaySize.width - anchor.dx,
      overlaySize.height - anchor.dy,
    );
    final t = Translations.of(context);
    final _PopupContextMenuAction? action =
        await showMenu<_PopupContextMenuAction>(
      context: context,
      position: position,
      items: <PopupMenuEntry<_PopupContextMenuAction>>[
        PopupMenuItem<_PopupContextMenuAction>(
          value: _PopupContextMenuAction.search,
          child: Text(t.search),
        ),
        PopupMenuItem<_PopupContextMenuAction>(
          value: _PopupContextMenuAction.copy,
          child: Text(t.copy),
        ),
      ],
    );
    if (action == null) return;
    final String text = (await _controller?.getSelectedText()) ?? '';
    if (text.isEmpty) return;
    switch (action) {
      case _PopupContextMenuAction.search:
        widget.onTextSelected?.call(text, Rect.zero);
      case _PopupContextMenuAction.copy:
        // BUG-402 范式：桌面 WebView2 合成模式下原生复制键转发受限，自己把选区文本写
        // 系统剪贴板。空选区上面已早退，不覆盖剪贴板已有内容。
        await Clipboard.setData(ClipboardData(text: text));
    }
  }

  static String? _cachedStylesJson;
  static Map<String, String>? _cachedStylesRef;

  // _rebuildStylesCache() always assigns a new Map, so identity change == content change.
  // TODO-895: public so the shared buildPopupSettingsJs uses the SAME cached encoding.
  static String dictionaryStylesJson() {
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
        'transcriptions': p['transcriptions'] ?? [],
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
