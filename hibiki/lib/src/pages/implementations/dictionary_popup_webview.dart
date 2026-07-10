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

/// board-1117：查词弹窗 WebView 在 Flutter 手势竞技场里挂的 [LongPressGestureRecognizer]
/// （5deeb754d 加，用途是让长按把手势让给 WebView 的原生选词把手）本来吃 Flutter 默认
/// `kLongPressTimeout`（500ms）——用户反馈「popup 里长按选中文字的等待时间太长」。
/// 这个 recognizer 只为触发原生选区，并不需要跟系统长按菜单对齐 500ms；缩短 deadline
/// 让原生选词更跟手。250ms 明显高于点按（tap 立即），不会把单击查词误判成长按，又比
/// 500ms 快一倍——与弹窗其它可调交互（滚轮 250~450ms）同量级。
const Duration kPopupNativeSelectLongPressDuration =
    Duration(milliseconds: 250);

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
    this.transparentDocumentBackground = false,
    this.onTextSelected,
    this.onLinkClick,
    this.onTapOutside,
    this.onMineEntry,
    this.onUpdateEntry,
    this.onDuplicateCheck,
    this.onOverwriteTargetNoteId,
    this.onMinedCardAction,
    this.onFavoriteEntry,
    this.onFavoriteCheck,
    this.onAppendSentence,
    this.onSetSentenceContext,
    this.onClearSentenceDraft,
    this.onScrolledToBottom,
    this.onTopPullReleased,
    this.onRendered,
    this.onRenderError,
    this.nudgeSurfaceOnRender = false,
  });

  final DictionarySearchResult result;

  /// TODO-869：本层弹窗是否有子（后代）弹窗。注入 `window.__hasChildPopup`，让
  /// popup.js 在点卡片本体留白时据此决定是否发 `tapOutside`（有子层才关后代，叶子层
  /// 不发，保持 TODO-859）。宿主按 `index < entries.length - 1` 派生传入。
  final bool hasChildPopup;

  /// TODO-1065：本弹窗宿主是「app 外 / 悬浮字幕」独立查词窗（popup_main 宿主）时置 true。
  /// 该路径的圆角卡由 Flutter [HibikiPopupSurface] 画，弹窗 WebView 跑在透明浮动窗里；
  /// 若 `<html>` documentElement 被填不透明近白的主题 surface（`--background-color`）铺满
  /// 整个 WebView 视口，就盖在 Flutter 卡片之上、浅色主题下读成整窗泛白。为 true 时给
  /// `<html>` 加 `mobile-external` class（popup.css `html.mobile-external{background:transparent}`）
  /// 令 documentElement 透明，只留 `<body>` 的主题填充（同一变量，被 Flutter 卡片裁圆角），
  /// 消除泛白。默认 false = 原 in-app 行为，桌面 global-lookup 走独立 `.global-lookup` 路径，
  /// 二者均不受影响（零回归）。
  final bool transparentDocumentBackground;
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

  /// TODO-1007/1008：点 ✓（卡已存在）时弹宿主操作选择（覆写/新增重复卡/查看·在 Anki
  /// 中打开），命中多张让用户选哪张。[fields] 是当前词条的制卡 payload（与 onMineEntry
  /// 同一份），宿主据其 expression/reading 反查全部命中卡并据用户选择执行。返回执行后
  /// 的 [MinePopupResult]（驱动 popup.js 刷新 ✓/+ 与第三态）。null 时 popup 回退到旧的
  /// 「重验 + 静默」两态行为（Never break userspace）。
  final Future<MinePopupResult> Function(Map<String, String> fields)?
      onMinedCardAction;

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

  /// TODO-1152：内容渲染完成（`popupRendered`）后是否补一次「表面重绘 nudge」。
  /// 仅用于把 WebView 撑满一块固定大区域（如 in-app 查词页的结果区，[Expanded] 全高）
  /// 的宿主：Windows 上 WebView2 内容在尺寸增大后 render 完即 idle 无 damage，宿主
  /// WGC 帧池采不到新暴露的下半区（下半屏黑）。渲染完逼一帧合成即可让 WGC 捕获完整
  /// 视口。默认 false，保持 nested 弹窗等内容自适应宿主的原行为不变（Never break
  /// userspace）。非 Windows 平台恒为 no-op（原生 WebView 正常合成）。
  final bool nudgeSurfaceOnRender;

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
  bool _refreshWhenReady = false;
  String? _lastSearchTerm;
  int _lastEntryCount = 0;
  int _renderToken = 0;

  /// 最近一次**真正发出注入**（controller 就绪、evaluateJavascript 已下发）的
  /// [DictionarySearchResult]。`!_ready` 早退分支不记录（那次没推出去）。
  /// 与 [_lastRenderedResult] 一起支撑 [refreshCurrentResult] 的去重：同一结果
  /// 不再盲目二次全量重推（此前每次查词渲染两遍、可见时刻=第二遍完成）。
  DictionarySearchResult? _lastPushedResult;

  /// 最近一次收到 `popupRendered`（render token 命中）时对应的已推结果。
  /// `identical(_lastRenderedResult, widget.result)` 即「当前结果已渲染完成，
  /// 不会再有渲染信号」——等信号的宿主必须立即按已渲染处理。
  DictionarySearchResult? _lastRenderedResult;

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

  /// TODO-1353: Ctrl+滚轮缩放查词内容时词典字号的合法区间（与注入 JS 的 wheel 监听
  /// [_zoomWheelJs] 用同一组界，两侧一致）。太小看不见、太大撑爆弹窗，故双侧夹死。
  static const double _popupZoomFontMin = 8.0;
  static const double _popupZoomFontMax = 72.0;

  /// TODO-1353: 把词典字号夹进 [_popupZoomFontMin].._popupZoomFontMax（纯函数，供守卫）。
  /// 非法（非有限 / 非正）值回退到 [_popupFontBaseline]。Ctrl+滚轮回传字号落 DB 前的
  /// 权威兜底——即便 JS 侧越界也不会写坏 `dictionaryFontSize`。
  static double clampPopupZoomFontSize(double fontSize) {
    if (!fontSize.isFinite || fontSize <= 0) return _popupFontBaseline;
    return fontSize.clamp(_popupZoomFontMin, _popupZoomFontMax).toDouble();
  }

  /// TODO-1353: 单格 Ctrl+滚轮的词典字号步进（纯函数，供守卫）。[zoomIn] 为 true（滚轮
  /// 上滚 / deltaY<0）放大一档，否则缩小一档，结果经 [clampPopupZoomFontSize] 夹紧。
  /// 与 [_zoomWheelJs] 里 `fs += (deltaY<0?1:-1)` 的语义镜像。
  static double steppedPopupZoomFontSize(double current,
      {required bool zoomIn}) {
    final double base =
        (current.isFinite && current > 0) ? current : _popupFontBaseline;
    return clampPopupZoomFontSize(base + (zoomIn ? 1.0 : -1.0));
  }

  /// TODO-1353: Ctrl+滚轮缩放查词内容的 wheel 监听（onLoadStop 装一次，幂等 guard）。
  /// 只拦 `e.ctrlKey` 的 wheel（普通滚动不受影响），preventDefault 抑制 WebView 自带的
  /// 页面缩放，读注入的 `window.__hoshiPopupFontSize` / `__hoshiPopupUiScale`（见
  /// popup_settings_injection buildPopupSettingsJs，每次注入刷新）算新字号并**就地**改
  /// documentElement.style.zoom 给即时反馈，再回调 Dart 的 `popupZoomFont` 持久化到
  /// `dictionaryFontSize`（下次开弹窗记住）。字号界与缩放界与 Dart 侧
  /// [_popupZoomFontMin]/[_popupZoomFontMax] / [popupContentZoom] 一致。
  ///
  /// TODO-1353 复诉：步进本体抽成 `window.__hoshiPopupZoomStep(dir)`——Ctrl+滚轮与
  /// 弹窗顶栏 A−/A+ 手动按钮（[zoomFontStep]，触屏没有 Ctrl+滚轮的唯一入口）共用同一
  /// 份夹紧 + 就地 zoom + 持久化路径，杜绝两处步进语义漂移。
  static const String _zoomWheelJs = '''
(function(){
  if (window.__hoshiZoomWheelInstalled) return;
  window.__hoshiZoomWheelInstalled = true;
  var MIN = 8, MAX = 72, STEP = 1;
  window.__hoshiPopupZoomStep = function(dir){
    var fs = window.__hoshiPopupFontSize;
    if (typeof fs !== 'number' || !isFinite(fs) || fs <= 0) fs = 16;
    fs += (dir > 0 ? STEP : -STEP);
    if (fs < MIN) fs = MIN;
    if (fs > MAX) fs = MAX;
    window.__hoshiPopupFontSize = fs;
    var scale = window.__hoshiPopupUiScale;
    if (typeof scale !== 'number' || !isFinite(scale) || scale <= 0) scale = 1;
    var z = scale * fs / 16;
    if (z < 0.3) z = 0.3;
    if (z > 8) z = 8;
    document.documentElement.style.zoom = z.toFixed(4);
    try { window.flutter_inappwebview.callHandler('popupZoomFont', fs); } catch (err) {}
  };
  window.addEventListener('wheel', function(e){
    if (!e.ctrlKey) return;
    e.preventDefault();
    window.__hoshiPopupZoomStep(e.deltaY < 0 ? 1 : -1);
  }, { passive: false });
})();
''';

  /// TODO-1353 复诉：弹窗顶栏 A−/A+ 手动字号步进入口（用户复诉 Ctrl+滚轮不可发现，
  /// 且 Android/iOS 触屏根本没有 Ctrl+滚轮）。直接调用注入的
  /// `window.__hoshiPopupZoomStep`，与 Ctrl+滚轮完全同一条路径：同 [8,72] 夹紧、就地改
  /// documentElement.style.zoom 即时生效不闪烁、经 `popupZoomFont` 回调持久化到
  /// `dictionaryFontSize`。WebView 未就绪（controller 为空 / 监听未装）时安全 no-op。
  void zoomFontStep({required bool zoomIn}) {
    _controller?.evaluateJavascript(
      source: 'window.__hoshiPopupZoomStep'
          ' && window.__hoshiPopupZoomStep(${zoomIn ? 1 : -1});',
    );
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

  // TODO-1152：内容渲染完成后逼一帧合成的「表面重绘 nudge」JS。put_Bounds 增大后
  // WebView2 已按新视口重排/重栅格，但内容随即 idle、compositor 不再产帧，宿主 WGC
  // 帧池（尺寸已随 setSurfaceSize 重建为全高）采不到新暴露下半区 → 下半屏黑。改 opacity
  // 到 0.9999（肉眼不可辨）触发一次全页合成，下一帧还原：这一帧 WebView2 产出 →
  // OnFrameArrived → WGC 捕获到完整视口。opacity<1 只建立层叠上下文、不为 fixed 后代
  // 建立包含块（不像 transform），故不动图片放大 .overlay 的 fixed 定位。幂等、无害。
  static const String _surfaceRepaintNudgeJs = r'''
(function(){
  try {
    var el = document.documentElement;
    if (!el) return;
    var prev = el.style.opacity;
    el.style.opacity = '0.9999';
    requestAnimationFrame(function(){
      requestAnimationFrame(function(){ el.style.opacity = prev; });
    });
  } catch (e) {}
})();
''';

  /// TODO-1152：渲染完成后（`popupRendered`）对 WebView 表面补一次重绘 nudge，逼
  /// WebView2 产出一帧让宿主 WGC 帧池捕获完整视口，消除下半屏黑。仅在
  /// [DictionaryPopupWebView.nudgeSurfaceOnRender] 且 Windows 平台执行；其余平台/宿主
  /// 恒 no-op（原生 WebView 正常合成，改动零行为影响）。
  void _nudgeSurfaceRepaint() {
    if (!isWindowsPlatform) return;
    _controller?.evaluateJavascript(source: _surfaceRepaintNudgeJs);
  }

  void highlightSelection(int charCount) {
    _controller?.evaluateJavascript(
      source:
          'window.hoshiSelection?.highlightSelection && window.hoshiSelection.highlightSelection($charCount)',
    );
  }

  void clearSelection() {
    _controller?.evaluateJavascript(
      source:
          'window.hoshiSelection?.clearSelection && window.hoshiSelection.clearSelection()',
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

  /// TODO-1325 #5 part1: move the ENTRY-level focus (the blue-triangle
  /// `.entry-current` indicator, driven by popup.js `hoshiFocusDictionaryEntryMove`)
  /// to the next/previous word entry in a multi-entry result, scrolling it into
  /// view. [forward] true → next entry below, false → previous above. Returns
  /// 'moved' when the focus advanced or 'blocked' at the first/last entry (or a
  /// single-entry / empty result). Orthogonal to the char caret — moves only the
  /// entry indicator + viewport, never the caret ring.
  Future<String> focusEntryMove(bool forward) async {
    final Object? raw = await _controller?.evaluateJavascript(
      source: 'window.hoshiFocusDictionaryEntryMove'
          " ? window.hoshiFocusDictionaryEntryMove('${forward ? 'next' : 'prev'}')"
          " : 'blocked'",
    );
    return raw?.toString() ?? 'blocked';
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
    // TODO-1065：app 外 / 悬浮字幕独立查词窗给 <html> 打透明标记（见 popup.css
    // html.mobile-external），消除 documentElement 不透明填充铺满视口的泛白。in-app
    // （transparentDocumentBackground=false）不加，桌面 global-lookup 走独立路径。
    final String docClassLine = widget.transparentDocumentBackground
        ? "document.documentElement.classList.add('mobile-external');\n"
        : '';
    return '''
      $docClassLine      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      document.documentElement.style.setProperty('--hoshi-primary-highlight', '$primaryRgba');
      document.documentElement.style.setProperty('--text-color', '$textRgba');
      document.documentElement.style.setProperty('--background-color', '$bgRgb');
      document.documentElement.style.setProperty('--md-surface-container', '${cssRgb(scheme.surfaceContainer)}');
      document.documentElement.style.setProperty('--md-surface-container-high', '${cssRgb(scheme.surfaceContainerHigh)}');
      document.documentElement.style.setProperty('--md-outline-variant', '${cssRgb(scheme.outlineVariant)}');
      document.documentElement.style.setProperty('--md-on-surface-variant', '${cssRgb(scheme.onSurfaceVariant)}');
      document.documentElement.style.setProperty('--md-primary', '${cssRgb(scheme.primary)}');
      document.documentElement.style.setProperty('--md-on-primary', '${cssRgb(scheme.onPrimary)}');
      document.documentElement.style.setProperty('--hibiki-radius-card', '${HibikiRadii.cardValue.toInt()}px');
      document.documentElement.style.setProperty('--dict-columns', '$dictColumns');
''';
  }

  void _pushResults() {
    if (_controller == null || !_ready) {
      _refreshWhenReady = true;
      return;
    }
    _refreshWhenReady = false;
    _lastPushedResult = widget.result;

    final int renderToken = ++_renderToken;
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
        // TODO-1065：app 外 / 悬浮字幕独立查词窗令 <html> 透明消除泛白（见字段 doc）。
        mobileExternal: widget.transparentDocumentBackground,
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
      window.__hibikiRenderToken = $renderToken;
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

  /// Ensures the current [widget.result] is (or will be) rendered in the WebView.
  ///
  /// BUG-523（原 BUG-480 编号）：隐藏/屏外 warm slot 的结果推送可能被漏掉（如
  /// didUpdateWidget 未触发、页面尚未 loadStop），宿主在该层翻可见后一帧调用
  /// 本方法兜底补推，避免露出空白 WebView 壳。
  ///
  /// 性能：此前这里**无条件**全量重推——每次查词渲染两遍、且第二遍的 render
  /// token 作废第一遍的 `popupRendered`，内容可见时刻被推迟到第二遍渲染完成。
  /// 现在只在当前结果确实没推出去过时才补推：
  ///
  /// 返回 `true` = 渲染信号还会到来（本次补推了，或此前的推送仍在渲染中，
  /// `popupRendered` 稍后必发）；返回 `false` = 当前结果已渲染完成、不会再有
  /// `popupRendered`——等信号撤盖板/翻可见的宿主必须立即按已渲染处理，否则会
  /// 空等到 failsafe 超时。
  bool refreshCurrentResult() {
    if (identical(_lastRenderedResult, widget.result)) {
      return false;
    }
    if (identical(_lastPushedResult, widget.result)) {
      // 已发出注入、渲染在途：popupRendered 会带当前 token 到达，别重推。
      return true;
    }
    _refreshWhenReady = true;
    _pushResults();
    return true;
  }

  static String _colorToHex(Color c) {
    final int r = (c.r * 255).round().clamp(0, 255);
    final int g = (c.g * 255).round().clamp(0, 255);
    final int b = (c.b * 255).round().clamp(0, 255);
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  // Some platform WebViews cannot reliably bootstrap popup.html as a file://
  // main frame. Read the popup assets from disk once and embed them inline.
  static String? _inlineCss;
  static String? _inlineDictMediaJs;
  static String? _inlineSelectionJs;
  static String? _inlinePopupJs;
  static bool _inlineAssetsLoadFailed = false;

  static bool get _shouldInlinePopupAssets =>
      isWindowsPlatform || defaultTargetPlatform == TargetPlatform.iOS;

  static void _ensureInlinePopupAssetsLoaded() {
    if (_inlineCss != null || _inlineAssetsLoadFailed) return;
    try {
      _inlineCss = _readPopupAsset('popup.css');
      _inlineDictMediaJs = _readPopupAsset('dict-media.js');
      _inlineSelectionJs = _readPopupAsset('selection.js');
      _inlinePopupJs = _readPopupAsset('popup.js');
    } catch (e, stack) {
      _inlineAssetsLoadFailed = true;
      debugPrint('[PopupWebView] Popup asset inlining failed, '
          'falling back to file:// URL loading: $e');
      ErrorLogService.instance
          .log('PopupWebView._ensureInlinePopupAssetsLoaded', e, stack);
    }
  }

  static String _buildInlinePopupHtml({
    required String themeAttr,
    required String bgHex,
  }) {
    return '<!DOCTYPE html>'
        '<html data-theme="$themeAttr" style="--background-color:$bgHex">'
        '<head>'
        '<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">'
        '<style>${_inlineCss!.replaceAll('</style', r'<\/style')}</style>'
        '<script>$_inlineDictMediaJs</script>'
        '<script>$_inlineSelectionJs</script>'
        '<script>$_inlinePopupJs</script>'
        '</head>'
        '<body>'
        '<div id="entries-container"></div>'
        '<div class="overlay">'
        '<div class="overlay-close" onclick="closeOverlay()">×</div>'
        '<div class="overlay-content"></div>'
        '</div>'
        '</body></html>';
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

    InAppWebViewInitialData? popupInitialData;
    final bool shouldInlinePopupAssets = _shouldInlinePopupAssets;
    if (shouldInlinePopupAssets) {
      _ensureInlinePopupAssetsLoaded();
      if (_inlineCss != null &&
          _inlineDictMediaJs != null &&
          _inlineSelectionJs != null &&
          _inlinePopupJs != null) {
        popupInitialData = InAppWebViewInitialData(
          data: _buildInlinePopupHtml(themeAttr: themeAttr, bgHex: bgHex),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }
    }

    final Widget webView = InAppWebView(
      initialData: popupInitialData,
      initialUrlRequest: popupInitialData != null
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
        Factory<LongPressGestureRecognizer>(() => LongPressGestureRecognizer(
            duration: kPopupNativeSelectLongPressDuration)),
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

        // TODO-1392：查词弹窗 JS 渲染路径（renderPopup / __hibikiContainer 等）抛异常，此前
        // 只 console.error → onConsoleMessage → debugPrint（永不进错误日志），uncaught 更彻底
        // 静默（popup.js 此前无 window.onerror）。BUG-706 那类 __hibikiRoot 命名冲突致 renderPopup
        // TypeError 中止渲染时，用户看到「弹窗空白 + 错误日志为空」无从排查。popup.js 顶层现装
        // 全局 window.onerror / unhandledrejection + 渲染 catch，经此桥把 {source,message,stack}
        // 回传，落 ErrorLogService（错误日志页可见）。四查词表面（书内 / 视频 / 首页 / app 外悬浮）
        // 共用本 WebView，一处接通全覆盖。
        controller.addJavaScriptHandler(
          handlerName: 'reportJsError',
          callback: (args) {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.reportJsError',
              null,
              ErrorLogService.instance,
              () {
                logPopupJsError(ErrorLogService.instance, args);
                return null;
              },
            );
          },
        );

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

        // TODO-1353: Ctrl+滚轮缩放回传的新词典字号 → 夹紧后持久化到 dictionaryFontSize。
        // JS 侧已就地改了 zoom（即时反馈），这里落 DB 让缩放跨弹窗 / 重开后记住。
        // setDictionaryFontSize 走 preferences（notifyListeners），下次 buildPopupSettingsJs
        // 注入的 zoom 与 __hoshiPopupFontSize 即为新值，四端（书内 / 首页 / 视频 / 外部
        // 悬浮）共用同一 WebView 均生效。
        controller.addJavaScriptHandler(
          handlerName: 'popupZoomFont',
          callback: (args) {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.popupZoomFont',
              null,
              ErrorLogService.instance,
              () {
                final Object? raw = args.isNotEmpty ? args[0] : null;
                final double? fs = raw is num
                    ? raw.toDouble()
                    : double.tryParse(raw?.toString() ?? '');
                if (fs == null) return null;
                ref
                    .read(appProvider)
                    .setDictionaryFontSize(clampPopupZoomFontSize(fs));
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
          callback: (args) {
            return _guardJsBridge<Object?>(
              'DictPopupWebview.popupRendered',
              null,
              ErrorLogService.instance,
              () {
                final Object? rawToken = args.length > 1 ? args[1] : null;
                final int? token = rawToken is num
                    ? rawToken.toInt()
                    : int.tryParse(rawToken?.toString() ?? '');
                if (token != null && token != _renderToken) {
                  return null;
                }
                // 记录「当前已推结果渲染完成」，供 refreshCurrentResult 去重判定
                // （识别渲染信号早于宿主盖板架起的竞态）。
                _lastRenderedResult = _lastPushedResult;
                widget.onRendered?.call();
                // TODO-1152：全高填充宿主（in-app 查词结果区）渲染完成后补一次表面
                // 重绘 nudge，逼 Windows WebView2/WGC 捕获完整视口，消除下半屏黑。
                if (widget.nudgeSurfaceOnRender) _nudgeSurfaceRepaint();
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

        // TODO-1007/1008：点 ✓（卡已存在）时 popup.js 调本处理器（带当前词条制卡
        // payload）。宿主据 expression/reading 反查全部命中卡并弹操作选择（覆写指定
        // 张 / 新增重复卡 / 查看·在 Anki 中打开），执行后回 MinePopupResult 刷新 ✓。
        // 与 mineEntry 同样：先落盘词典媒体字节（覆写/新增都要嵌外字），自带 try/catch
        // 永不让异常穿过原生桥（BUG-293），返回结构化结果。
        controller.addJavaScriptHandler(
          handlerName: 'minedCardAction',
          callback: (args) async {
            try {
              if (args.isNotEmpty &&
                  args[0] is Map &&
                  widget.onMinedCardAction != null) {
                final fields = Map<String, String>.from(
                  (args[0] as Map)
                      .map((k, v) => MapEntry(k.toString(), v.toString())),
                );
                await writeDictionaryMediaCache(
                    fields['dictionaryMedia'] ?? '');
                final MinePopupResult result =
                    await widget.onMinedCardAction!(fields);
                return result.toJson();
              }
            } catch (e, stack) {
              ErrorLogService.instance
                  .log('DictPopupWebview.minedCardAction', e, stack);
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
        // TODO-1353: 装一次 Ctrl+滚轮缩放监听（幂等 guard；warm 热槽也只装一次）。
        controller.evaluateJavascript(source: _zoomWheelJs);
        controller
            .evaluateJavascript(source: ReaderCaretScripts.source())
            .then((_) {
          if (!mounted) return;
          unawaited(_pushInstantScrollPreference());
          if (_refreshWhenReady || _lastSearchTerm == null) {
            _pushResults();
          }
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

/// TODO-1392：查词弹窗 JS 报错桥（`reportJsError` handler）收到的原始 args → 一条错误日志。
/// 抽成顶层纯函数，便于单测「JS 抛异常 → error_log 有记录」而无需真 WebView。
///
/// [rawArgs] 是 flutter_inappwebview 传给 handler callback 的 `List`（首元素为 JS 对象
/// `{source, message, stack}`）。source 前缀成 `PopupJs.<source>` 写进 [ErrorLogService]，
/// stack 非空时经 [StackTrace.fromString] 还原成栈（[ErrorLogService.log] 会序列化落盘，
/// 复用 TODO-1383 的串行落盘链），空则不带栈。绝不吞——目的就是让 JS 报错在错误日志页可见。
void logPopupJsError(ErrorLogService errorLogService, List<dynamic> rawArgs) {
  final Object? raw = rawArgs.isNotEmpty ? rawArgs.first : null;
  final Map<Object?, Object?> payload =
      raw is Map ? raw : const <Object?, Object?>{};
  final String source = (payload['source'] ?? 'unknown').toString();
  final String message = (payload['message'] ?? '').toString();
  final String stack = (payload['stack'] ?? '').toString();
  errorLogService.log(
    'PopupJs.$source',
    message.isEmpty ? '(no message)' : message,
    stack.isEmpty ? null : StackTrace.fromString(stack),
  );
}
