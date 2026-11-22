/// 全屏歌词动画的主题契约（folia `Theme` 的歌词动画部分）：动画强度、每首的按词着色、配色覆盖、
/// 字重 / 字体提示。来源是 AI 主题（每首生成，见 AI 主题服务）或以后的手动主题；为 null 时宿主照旧
/// 从封面取色、强度取全局偏好。
///
/// 按词着色移植自 folia `src/components/visualizer/wordColoring.ts`（匹配规则逐条一致）。
library;

import 'package:flutter/foundation.dart' show immutable, mapEquals;
import 'package:material_ui/material_ui.dart';

/// 动画强度（folia `Theme.animationIntensity`）。[prefValue] 落库（冻结）。
enum LyricVisualizerIntensity {
  calm('calm'),
  normal('normal'),
  chaotic('chaotic');

  const LyricVisualizerIntensity(this.prefValue);

  final String prefValue;

  static const LyricVisualizerIntensity defaultIntensity = normal;

  /// 未知 / 缺省值回落 [defaultIntensity]。
  static LyricVisualizerIntensity fromPref(String? value) {
    for (final LyricVisualizerIntensity v in values) {
      if (v.prefValue == value) return v;
    }
    return defaultIntensity;
  }

  /// 常用的三档倍数：calm / normal / chaotic 各取一个值（样式调幅度用）。
  double pick(double calmValue, double normalValue, double chaoticValue) =>
      switch (this) {
        LyricVisualizerIntensity.calm => calmValue,
        LyricVisualizerIntensity.normal => normalValue,
        LyricVisualizerIntensity.chaotic => chaoticValue,
      };
}

/// 配色覆盖：每项为 null = 沿用封面取色。
@immutable
class LyricVisualizerPaletteOverride {
  const LyricVisualizerPaletteOverride({
    this.background,
    this.primary,
    this.secondary,
    this.accent,
    this.text,
  });

  final Color? background;
  final Color? primary;
  final Color? secondary;
  final Color? accent;
  final Color? text;

  bool get isEmpty =>
      background == null &&
      primary == null &&
      secondary == null &&
      accent == null &&
      text == null;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerPaletteOverride &&
      other.background == background &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.accent == accent &&
      other.text == text;

  @override
  int get hashCode => Object.hash(background, primary, secondary, accent, text);
}

/// 一段着色范围（行文本的 UTF-16 偏移，左闭右开）。
@immutable
class LyricVisualizerWordColorRange {
  const LyricVisualizerWordColorRange({
    required this.start,
    required this.end,
    required this.color,
    required this.priority,
  });

  final int start;
  final int end;
  final Color color;

  /// 越长的关键字越优先（folia：CJK 取字数，英文取最长单词长度）。
  final int priority;

  bool overlaps(int s, int e) => start < e && s < end;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerWordColorRange &&
      other.start == start &&
      other.end == end &&
      other.color == color &&
      other.priority == priority;

  @override
  int get hashCode => Object.hash(start, end, color, priority);

  @override
  String toString() => 'WordColorRange($start..$end, $color)';
}

/// CJK 匹配方式（folia `WordColorCjkMatchMode`）。
enum LyricVisualizerCjkMatch {
  /// 关键字包含这个词（folia 默认 `target-contains-token`）。
  targetContainsToken,

  /// 互相包含。
  bidirectional,

  /// 完全相同。
  exact,
}

final RegExp _cjkRe = RegExp(r'[一-龥぀-ヿ가-힯]');
final RegExp _nonWordRe = RegExp(r'[^\w]');
final RegExp _wordRe = RegExp(r'\w+');
final RegExp _spaceRe = RegExp(r'\s+');

String _normalizeToken(String s) => s.toLowerCase().replaceAll(_nonWordRe, '');

/// 每首的歌词动画主题。
@immutable
class LyricVisualizerTheme {
  const LyricVisualizerTheme({
    this.wordColors = const <String, Color>{},
    this.palette,
    this.intensity,
    this.fontWeight,
    this.fontFamily,
  });

  /// 关键字 → 颜色（顺序有意义：同优先级先写的先匹配，与 folia 数组一致）。
  final Map<String, Color> wordColors;

  /// 配色覆盖；null = 封面取色。
  final LyricVisualizerPaletteOverride? palette;

  /// 主题指定的强度；null = 用全局偏好。
  final LyricVisualizerIntensity? intensity;

  /// 字重提示（folia `fontWeight`）。
  final FontWeight? fontWeight;

  /// 字体族提示（folia `fontFamily`；本机没有该字体时由 Flutter 回落默认字体）。
  final String? fontFamily;

  bool get hasWordColors => wordColors.isNotEmpty;

  /// 单个词的颜色（folia `resolveWordColor`）：CJK 词按 [cjkMatch] 比对关键字，拉丁词规整成
  /// 小写字母数字后与关键字拆出的单词比对；没命中回 [fallback]。
  Color resolveWordColor(
    String word,
    Color fallback, {
    LyricVisualizerCjkMatch cjkMatch =
        LyricVisualizerCjkMatch.targetContainsToken,
  }) {
    if (wordColors.isEmpty) return fallback;
    final String clean = word.trim();
    if (clean.isEmpty) return fallback;
    final bool cjk = _cjkRe.hasMatch(clean);
    final String normalized = _normalizeToken(clean);
    for (final MapEntry<String, Color> e in wordColors.entries) {
      final String target = e.key.trim();
      if (target.isEmpty) continue;
      if (cjk) {
        final bool hit = switch (cjkMatch) {
          LyricVisualizerCjkMatch.exact => target == clean,
          LyricVisualizerCjkMatch.bidirectional =>
            target.contains(clean) || clean.contains(target),
          LyricVisualizerCjkMatch.targetContainsToken => target.contains(clean),
        };
        if (hit) return e.value;
        continue;
      }
      if (normalized.isEmpty) continue;
      final Iterable<String> targetWords = target
          .split(_spaceRe)
          .map(_normalizeToken)
          .where((String w) => w.isNotEmpty);
      if (targetWords.contains(normalized)) return e.value;
    }
    return fallback;
  }

  /// 整行的着色范围（folia `buildWordColorRanges`）：CJK 关键字按子串查找，英文关键字按 `\w+` 单词
  /// 匹配；重叠时长关键字优先，结果按起点升序且互不重叠。
  List<LyricVisualizerWordColorRange> colorRangesFor(String lineText) {
    if (lineText.isEmpty || wordColors.isEmpty) {
      return const <LyricVisualizerWordColorRange>[];
    }
    final List<LyricVisualizerWordColorRange> ranges =
        <LyricVisualizerWordColorRange>[];
    final Map<String, (Color, int)> english = <String, (Color, int)>{};
    for (final MapEntry<String, Color> e in wordColors.entries) {
      final String target = e.key.trim();
      if (target.isEmpty) continue;
      if (_cjkRe.hasMatch(target)) {
        int cursor = 0;
        while (cursor < lineText.length) {
          final int at = lineText.indexOf(target, cursor);
          if (at < 0) break;
          ranges.add(
            LyricVisualizerWordColorRange(
              start: at,
              end: at + target.length,
              color: e.value,
              priority: target.length,
            ),
          );
          cursor = at + (target.isEmpty ? 1 : target.length);
        }
        continue;
      }
      final List<String> words = target
          .split(_spaceRe)
          .map(_normalizeToken)
          .where((String w) => w.isNotEmpty)
          .toList();
      if (words.isEmpty) continue;
      int priority = 0;
      for (final String w in words) {
        if (w.length > priority) priority = w.length;
      }
      for (final String w in words) {
        final (Color, int)? cur = english[w];
        if (cur == null || priority > cur.$2) english[w] = (e.value, priority);
      }
    }
    if (english.isNotEmpty) {
      for (final RegExpMatch m in _wordRe.allMatches(lineText)) {
        final (Color, int)? hit = english[_normalizeToken(m[0]!)];
        if (hit == null) continue;
        ranges.add(
          LyricVisualizerWordColorRange(
            start: m.start,
            end: m.end,
            color: hit.$1,
            priority: hit.$2,
          ),
        );
      }
    }
    // 优先级高（关键字长）的先占位，重叠的丢掉。
    final List<LyricVisualizerWordColorRange> sorted =
        <LyricVisualizerWordColorRange>[...ranges]..sort((
          LyricVisualizerWordColorRange a,
          LyricVisualizerWordColorRange b,
        ) {
          final int p = b.priority.compareTo(a.priority);
          if (p != 0) return p;
          final int s = a.start.compareTo(b.start);
          return s != 0 ? s : a.end.compareTo(b.end);
        });
    final List<LyricVisualizerWordColorRange> picked =
        <LyricVisualizerWordColorRange>[];
    for (final LyricVisualizerWordColorRange r in sorted) {
      if (!picked.any(
        (LyricVisualizerWordColorRange p) => p.overlaps(r.start, r.end),
      )) {
        picked.add(r);
      }
    }
    picked.sort((
      LyricVisualizerWordColorRange a,
      LyricVisualizerWordColorRange b,
    ) {
      final int s = a.start.compareTo(b.start);
      return s != 0 ? s : a.end.compareTo(b.end);
    });
    return picked;
  }

  /// 行内 `[start, end)`（UTF-16 偏移）这一段该用的颜色：与某个范围重叠就取它（folia
  /// `resolveTokenColorMap` 的单段版），否则 null。
  static Color? colorForSpan(
    List<LyricVisualizerWordColorRange> ranges,
    int start,
    int end,
  ) {
    for (final LyricVisualizerWordColorRange r in ranges) {
      if (r.start >= end) break;
      if (r.overlaps(start, end)) return r.color;
    }
    return null;
  }

  LyricVisualizerTheme copyWith({
    Map<String, Color>? wordColors,
    LyricVisualizerPaletteOverride? palette,
    LyricVisualizerIntensity? intensity,
    FontWeight? fontWeight,
    String? fontFamily,
  }) => LyricVisualizerTheme(
    wordColors: wordColors ?? this.wordColors,
    palette: palette ?? this.palette,
    intensity: intensity ?? this.intensity,
    fontWeight: fontWeight ?? this.fontWeight,
    fontFamily: fontFamily ?? this.fontFamily,
  );

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerTheme &&
      mapEquals(other.wordColors, wordColors) &&
      other.palette == palette &&
      other.intensity == intensity &&
      other.fontWeight == fontWeight &&
      other.fontFamily == fontFamily;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(
      wordColors.entries.map(
        (MapEntry<String, Color> e) => Object.hash(e.key, e.value),
      ),
    ),
    palette,
    intensity,
    fontWeight,
    fontFamily,
  );
}
