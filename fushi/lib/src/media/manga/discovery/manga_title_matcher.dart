/// 标题模糊匹配打分：把「AniList 元数据条目」对上「在线来源搜索结果」。
///
/// 打分模型对齐 AnymeX 的 SourceMapper：token-set 0.4 + partial 0.3 + 全串
/// ratio 0.3 加权（漫画没有 season，去掉季号加成项）。两处为 CJK 做的适配：
/// - token 化按空白切；CJK 标题没有空白，token-set 退化为整串比较——此时
///   partial ratio（短串在长串里找最佳窗口）承担「包含即高分」的职责，覆盖
///   来源把副标题/卷号拼进标题的常见情况。
/// - 归一化只删标点/符号并折叠空白，**不做任何转写**：假名/汉字/罗马字之间
///   不互转，跨文字系统的命中交给多标题轮询（native/romaji/english 各查一轮）。
library;

import 'dart:math' as math;

/// [candidate]（来源搜索结果标题）对 [targets]（AniList 各语言标题+别名）的
/// 匹配分，取所有 target 中的最高分。返回 0.0–1.0。
double mangaTitleMatchScore(String candidate, List<String> targets) {
  final String source = normalizeMangaTitle(candidate);
  if (source.isEmpty) return 0;
  double best = 0;
  for (final String target in targets) {
    final String normalized = normalizeMangaTitle(target);
    if (normalized.isEmpty) continue;
    final double score = _pairScore(source, normalized);
    if (score > best) best = score;
    if (best >= 1) break;
  }
  return best;
}

double _pairScore(String a, String b) {
  final double tokenSet = _tokenSetRatio(a, b);
  final double partial = _partialRatio(a, b);
  final double whole = _ratio(a, b);
  final double score = tokenSet * 0.4 + partial * 0.3 + whole * 0.3;
  return score.clamp(0.0, 1.0);
}

/// 归一化：小写、去标点/符号（保留字母数字与 CJK）、折叠空白。
String normalizeMangaTitle(String value) {
  final StringBuffer buffer = StringBuffer();
  bool pendingSpace = false;
  for (final int rune in value.toLowerCase().runes) {
    if (_isTitleRune(rune)) {
      if (pendingSpace && buffer.isNotEmpty) buffer.writeCharCode(0x20);
      pendingSpace = false;
      buffer.writeCharCode(rune);
    } else {
      // 标点、符号、空白统一视作分隔，折叠为单个空格。
      pendingSpace = true;
    }
  }
  return buffer.toString();
}

bool _isTitleRune(int rune) {
  if (rune >= 0x30 && rune <= 0x39) return true; // 0-9
  if (rune >= 0x61 && rune <= 0x7A) return true; // a-z
  if (rune >= 0x3040 && rune <= 0x30FF) return true; // 假名
  if (rune >= 0x3400 && rune <= 0x9FFF) return true; // CJK 扩展 A + 基本区
  if (rune >= 0xF900 && rune <= 0xFAFF) return true; // CJK 兼容
  if (rune >= 0xAC00 && rune <= 0xD7AF) return true; // 谚文
  if (rune >= 0xFF10 && rune <= 0xFF19) return true; // 全角数字
  if (rune >= 0xFF41 && rune <= 0xFF5A) return true; // 全角小写字母
  if (rune >= 0x31F0 && rune <= 0x31FF) return true; // 片假名音标扩展
  return false;
}

/// 全串相似度：1 - 编辑距离/较长串长度。
double _ratio(String a, String b) {
  if (a == b) return 1;
  final int maxLen = math.max(a.length, b.length);
  if (maxLen == 0) return 1;
  return 1 - _levenshtein(a, b) / maxLen;
}

/// 短串对长串所有等长窗口的最佳 [_ratio]。窗口按短串长度滑动，步长 1。
double _partialRatio(String a, String b) {
  final String shorter = a.length <= b.length ? a : b;
  final String longer = a.length <= b.length ? b : a;
  if (shorter.isEmpty) return 0;
  if (longer.contains(shorter)) return 1;
  double best = 0;
  for (int start = 0; start + shorter.length <= longer.length; start++) {
    final double score =
        _ratio(shorter, longer.substring(start, start + shorter.length));
    if (score > best) best = score;
    if (best >= 1) break;
  }
  return best;
}

/// 词集合相似度（fuzzywuzzy 的 token_set_ratio 简化版）：交集串与两个「交集+
/// 差集」串两两比较取最高。CJK 无空白时退化为整串比较（词表只有一个元素）。
double _tokenSetRatio(String a, String b) {
  final Set<String> tokensA =
      a.split(' ').where((String t) => t.isNotEmpty).toSet();
  final Set<String> tokensB =
      b.split(' ').where((String t) => t.isNotEmpty).toSet();
  if (tokensA.isEmpty || tokensB.isEmpty) return 0;
  final List<String> intersection = (tokensA.intersection(tokensB)).toList()
    ..sort();
  final List<String> onlyA = tokensA.difference(tokensB).toList()..sort();
  final List<String> onlyB = tokensB.difference(tokensA).toList()..sort();
  final String base = intersection.join(' ');
  final String combinedA = <String>[...intersection, ...onlyA].join(' ').trim();
  final String combinedB = <String>[...intersection, ...onlyB].join(' ').trim();
  double best = _ratio(combinedA, combinedB);
  if (base.isNotEmpty) {
    best = math.max(best, _ratio(base, combinedA));
    best = math.max(best, _ratio(base, combinedB));
  }
  return best;
}

int _levenshtein(String a, String b) {
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  List<int> previous =
      List<int>.generate(b.length + 1, (int index) => index, growable: false);
  List<int> current = List<int>.filled(b.length + 1, 0, growable: false);
  for (int i = 0; i < a.length; i++) {
    current[0] = i + 1;
    for (int j = 0; j < b.length; j++) {
      final int cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      current[j + 1] = math.min(
        math.min(current[j] + 1, previous[j + 1] + 1),
        previous[j] + cost,
      );
    }
    final List<int> swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}
