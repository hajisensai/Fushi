import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// BUG-1140 第二阶段①：阅读器引擎 JS 的**每次导航参数**。
///
/// 背景：此前整份引擎脚本（selection + 三种 shell + caret + furigana + 手势，压缩后
/// 仍 ~145K 字符）在 Dart 侧把 `insets / pageWidth / progress / charOffset / fragment /
/// sasayakiCues …` 逐个**插值进源码**，于是每次跨章都是一份**全新的字符串**：既要过一次
/// platform channel，又要让 WebView 的 JS 引擎从零解析编译（`evaluateJavascript` 的字符串
/// 没有 V8 code cache）。实测 `evalSetupScript` 中位数 24ms，与章节体量无关 = 纯固定开销。
///
/// 修法：引擎源码变成**零插值的静态资源**（`<script src>` 走 fushi.local 拦截器 + 强缓存，
/// 见 `ReaderEngineScript`），只暴露一个 `window.__fushiEngine.install(C)`；本类就是那个
/// `C`——每次导航只下发这一小份 JSON，引擎在**运行时读取**它。
///
/// 因此本类是「per-nav 参数」的唯一真相源：**任何随导航/设置变化的值都必须落在这里**，
/// 不得回到脚本源码里插值（否则引擎不再静态，缓存与编译复用同时失效）。守卫见
/// `test/reader/reader_engine_static_source_guard_test.dart`。
@immutable
class ReaderEngineConfig {
  const ReaderEngineConfig({
    required this.navigationGeneration,
    required this.continuousMode,
    required this.vnMode,
    required this.vnClickAdvance,
    required this.scanNonJapaneseText,
    required this.hoverAutoLookup,
    this.hostHoverLookup = false,
    required this.highlightOnTap,
    required this.showChrome,
    required this.debugLogging,
    required this.swipeDistThreshold,
    required this.swipeFastDistThreshold,
    required this.wheelGestureQuietMs,
    required this.furiganaMode,
    required this.caretColor,
    required this.caretInsetTop,
    required this.caretInsetBottom,
    required this.initialProgress,
    required this.initialCharOffset,
    required this.initialCharOffsetEnd,
    required this.initialFragment,
    required this.chromeTopInset,
    required this.chromeBottomInset,
    required this.dartPageWidth,
    required this.dartPageHeight,
    required this.marginTop,
    required this.marginBottom,
    required this.marginLeft,
    required this.marginRight,
    required this.blurImages,
    required this.revealedKeys,
    required this.perfTraceEnabled,
    required this.vnRevealSpeed,
    required this.vnScreenMode,
    required this.vnSentencesPerScreen,
    required this.vnPreserveDialogue,
    required this.vnMergeCrossScreenSentenceAudioCues,
    this.sentenceAudioCuesJson,
  });

  /// Immutable token identifying the document/navigation that owns this
  /// config. Restore callbacks must echo it so a late callback from a replaced
  /// document cannot complete or mutate the active navigation.
  final int navigationGeneration;

  // ── 视图模式 / 手势 ────────────────────────────────────────────────
  final bool continuousMode;
  final bool vnMode;
  final bool vnClickAdvance;
  final bool scanNonJapaneseText;
  final bool hoverAutoLookup;

  /// BUG-2490：true = 宿主（Flutter）侧接管 Shift-悬停 / 纯悬停查词，文档内的
  /// mousemove 腿整条关掉（macOS 等 WebView 为原生视图的平台）；false = 维持 JS 腿
  /// （Windows：WebView2 是 Flutter 纹理，hover 由 fork 转发进文档）。
  final bool hostHoverLookup;
  final bool highlightOnTap;
  final bool showChrome;
  final bool debugLogging;
  final int swipeDistThreshold;
  final int swipeFastDistThreshold;
  final int wheelGestureQuietMs;

  /// `off` / `toggle` / `hidden` / `dimmed`（`ReaderSettings.furiganaMode` 的
  /// 值域）。JS 侧现已不按它分支（隐藏 / 淡显都由 CSS 承担），仍随 config 下发
  /// 供探针 / 日志读。
  final String furiganaMode;

  // ── caret ─────────────────────────────────────────────────────────
  final String caretColor;
  final double caretInsetTop;
  final double caretInsetBottom;

  // ── 恢复锚（三选一，优先级 fragment > charOffset > progress）────────
  final double initialProgress;
  final int initialCharOffset;
  final int initialCharOffsetEnd;
  final String? initialFragment;

  // ── 版面几何 ──────────────────────────────────────────────────────
  final double chromeTopInset;
  final double chromeBottomInset;
  final double? dartPageWidth;
  final double? dartPageHeight;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  // ── 图片 ──────────────────────────────────────────────────────────
  final bool blurImages;
  final List<String> revealedKeys;

  // ── 诊断 ──────────────────────────────────────────────────────────
  final bool perfTraceEnabled;

  // ── VN shell ──────────────────────────────────────────────────────
  final int vnRevealSpeed;
  final String vnScreenMode;
  final int vnSentencesPerScreen;
  final bool vnPreserveDialogue;
  final bool vnMergeCrossScreenSentenceAudioCues;

  /// 有声书 sasayaki cue 列表，**已经是 JSON 文本**（`_prepareSasayakiCuesJson` 的
  /// 产物）。原样嵌进 config 字面量，避免「解码再编码」多走一遍。`null` = 本章无 cue。
  final String? sentenceAudioCuesJson;

  /// 除 [sasayakiCuesJson] 外的全部字段（它是已编码的 JSON 片段，见 [toJsLiteral]）。
  Map<String, Object?> toJson() => <String, Object?>{
        'navigationGeneration': navigationGeneration,
        'continuousMode': continuousMode,
        'vnMode': vnMode,
        'vnClickAdvance': vnClickAdvance,
        'scanNonJapaneseText': scanNonJapaneseText,
        'hoverAutoLookup': hoverAutoLookup,
        'hostHoverLookup': hostHoverLookup,
        'highlightOnTap': highlightOnTap,
        'showChrome': showChrome,
        'debugLogging': debugLogging,
        'swipeDistThreshold': swipeDistThreshold,
        'swipeFastDistThreshold': swipeFastDistThreshold,
        'wheelGestureQuietMs': wheelGestureQuietMs,
        'furiganaMode': furiganaMode,
        'caretColor': caretColor,
        'caretInsetTop': caretInsetTop,
        'caretInsetBottom': caretInsetBottom,
        'initialProgress': initialProgress,
        'initialCharOffset': initialCharOffset,
        'initialCharOffsetEnd': initialCharOffsetEnd,
        'initialFragment': initialFragment,
        'chromeTopInset': chromeTopInset,
        'chromeBottomInset': chromeBottomInset,
        'dartPageWidth': dartPageWidth?.round(),
        'dartPageHeight': dartPageHeight?.round(),
        'marginTop': marginTop,
        'marginBottom': marginBottom,
        'marginLeft': marginLeft,
        'marginRight': marginRight,
        'blurImages': blurImages,
        'revealedKeys': revealedKeys,
        'perfTraceEnabled': perfTraceEnabled,
        'vnRevealSpeed': vnRevealSpeed,
        'vnScreenMode': vnScreenMode,
        'vnSentencesPerScreen': vnSentencesPerScreen,
        'vnPreserveDialogue': vnPreserveDialogue,
        'vnMergeCrossScreenSentenceAudioCues':
            vnMergeCrossScreenSentenceAudioCues,
      };

  /// 运行时可**热更新**的那一小份（BUG-2471）：`window.__fushiEngine.updateLive(patch)`
  /// 把 patch 合并进已 install 的 `C`（`window.__fushiReaderConfig` 与 install 闭包里的
  /// `C` 是同一个对象），并按需重算已物化的派生值（四个边距 → `--reader-margin-*`
  /// 像素变量、`window.scanNonJapaneseText`）。
  ///
  /// 背景：BUG-1812 把边距百分比从 CSS 的 `vh/vw` 搬进 `C`，由引擎在 install 时物化成
  /// `documentElement` 上的内联像素变量；此后「改边距」走的仍是只换 CSS 的
  /// `onSettingsChangedLive`，新样式表里的 `var(--reader-margin-top, Xvh)` 回退值被
  /// 停在旧值的内联变量遮住——改完没反应，要翻章 / 重开书才见效。滑动灵敏度阈值、
  /// 滚轮静默窗、扫描非日文这些同样只在 install 时读一次。这里就是它们的热更新通道：
  /// 设置一变，Dart 侧（`_applyStylesLive`）先下发这份 patch，再换 CSS + 重锚。
  ///
  /// 只放「引擎运行时按值读取、不需要重跑 install」的键；需要整章重载的
  /// （view / writing mode、模糊图）仍走 `notifyReaderLayoutChanged`。
  static String liveUpdateInvocation({
    required double marginTop,
    required double marginBottom,
    required double marginLeft,
    required double marginRight,
    required int swipeDistThreshold,
    required int swipeFastDistThreshold,
    required int wheelGestureQuietMs,
    required bool scanNonJapaneseText,
  }) {
    final String patch = jsonEncode(<String, Object?>{
      'marginTop': marginTop,
      'marginBottom': marginBottom,
      'marginLeft': marginLeft,
      'marginRight': marginRight,
      'swipeDistThreshold': swipeDistThreshold,
      'swipeFastDistThreshold': swipeFastDistThreshold,
      'wheelGestureQuietMs': wheelGestureQuietMs,
      'scanNonJapaneseText': scanNonJapaneseText,
    });
    return '(window.__fushiEngine && window.__fushiEngine.updateLive) '
        '? window.__fushiEngine.updateLive($patch) : false;';
  }

  /// 可直接嵌进 JS 的对象字面量。
  ///
  /// [sasayakiCuesJson] 本身已是合法 JSON（数组）文本，直接拼进来；其余字段走
  /// [jsonEncode]。这样避免 `jsonDecode` 一遍再 `jsonEncode` 一遍（cue 列表按章可达数千条）。
  String toJsLiteral() {
    final String head = jsonEncode(toJson());
    assert(head.startsWith('{') && head.endsWith('}'));
    final String body = head.substring(1, head.length - 1);
    final String cues = sentenceAudioCuesJson ?? 'null';
    return '{$body,"sentenceAudioCues":$cues}';
  }
}
