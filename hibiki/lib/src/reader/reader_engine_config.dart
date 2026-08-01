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
/// 修法：引擎源码变成**零插值的静态资源**（`<script src>` 走 hoshi.local 拦截器 + 强缓存，
/// 见 `ReaderEngineScript`），只暴露一个 `window.__hoshiEngine.install(C)`；本类就是那个
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
    required this.highlightOnTap,
    required this.showChrome,
    required this.debugLogging,
    required this.swipeDistThreshold,
    required this.swipeFastDistThreshold,
    required this.wheelPageTurnInterval,
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
    required this.blurImages,
    required this.revealedKeys,
    required this.perfTraceEnabled,
    required this.vnRevealSpeed,
    required this.vnScreenMode,
    required this.vnSentencesPerScreen,
    required this.vnPreserveDialogue,
    required this.vnMergeCrossScreenSasayakiCues,
    this.sasayakiCuesJson,
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
  final bool highlightOnTap;
  final bool showChrome;
  final bool debugLogging;
  final int swipeDistThreshold;
  final int swipeFastDistThreshold;
  final int wheelPageTurnInterval;

  /// `off` / `partial` / `toggle`（`ReaderSettings.furiganaMode` 的值域）。
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
  final bool vnMergeCrossScreenSasayakiCues;

  /// 有声书 sasayaki cue 列表，**已经是 JSON 文本**（`_prepareSasayakiCuesJson` 的
  /// 产物）。原样嵌进 config 字面量，避免「解码再编码」多走一遍。`null` = 本章无 cue。
  final String? sasayakiCuesJson;

  /// 除 [sasayakiCuesJson] 外的全部字段（它是已编码的 JSON 片段，见 [toJsLiteral]）。
  Map<String, Object?> toJson() => <String, Object?>{
        'navigationGeneration': navigationGeneration,
        'continuousMode': continuousMode,
        'vnMode': vnMode,
        'vnClickAdvance': vnClickAdvance,
        'scanNonJapaneseText': scanNonJapaneseText,
        'hoverAutoLookup': hoverAutoLookup,
        'highlightOnTap': highlightOnTap,
        'showChrome': showChrome,
        'debugLogging': debugLogging,
        'swipeDistThreshold': swipeDistThreshold,
        'swipeFastDistThreshold': swipeFastDistThreshold,
        'wheelPageTurnInterval': wheelPageTurnInterval,
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
        'blurImages': blurImages,
        'revealedKeys': revealedKeys,
        'perfTraceEnabled': perfTraceEnabled,
        'vnRevealSpeed': vnRevealSpeed,
        'vnScreenMode': vnScreenMode,
        'vnSentencesPerScreen': vnSentencesPerScreen,
        'vnPreserveDialogue': vnPreserveDialogue,
        'vnMergeCrossScreenSasayakiCues': vnMergeCrossScreenSasayakiCues,
      };

  /// 可直接嵌进 JS 的对象字面量。
  ///
  /// [sasayakiCuesJson] 本身已是合法 JSON（数组）文本，直接拼进来；其余字段走
  /// [jsonEncode]。这样避免 `jsonDecode` 一遍再 `jsonEncode` 一遍（cue 列表按章可达数千条）。
  String toJsLiteral() {
    final String head = jsonEncode(toJson());
    assert(head.startsWith('{') && head.endsWith('}'));
    final String body = head.substring(1, head.length - 1);
    final String cues = sasayakiCuesJson ?? 'null';
    return '{$body,"sasayakiCues":$cues}';
  }
}
