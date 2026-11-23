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
///
/// 读法出处（[CastNameEvidence]，第三期）：「查人名读法」只收页面印着的注音（OCR 判出的
/// 注音块，或 AI 看页图抄下的、带页码）与联网搜索结果里官方资料写明的读法（带 URL），
/// 记在条目的 [CastTextSubstitution.evidence] 上。出处只给出**建议读法**
/// （[CastTextSubstitution.suggestedReading]），读法仍留空、不生效，用户采用后才填进
/// [CastTextSubstitution.replacement]；多个出处读法冲突时不给建议，留待复核。
library;

import 'package:fushi_engine/tts/render/tts_cast.dart';

/// 条目类别：普通用词替换（显示与朗读都改）/ 人名读法（只改朗读）。
enum CastSubstitutionKind {
  text,
  name;

  static CastSubstitutionKind parse(Object? raw) =>
      raw == 'name' ? CastSubstitutionKind.name : CastSubstitutionKind.text;
}

/// 人名读法出处的来源：页面印着的注音 / 官方资料。
enum CastNameEvidenceOrigin {
  ruby,
  official;

  static CastNameEvidenceOrigin? parse(Object? raw) => switch (raw) {
    'ruby' => CastNameEvidenceOrigin.ruby,
    'official' => CastNameEvidenceOrigin.official,
    _ => null,
  };
}

/// 一条人名读法的出处：[reading] 是出处写明的读法（只含假名，已去掉空格与「・」）。
///
/// - [CastNameEvidenceOrigin.ruby]：页面印着的注音，[page] 是 1 起的页码，[volume] 是卷名；
///   [byAi] = AI 看页图抄下的（否则是 OCR 判出的注音块）。
/// - [CastNameEvidenceOrigin.official]：联网搜索结果里的官方资料，[url] 是出处。
class CastNameEvidence {
  const CastNameEvidence({
    required this.origin,
    required this.reading,
    this.page,
    this.volume,
    this.url,
    this.byAi = false,
  });

  final CastNameEvidenceOrigin origin;
  final String reading;
  final int? page;
  final String? volume;
  final String? url;
  final bool byAi;

  /// 同一出处（判重用）。
  String get key =>
      '${origin.name}|$reading|${page ?? ''}|${volume ?? ''}|${url ?? ''}';

  Map<String, Object?> toJson() => <String, Object?>{
    'o': origin.name,
    'r': reading,
    if (page != null) 'p': page,
    if (volume != null) 'v': volume,
    if (url != null) 'u': url,
    if (byAi) 'ai': true,
  };

  static CastNameEvidence? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final CastNameEvidenceOrigin? origin = CastNameEvidenceOrigin.parse(
      raw['o'],
    );
    final String? reading = normalizeCastNameReading(raw['r']);
    if (origin == null || reading == null) return null;
    final Object? page = raw['p'];
    final Object? volume = raw['v'];
    final Object? url = raw['u'];
    return CastNameEvidence(
      origin: origin,
      reading: reading,
      page: page is int && page > 0 ? page : null,
      volume: volume is String && volume.isNotEmpty ? volume : null,
      url: url is String && url.isNotEmpty ? url : null,
      byAi: raw['ai'] == true,
    );
  }
}

/// 一条人名最多记几条出处。
const int kCastNameMaxEvidence = 6;

final RegExp _kNameReadingSeparators = RegExp(r'[\s\u3000・･]');
final RegExp _kNameReadingKana = RegExp(r'^[ぁ-ゖァ-ヺー]+$');

/// 规范化出处里的读法：去掉空格与「・」，只接受假名（平 / 片假名、长音），否则 null。
String? normalizeCastNameReading(Object? raw) {
  if (raw is! String) return null;
  final String r = raw.replaceAll(_kNameReadingSeparators, '');
  return r.isNotEmpty && _kNameReadingKana.hasMatch(r) ? r : null;
}

/// 片假名折成平假名（比较两个读法是否相同）。
String foldCastNameReading(String reading) => String.fromCharCodes(
  reading.runes.map((int c) => c >= 0x30a1 && c <= 0x30f6 ? c - 0x60 : c),
);

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
    this.evidence = const <CastNameEvidence>[],
  });

  /// 人名读法条目；[reading] 留空 = 待复核（不生效）。
  const CastTextSubstitution.name({
    required String written,
    required String reading,
    this.enabled = true,
    this.character,
    this.evidence = const <CastNameEvidence>[],
  }) : source = written,
       replacement = reading,
       kind = CastSubstitutionKind.name;

  final String source;
  final String replacement;
  final bool enabled;
  final CastSubstitutionKind kind;

  /// 人名条目属于哪个角色（系列角色表里的规范名；只用于分组展示与去重）。
  final String? character;

  /// 人名条目读法的出处（「查人名读法」收集；只作建议与出处记录，不直接生效）。
  final List<CastNameEvidence> evidence;

  bool get isName => kind == CastSubstitutionKind.name;

  /// 人名条目还没填读法（待复核，不生效）。
  bool get isPendingName => isName && replacement.trim().isEmpty;

  /// 出处里的不同读法（片假名 / 平假名差别不算），按首次出现顺序。
  List<String> get evidenceReadings {
    final Map<String, String> byFolded = <String, String>{};
    for (final CastNameEvidence e in evidence) {
      byFolded.putIfAbsent(foldCastNameReading(e.reading), () => e.reading);
    }
    return byFolded.values.toList();
  }

  /// 出处给出的建议读法：所有出处一致时取第一条，没有出处或出处冲突为 null。
  String? get suggestedReading {
    final List<String> readings = evidenceReadings;
    return readings.length == 1 ? readings.single : null;
  }

  /// 出处读法互相冲突（留待复核，不给建议）。
  bool get hasConflictingEvidence => evidenceReadings.length > 1;

  /// 支持当前读法 [replacement] 的那条出处（平 / 片假名、空格与「・」差别不算）；读法
  /// 留空、或用户手填的读法与所有出处都不一样时为 null——那时出处不能当成这个读法的
  /// 来源显示。
  CastNameEvidence? get evidenceForReading {
    final String? current = normalizeCastNameReading(replacement);
    if (current == null) return null;
    final String folded = foldCastNameReading(current);
    for (final CastNameEvidence e in evidence) {
      if (foldCastNameReading(e.reading) == folded) return e;
    }
    return null;
  }

  /// 改写法时出处一并作废（出处只对原来那个写法成立）。
  CastTextSubstitution copyWith({
    String? source,
    String? replacement,
    bool? enabled,
    List<CastNameEvidence>? evidence,
  }) => CastTextSubstitution(
    source: source ?? this.source,
    replacement: replacement ?? this.replacement,
    enabled: enabled ?? this.enabled,
    kind: kind,
    character: character,
    evidence:
        evidence ??
        (source == null || source == this.source
            ? this.evidence
            : const <CastNameEvidence>[]),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    's': source,
    'r': replacement,
    if (!enabled) 'off': true,
    if (isName) 'k': 'name',
    if (character != null) 'c': character,
    if (evidence.isNotEmpty)
      'e': <Map<String, Object?>>[
        for (final CastNameEvidence e in evidence) e.toJson(),
      ],
  };

  static CastTextSubstitution? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? s = raw['s'];
    final Object? r = raw['r'];
    if (s is! String || s.isEmpty || r is! String) return null;
    final Object? c = raw['c'];
    final Object? e = raw['e'];
    return CastTextSubstitution(
      source: s,
      replacement: r,
      enabled: raw['off'] != true,
      kind: CastSubstitutionKind.parse(raw['k']),
      character: c is String && c.isNotEmpty ? c : null,
      evidence: <CastNameEvidence>[
        if (e is List)
          for (final Object? item in e)
            if (CastNameEvidence.fromJson(item) case final CastNameEvidence ev)
              ev,
      ],
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

/// 把「查人名读法」找到的出处并进表：[found] 是 写法 → 出处。只并进同写法的人名条目
/// （去重、最多 [kCastNameMaxEvidence] 条），读法本身不动——建议要用户采用才生效。
/// [addFrom] 里的角色（规范名 + 别名）有出处、表里还没有这个写法的，先补成待复核条目。
/// 返回新表与「这次新有了建议读法」的待复核条目数。
({List<CastTextSubstitution> table, int suggested}) mergeCastNameEvidence({
  required List<CastTextSubstitution> table,
  required Map<String, List<CastNameEvidence>> found,
  Iterable<TtsCastCharacter> addFrom = const <TtsCastCharacter>[],
}) {
  bool hasFound(String written) => found[written]?.isNotEmpty ?? false;
  final List<CastTextSubstitution> base = <CastTextSubstitution>[
    ...table,
    for (final CastTextSubstitution e in pendingCastNameEntries(
      table: table,
      roster: addFrom,
    ))
      if (hasFound(e.source)) e,
  ];
  int suggested = 0;
  final List<CastTextSubstitution> out = <CastTextSubstitution>[];
  for (final CastTextSubstitution e in base) {
    if (!e.isName || !hasFound(e.source)) {
      out.add(e);
      continue;
    }
    final Map<String, CastNameEvidence> merged = <String, CastNameEvidence>{
      for (final CastNameEvidence ev in e.evidence) ev.key: ev,
    };
    for (final CastNameEvidence ev in found[e.source]!) {
      if (merged.length >= kCastNameMaxEvidence) break;
      merged.putIfAbsent(ev.key, () => ev);
    }
    final CastTextSubstitution next = e.copyWith(
      evidence: merged.values.toList(),
    );
    if (next.isPendingName &&
        next.suggestedReading != null &&
        e.suggestedReading == null) {
      suggested++;
    }
    out.add(next);
  }
  return (table: out, suggested: suggested);
}
