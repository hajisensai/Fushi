/// 系列级的用词替换表：用户自己填「原文写法 → 替换写法」，生成时朗读的文字、cue
/// 文本、制卡句子用替换后的写法。
///
/// - 只在输出端替换：原文（OCR、EPUB 正文、演出稿）不改，删掉或停用一条即恢复原样。
/// - 字面匹配、长的优先（「セーラー服」先于「服」），一次扫描不重复替换。
/// - 手动填写的念法（`say`）是用户已经写好的最终文字，不再替换。
/// - 不自动挑候选，也不参与给 AI 的输入（AI 标注照常看原文）。
library;

class CastTextSubstitution {
  const CastTextSubstitution({
    required this.source,
    required this.replacement,
    this.enabled = true,
  });

  final String source;
  final String replacement;
  final bool enabled;

  Map<String, Object?> toJson() => <String, Object?>{
    's': source,
    'r': replacement,
    if (!enabled) 'off': true,
  };

  static CastTextSubstitution? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? s = raw['s'];
    final Object? r = raw['r'];
    if (s is! String || s.isEmpty || r is! String) return null;
    return CastTextSubstitution(
      source: s,
      replacement: r,
      enabled: raw['off'] != true,
    );
  }
}

/// 表的问题（界面逐条提示，不抛异常）。
enum CastSubstitutionProblem { emptySource, duplicateSource, lineBreak }

/// 逐条检查：空原文、原文重复、含换行 / 制表符。返回 下标 → 问题。
Map<int, CastSubstitutionProblem> validateCastSubstitutions(
  List<CastTextSubstitution> table,
) {
  final Map<int, CastSubstitutionProblem> out =
      <int, CastSubstitutionProblem>{};
  final Set<String> seen = <String>{};
  final RegExp bad = RegExp(r'[\t\r\n]');
  for (int i = 0; i < table.length; i++) {
    final CastTextSubstitution e = table[i];
    if (e.source.trim().isEmpty) {
      out[i] = CastSubstitutionProblem.emptySource;
    } else if (bad.hasMatch(e.source) || bad.hasMatch(e.replacement)) {
      out[i] = CastSubstitutionProblem.lineBreak;
    } else if (!seen.add(e.source)) {
      out[i] = CastSubstitutionProblem.duplicateSource;
    }
  }
  return out;
}

/// 按表替换 [text]（只用启用且合格的条目）。
String applyCastSubstitutions(String text, List<CastTextSubstitution> table) {
  if (text.isEmpty || table.isEmpty) return text;
  final Map<int, CastSubstitutionProblem> problems = validateCastSubstitutions(
    table,
  );
  final Map<String, String> bySource = <String, String>{
    for (int i = 0; i < table.length; i++)
      if (table[i].enabled && !problems.containsKey(i))
        table[i].source: table[i].replacement,
  };
  if (bySource.isEmpty) return text;
  final List<String> sources = bySource.keys.toList()
    ..sort((String a, String b) {
      final int byLength = b.length.compareTo(a.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
  final RegExp pattern = RegExp(sources.map(RegExp.escape).join('|'));
  return text.replaceAllMapped(pattern, (Match m) => bySource[m[0]!]!);
}
