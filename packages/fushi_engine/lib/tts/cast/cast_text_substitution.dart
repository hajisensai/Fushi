/// 系列级的用词替换表：用户自己填「原文写法 → 替换写法」，生成时朗读的文字、cue
/// 文本、制卡句子用替换后的写法。
///
/// - 在 AI 标注文字输入与输出端替换：原文（OCR、EPUB 正文、演出稿）不改，删掉或停用一条即恢复原样。
/// - 字面匹配、长的优先（「セーラー服」先于「服」），一次扫描不重复替换。
/// - 手动填写的念法（`say`）是用户已经写好的最终文字，不再替换。
/// - 不自动挑候选；AI 标注的正文、OCR 与上下文也按同一张表替换；上传页图由应用层重绘命中的文字块。
///
/// 人名读法（[CastSubstitutionKind.name]，拍板 TW9ete_FHX）：「豊川祥子 → とがわさきこ」
/// 这类条目**只改合成时念的文字**（[applyCastSpokenSubstitutions]）。字幕 / cue / 制卡
/// 句子、AI 标注输入、上传页图都只走 [applyCastSubstitutions]，它跳过人名条目——读法
/// 不流到任何显示层。读法留空 = 待复核，不生效。单字简称（「祥ちゃん」的「祥」）只在
/// 后面紧跟称呼后缀时命中，避免「不祥事」之类误念。
library;

import 'package:fushi_engine/tts/render/tts_cast.dart';

/// 条目类别：普通用词替换（显示与朗读都改）/ 人名读法（只改朗读）。
enum CastSubstitutionKind {
  text,
  name;

  static CastSubstitutionKind parse(Object? raw) =>
      raw == 'name' ? CastSubstitutionKind.name : CastSubstitutionKind.text;
}

/// 单字人名简称只在这些称呼后缀前命中（「祥ちゃん」→「さきちゃん」）。
const List<String> kCastNameHonorifics = <String>[
  'ちゃん',
  'さん',
  'くん',
  '君',
  '様',
  'さま',
  '先輩',
  'せんぱい',
  '先生',
  '殿',
  '氏',
  'たん',
  'っち',
  'ちん',
  '嬢',
];

class CastTextSubstitution {
  const CastTextSubstitution({
    required this.source,
    required this.replacement,
    this.enabled = true,
    this.kind = CastSubstitutionKind.text,
    this.character,
  });

  /// 人名读法条目；[reading] 留空 = 待复核（不生效）。
  const CastTextSubstitution.name({
    required String written,
    required String reading,
    this.enabled = true,
    this.character,
  }) : source = written,
       replacement = reading,
       kind = CastSubstitutionKind.name;

  final String source;
  final String replacement;
  final bool enabled;
  final CastSubstitutionKind kind;

  /// 人名条目属于哪个角色（系列角色表里的规范名；只用于分组展示与去重）。
  final String? character;

  bool get isName => kind == CastSubstitutionKind.name;

  /// 人名条目还没填读法（待复核，不生效）。
  bool get isPendingName => isName && replacement.trim().isEmpty;

  CastTextSubstitution copyWith({
    String? source,
    String? replacement,
    bool? enabled,
  }) => CastTextSubstitution(
    source: source ?? this.source,
    replacement: replacement ?? this.replacement,
    enabled: enabled ?? this.enabled,
    kind: kind,
    character: character,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    's': source,
    'r': replacement,
    if (!enabled) 'off': true,
    if (isName) 'k': 'name',
    if (character != null) 'c': character,
  };

  static CastTextSubstitution? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? s = raw['s'];
    final Object? r = raw['r'];
    if (s is! String || s.isEmpty || r is! String) return null;
    final Object? c = raw['c'];
    return CastTextSubstitution(
      source: s,
      replacement: r,
      enabled: raw['off'] != true,
      kind: CastSubstitutionKind.parse(raw['k']),
      character: c is String && c.isNotEmpty ? c : null,
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

/// 按表替换要**显示**的文字（字幕 / cue / 制卡句子 / AI 标注输入 / 页图重绘）：只用
/// 启用且合格的普通条目，人名读法不参与。
String applyCastSubstitutions(String text, List<CastTextSubstitution> table) =>
    _applySubstitutions(text, table, spoken: false);

/// 按表替换合成时实际**念**的文字：普通条目 + 已填读法的人名条目，一次扫描、长的优先。
String applyCastSpokenSubstitutions(
  String text,
  List<CastTextSubstitution> table,
) => _applySubstitutions(text, table, spoken: true);

String _applySubstitutions(
  String text,
  List<CastTextSubstitution> table, {
  required bool spoken,
}) {
  if (text.isEmpty || table.isEmpty) return text;
  final Map<int, CastSubstitutionProblem> problems = validateCastSubstitutions(
    table,
  );
  final Map<String, CastTextSubstitution> bySource =
      <String, CastTextSubstitution>{
        for (int i = 0; i < table.length; i++)
          if (table[i].enabled &&
              !problems.containsKey(i) &&
              (!table[i].isName || (spoken && !table[i].isPendingName)))
            table[i].source: table[i],
      };
  if (bySource.isEmpty) return text;
  final List<String> sources = bySource.keys.toList()
    ..sort((String a, String b) {
      final int byLength = b.length.compareTo(a.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
  final String honorifics = kCastNameHonorifics.map(RegExp.escape).join('|');
  final RegExp pattern = RegExp(
    sources
        .map((String s) {
          final String escaped = RegExp.escape(s);
          // 单字人名简称：只在称呼后缀前命中。
          return bySource[s]!.isName && s.runes.length == 1
              ? '$escaped(?=(?:$honorifics))'
              : escaped;
        })
        .join('|'),
  );
  return text.replaceAllMapped(
    pattern,
    (Match m) => bySource[m[0]!]!.replacement,
  );
}

/// 从角色表补出待复核的人名条目：每个角色的规范名与别名，表里还没有同一写法的各补
/// 一条（读法留空，不生效）。返回新增的条目（按角色表顺序）。
List<CastTextSubstitution> pendingCastNameEntries({
  required List<CastTextSubstitution> table,
  required Iterable<TtsCastCharacter> roster,
}) {
  final Set<String> known = <String>{
    for (final CastTextSubstitution e in table) e.source,
  };
  final List<CastTextSubstitution> out = <CastTextSubstitution>[];
  for (final TtsCastCharacter c in roster) {
    if (c.name == kTtsNarrator || c.name == kTtsUnknown) continue;
    for (final String written in <String>[c.name, ...c.aliases]) {
      final String w = written.trim();
      if (w.isEmpty || !known.add(w)) continue;
      out.add(
        CastTextSubstitution.name(written: w, reading: '', character: c.name),
      );
    }
  }
  return out;
}
