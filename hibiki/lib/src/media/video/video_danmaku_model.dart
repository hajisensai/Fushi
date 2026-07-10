import 'dart:convert';

import 'package:flutter/foundation.dart';

const int kVideoDanmakuLocalMaxBytes = 20 * 1024 * 1024;
const int kDefaultVideoDanmakuMaxActive = 80;
const int kMaxVideoDanmakuActive = 200;
const int kDefaultVideoDanmakuMaxLanes = 12;
const Duration kDefaultVideoDanmakuScrollDuration = Duration(seconds: 8);
const Duration kDefaultVideoDanmakuFixedDuration = Duration(seconds: 4);

enum VideoDanmakuMode { scroll, top, bottom }

@immutable
class VideoDanmakuItem {
  const VideoDanmakuItem({
    required this.startMs,
    required this.text,
    required this.mode,
    required this.colorArgb,
  });

  final int startMs;
  final String text;
  final VideoDanmakuMode mode;
  final int colorArgb;

  VideoDanmakuItem copyWith({
    int? startMs,
    String? text,
    VideoDanmakuMode? mode,
    int? colorArgb,
  }) {
    return VideoDanmakuItem(
      startMs: startMs ?? this.startMs,
      text: text ?? this.text,
      mode: mode ?? this.mode,
      colorArgb: colorArgb ?? this.colorArgb,
    );
  }
}

@immutable
class VideoDanmakuLoadResult {
  const VideoDanmakuLoadResult({
    required this.items,
    required this.sourcePath,
    this.tooLarge = false,
    this.error,
  });

  final List<VideoDanmakuItem> items;
  final String sourcePath;
  final bool tooLarge;
  final Object? error;
}

int normalizeVideoDanmakuMaxActive(int value) =>
    value.clamp(1, kMaxVideoDanmakuActive).toInt();

/// 弹幕样式（全局偏好，TODO-1376）：字号缩放 / 不透明度 / 速度缩放 / 显示区域占屏比。
///
/// 全部即改即生效、落 JSON 偏好，与弹幕来源无关（本地 sidecar 与在线弹弹play 共用）。
/// 所有字段都有合法区间，读盘 / UI 输入统一经 [normalized] clamp，消除越界特例。
@immutable
class VideoDanmakuStyle {
  const VideoDanmakuStyle({
    this.fontScale = 1.0,
    this.opacity = 1.0,
    this.speedScale = 1.0,
    this.areaFraction = 1.0,
  });

  static const VideoDanmakuStyle defaults = VideoDanmakuStyle();

  static const double minFontScale = 0.5;
  static const double maxFontScale = 2.0;
  static const double minOpacity = 0.1;
  static const double maxOpacity = 1.0;
  static const double minSpeedScale = 0.5;
  static const double maxSpeedScale = 2.0;
  static const double minAreaFraction = 0.25;
  static const double maxAreaFraction = 1.0;

  /// 字号缩放（1.0 = 20px 基准字号），限定 [minFontScale, maxFontScale]。
  final double fontScale;

  /// 整体不透明度乘子，限定 [minOpacity, maxOpacity]。
  final double opacity;

  /// 速度缩放（越大越快 = 滚动/停留时长越短），限定 [minSpeedScale, maxSpeedScale]。
  final double speedScale;

  /// 弹幕可占用的画面高度比例（从顶部起算），限定 [minAreaFraction, maxAreaFraction]。
  final double areaFraction;

  VideoDanmakuStyle copyWith({
    double? fontScale,
    double? opacity,
    double? speedScale,
    double? areaFraction,
  }) {
    return VideoDanmakuStyle(
      fontScale: fontScale ?? this.fontScale,
      opacity: opacity ?? this.opacity,
      speedScale: speedScale ?? this.speedScale,
      areaFraction: areaFraction ?? this.areaFraction,
    );
  }

  /// 已 clamp 到合法区间的规范化实例（读盘 / UI 滑块输入统一走此）。
  VideoDanmakuStyle normalized() => VideoDanmakuStyle(
        fontScale: fontScale.clamp(minFontScale, maxFontScale).toDouble(),
        opacity: opacity.clamp(minOpacity, maxOpacity).toDouble(),
        speedScale: speedScale.clamp(minSpeedScale, maxSpeedScale).toDouble(),
        areaFraction:
            areaFraction.clamp(minAreaFraction, maxAreaFraction).toDouble(),
      );

  /// 滚动弹幕在屏时长（速度越大越短）。
  Duration get scrollDuration => Duration(
        milliseconds:
            (kDefaultVideoDanmakuScrollDuration.inMilliseconds / speedScale)
                .round(),
      );

  /// 顶部/底部固定弹幕停留时长（速度越大越短）。
  Duration get fixedDuration => Duration(
        milliseconds:
            (kDefaultVideoDanmakuFixedDuration.inMilliseconds / speedScale)
                .round(),
      );

  static String encode(VideoDanmakuStyle style) => jsonEncode(<String, dynamic>{
        'fontScale': style.fontScale,
        'opacity': style.opacity,
        'speedScale': style.speedScale,
        'areaFraction': style.areaFraction,
      });

  static VideoDanmakuStyle decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      double num_(Object? v, double fallback) =>
          v is num ? v.toDouble() : fallback;
      return VideoDanmakuStyle(
        fontScale: num_(d['fontScale'], 1.0),
        opacity: num_(d['opacity'], 1.0),
        speedScale: num_(d['speedScale'], 1.0),
        areaFraction: num_(d['areaFraction'], 1.0),
      ).normalized();
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VideoDanmakuStyle &&
      other.fontScale == fontScale &&
      other.opacity == opacity &&
      other.speedScale == speedScale &&
      other.areaFraction == areaFraction;

  @override
  int get hashCode => Object.hash(fontScale, opacity, speedScale, areaFraction);
}

/// 弹幕屏蔽规则（TODO-1376）：每行一条，`/pattern/` 视为正则（默认忽略大小写），
/// 其余按纯文本子串（忽略大小写）匹配。非法正则行被丢弃。
///
/// 一份多行文本即真相源：数据结构本身消除「纯文本 vs 正则」的 UI 分叉——不需要给
/// 用户两个独立输入框，也不需要 isRegex 布尔标记。
@immutable
class VideoDanmakuBlockRules {
  const VideoDanmakuBlockRules({
    this.plainWords = const <String>[],
    this.regexes = const <RegExp>[],
  });

  static const VideoDanmakuBlockRules empty = VideoDanmakuBlockRules();

  /// 已小写化的纯文本子串规则（匹配时对弹幕文本同样小写化）。
  final List<String> plainWords;

  /// 已编译的正则规则（非法 pattern 在解析阶段丢弃，不入列）。
  final List<RegExp> regexes;

  bool get isEmpty => plainWords.isEmpty && regexes.isEmpty;

  /// [text] 命中任一规则时返回 true（应被屏蔽）。
  bool blocks(String text) {
    if (isEmpty) return false;
    final String lower = text.toLowerCase();
    for (final String word in plainWords) {
      if (word.isNotEmpty && lower.contains(word)) return true;
    }
    for (final RegExp re in regexes) {
      if (re.hasMatch(text)) return true;
    }
    return false;
  }
}

/// 把多行规则文本解析成 [VideoDanmakuBlockRules]（编译正则、丢弃非法行/空行）。
VideoDanmakuBlockRules parseVideoDanmakuBlockRules(String raw) {
  final List<String> plain = <String>[];
  final List<RegExp> regexes = <RegExp>[];
  for (final String line in const LineSplitter().convert(raw)) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.length >= 2 &&
        trimmed.startsWith('/') &&
        trimmed.endsWith('/')) {
      final String pattern = trimmed.substring(1, trimmed.length - 1);
      if (pattern.isEmpty) continue;
      try {
        regexes.add(RegExp(pattern, caseSensitive: false));
      } catch (_) {
        // 非法正则丢弃，不阻断其它规则。
      }
      continue;
    }
    plain.add(trimmed.toLowerCase());
  }
  return VideoDanmakuBlockRules(plainWords: plain, regexes: regexes);
}

/// 用屏蔽规则过滤弹幕列表；规则为空时原样返回（零拷贝，热路径省分配）。
List<VideoDanmakuItem> filterVideoDanmaku(
  List<VideoDanmakuItem> items,
  VideoDanmakuBlockRules rules,
) {
  if (rules.isEmpty) return items;
  return items
      .where((VideoDanmakuItem item) => !rules.blocks(item.text))
      .toList(growable: false);
}
