/// S0：作品专名表的生成与校验（spec `2026-10-19-video-asr-llm-subtitle-pipeline`
/// 第 3 节，移植自基准 `C:\asr_bench\scripts\series_glossary.py`）。
///
/// 数据源优先级：刮削数据（日文原名 / AniDB 汉字标题 / 角色日文名，**权威**）→
/// 百科页正文（[WebKnowledgeClient] 按日文原名抓；不依赖提供商的联网工具）→ AI
/// 整理成 `[{ja, reading, kind, misrecognitions}]`。提示词要求写法只取资料、不取
/// ASR：ASR 抽样只用来确认「是哪部作品」（同名作品会撞，「sin 七つの大罪」被查成
/// 铃木央的《七つの大罪》）。
///
/// 两道程序校验，不过就带反馈重做，仍不过抛 [SubtitleGlossaryValidationFailure]
/// （UI 要让用户处理）：
/// - 身份校验（[subtitleGlossaryCoverage]）：表中人名有多少真的出现在 ASR 文本里。
///   实测查错作品的表 2/40，对的 14/21，阈值 [kSubtitleGlossaryCoverageThreshold]。
/// - 矛盾校验（[subtitleGlossaryConflicts]）：某条的正式写法出现在另一条的误写里，
///   或类别带「要確認」之类注记。
///
/// 合并已有表：`userEdited` 条目原样保留、不被覆盖；资料指纹（[subtitleGlossaryFingerprint]）
/// 没变且已有表时不重新生成。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:path/path.dart' as p;

/// 身份校验阈值：表中人名在 ASR 文本里出现的比例下限（同基准 `0.35`）。
const double kSubtitleGlossaryCoverageThreshold = 0.35;

/// 人名条目少于这个数时不做身份校验（样本太小，判不出来；同基准 `< 4`）。
const int kSubtitleGlossaryCoverageMinNames = 4;

/// 提示词 / 校验规则的版本：改了提示词要 +1，让已有表的指纹失效、重新生成。
const int kSubtitleGlossaryPromptVersion = 1;

/// 生成提示词（`series_glossary.py` 的 `PROMPT`）。
///
/// 与基准的唯一差别：基准让 Claude CLI 自己 WebSearch，这里不依赖提供商的联网
/// 工具，改成把刮削数据与百科页正文放进 `{sources}` 交给模型——「必要ならWeb検索で…
/// 確認してください」一句相应改成按资料确认。其余规则逐字照搬。
const String kSubtitleGlossaryPrompt =
    '''日本のアニメ「{title}」(全シーズン・劇場版を含む)の日本語字幕を音声認識で作ります。誤認識されやすい固有名詞の表を作ってください。
正しい表記は下の資料(公式データ・百科事典の抜粋)で確認してください。資料に無い項目は、作品の公式表記を確かに知っている場合だけ含めてください。
含めるもの: 主要・準主要キャラクターのフルネーム、作中での呼ばれ方(愛称・あだ名・敬称付きの呼び方、例: りっちゃん、ムギちゃん、あずにゃん)、
楽器やペットなど名前の付いた物、部活・バンド名・学校名・曲名、作品特有の用語。
各項目に正しい表記・読み(ひらがな)・音声認識で出やすい誤表記の例(あれば)を付ける。
{sources}
{identity}
出力は JSON 配列のみ(説明文なし): [{"ja": "唯", "reading": "ゆい", "kind": "人名(平沢唯の名)", "misrecognitions": ["結衣", "悠依"]}, ...]''';

/// 身份确认用的 ASR 抽样（`IDENTITY`；「Web で確認」改为按资料确认）。
const String kSubtitleGlossaryIdentity =
    '''作品の特定用の資料(表記の根拠にはしない): 下は実際の音声を音声認識した抜粋(誤りを含む)。
同名・類似タイトルの別作品(原作違い・リメイク・スピンオフ等)と取り違えないよう、抜粋に出てくる登場人物・用語と一致する作品であることを
資料で確認してから表を作ること。正しい表記は抜粋ではなく公式データ・百科事典等の資料から取ること。
抜粋:
{lines}
''';

/// 身份校验不过时追加的反馈（`WRONG_WORK`，逐字照搬）。
const String kSubtitleGlossaryWrongWork = '''
前回作った表の人名はほとんど音声に出てこなかった(別作品の表だった可能性が高い): {miss}
音声に実際に多く出てくるカタカナ語: {heard}
これらの名前が登場する作品を特定し直して、その作品の表を作ること。
''';

/// 矛盾校验不过时的重做提示（`RECHECK`；「WebSearch / WebFetch で」改为按资料）。
const String kSubtitleGlossaryRecheck =
    '''アニメ「{title}」の固有名詞表に矛盾があります。下の資料で公式サイト・Wikipedia 等の正式表記を確認し、修正した表全体を出力してください。
- 同じ人物・用語の別表記は1項目にまとめ、正式表記を ja に、それ以外は misrecognitions に入れる。
- 音声認識の出力をそのまま正式表記にしない。確認できない項目は削除する。「要確認」などの注記を残さない。
{sources}
矛盾:
{issues}
現在の表:
{table}
出力は JSON 配列のみ(説明文なし)。''';

final RegExp _kKatakanaRun = RegExp('[ァ-ヺー]{2,}');
final RegExp _kReadingNoise = RegExp(r'[\s・]');
final RegExp _kUnverifiedKind = RegExp('要確認|不明|ASR');

String _kata(String s) => String.fromCharCodes(<int>[
  for (final int ch in s.runes)
    if (ch >= 0x3041 && ch <= 0x3096) ch + 0x60 else ch,
]);

/// 身份校验：人名条目里，有哪些（按正式写法 / 读音 / 已知误写）出现在 [spoken] 里。
/// 同 `series_glossary.py` 的 `coverage`。
({List<String> hit, List<String> miss}) subtitleGlossaryCoverage(
  List<SubtitleGlossaryEntry> entries,
  String spoken,
) {
  final List<String> hit = <String>[];
  final List<String> miss = <String>[];
  for (final SubtitleGlossaryEntry e in entries) {
    if (!e.isPersonName) continue;
    final String rd = e.reading.replaceAll(_kReadingNoise, '');
    final List<String> forms = <String>[
      e.ja,
      rd,
      _kata(rd),
      ...e.misrecognitions,
    ];
    final bool heard = forms.any(
      (String f) => f.runes.length >= 2 && spoken.contains(f),
    );
    (heard ? hit : miss).add(e.ja);
  }
  return (hit: hit, miss: miss);
}

/// 身份校验是否通过（人名太少时不判，视为通过）。
bool subtitleGlossaryCoveragePasses(({List<String> hit, List<String> miss}) c) {
  final int total = c.hit.length + c.miss.length;
  return total < kSubtitleGlossaryCoverageMinNames ||
      c.hit.length >= kSubtitleGlossaryCoverageThreshold * total;
}

/// 矛盾校验：同 `series_glossary.py` 的 `conflicts`（问题描述是给模型看的日文）。
List<String> subtitleGlossaryConflicts(List<SubtitleGlossaryEntry> entries) {
  final Set<String> canon = <String>{
    for (final SubtitleGlossaryEntry e in entries) e.ja,
  };
  final List<String> out = <String>[];
  for (final SubtitleGlossaryEntry e in entries) {
    for (final String m in e.misrecognitions) {
      if (canon.contains(m) && m != e.ja) {
        out.add('「$m」は正式表記の項目でもあるが、「${e.ja}」の誤表記にも入っている');
      }
    }
    if (_kUnverifiedKind.hasMatch(e.kind)) {
      out.add('「${e.ja}」: ${e.kind}');
    }
  }
  return out;
}

/// ASR 文本里出现最多的片假名词（`Counter(KATA.findall(spoken)).most_common(n)`；
/// 同频按首次出现先后）。
List<String> mostCommonKatakana(String spoken, int n) {
  final Map<String, int> count = <String, int>{};
  for (final RegExpMatch m in _kKatakanaRun.allMatches(spoken)) {
    count.update(m.group(0)!, (int v) => v + 1, ifAbsent: () => 1);
  }
  final List<MapEntry<String, int>> ordered = count.entries.toList();
  final Map<String, int> firstSeen = <String, int>{
    for (int i = 0; i < ordered.length; i++) ordered[i].key: i,
  };
  ordered.sort((MapEntry<String, int> a, MapEntry<String, int> b) {
    final int byCount = b.value.compareTo(a.value);
    return byCount != 0
        ? byCount
        : firstSeen[a.key]!.compareTo(firstSeen[b.key]!);
  });
  return <String>[for (final MapEntry<String, int> e in ordered.take(n)) e.key];
}

/// 身份确认用的抽样：前 3 集，每集均匀取 ≤25 行（同基准
/// `texts[e][::max(1, len // 25)][:25]`）。
List<String> subtitleGlossaryIdentitySample(List<List<String>> episodes) {
  final List<String> out = <String>[];
  for (final List<String> texts in episodes.take(3)) {
    final int step = texts.length ~/ 25 < 1 ? 1 : texts.length ~/ 25;
    final List<String> picked = <String>[
      for (int i = 0; i < texts.length; i += step) texts[i],
    ];
    out.addAll(picked.take(25));
  }
  return out;
}

/// 资料指纹：刮削身份 + 角色表 + 启用的百科站点 + 提示词版本。资料没变就不重新
/// 生成。百科页正文不进指纹（条目改一个字就让整表重生成、白花钱），站点集合进。
String subtitleGlossaryFingerprint(
  SubtitleWorkContext context, {
  List<String> webSiteIds = const <String>[],
}) {
  final String canonical = jsonEncode(<String, Object?>{
    'v': kSubtitleGlossaryPromptVersion,
    'title': context.title,
    'originalTitle': context.originalTitle,
    'kanjiTitle': context.kanjiTitle,
    'characters': <Map<String, Object?>>[
      for (final SubtitleWorkCharacter c in context.characters) c.toJson(),
    ],
    'web': webSiteIds,
  });
  return sha1.convert(utf8.encode(canonical)).toString();
}

/// 资料段（刮削数据 + 百科页），S0 生成与重做共用。
String buildSubtitleGlossarySources(
  SubtitleWorkContext context,
  List<WebKnowledgePage> pages,
) {
  final List<String> lines = <String>[];
  if (context.hasScrapedData) {
    lines.add('作品の公式データ(確定情報。作品の特定と表記の根拠にしてよい):');
    if (context.originalTitle?.isNotEmpty ?? false) {
      lines.add('- 日本語タイトル: ${context.originalTitle}');
    }
    if (context.kanjiTitle?.isNotEmpty ?? false) {
      lines.add('- 漢字タイトル: ${context.kanjiTitle}');
    }
    final List<SubtitleWorkCharacter> named = <SubtitleWorkCharacter>[
      for (final SubtitleWorkCharacter c in context.characters)
        if (c.originalName?.trim().isNotEmpty ?? false) c,
    ];
    final List<SubtitleWorkCharacter> romaji = <SubtitleWorkCharacter>[
      for (final SubtitleWorkCharacter c in context.characters)
        if (!(c.originalName?.trim().isNotEmpty ?? false)) c,
    ];
    String cv(SubtitleWorkCharacter c) =>
        c.voiceActor == null ? '' : ' / CV: ${c.voiceActor}';
    if (named.isNotEmpty) {
      lines.add('- 登場人物(公式の日本語表記。表の人名はこの表記に合わせること):');
      for (final SubtitleWorkCharacter c in named) {
        lines.add('  ${c.originalName!.trim()} (${c.name}${cv(c)})');
      }
    }
    if (romaji.isNotEmpty) {
      lines.add('- 登場人物(ローマ字表記のみ。日本語表記は資料で確認すること):');
      for (final SubtitleWorkCharacter c in romaji) {
        lines.add('  ${c.name}${cv(c)}');
      }
    }
  }
  if (pages.isNotEmpty) {
    lines.add('参考資料(百科事典等の抜粋):');
    for (final WebKnowledgePage page in pages) {
      lines
        ..add('【${page.site.label}: ${page.title}】')
        ..add(page.text);
    }
  }
  if (lines.isEmpty) {
    lines.add('(公式データ・参考資料なし。作品の公式表記を確かに知っている項目だけ含めること)');
  }
  return lines.join('\n');
}

/// 校验没过、带反馈重做后仍没过。
enum SubtitleGlossaryProblem {
  /// 身份校验：表里的人名几乎都没出现在音频里（多半查成了同名的别的作品）。
  wrongWork,

  /// 矛盾校验：正式写法与误写互相打架 / 带「要確認」注记。
  conflicts,
}

/// 专名表校验失败：UI 要让用户处理（改作品身份 / 先刮削 / 手动编辑后重跑）。
class SubtitleGlossaryValidationFailure implements Exception {
  const SubtitleGlossaryValidationFailure({
    required this.problem,
    required this.candidate,
    this.heardNames = const <String>[],
    this.missingNames = const <String>[],
    this.conflicts = const <String>[],
  });

  final SubtitleGlossaryProblem problem;

  /// 最后一次生成的表（未保存）：UI 可以拿它给用户改。
  final List<SubtitleGlossaryEntry> candidate;

  /// 身份校验：在 ASR 里出现 / 没出现的人名。
  final List<String> heardNames;
  final List<String> missingNames;

  /// 矛盾校验的问题描述（日文，给模型看的原文）。
  final List<String> conflicts;

  @override
  String toString() => switch (problem) {
    SubtitleGlossaryProblem.wrongWork =>
      'SubtitleGlossaryValidationFailure(wrongWork: '
          '${heardNames.length}/${heardNames.length + missingNames.length} '
          'names heard)',
    SubtitleGlossaryProblem.conflicts =>
      'SubtitleGlossaryValidationFailure(conflicts: ${conflicts.length})',
  };
}

/// 一次 S0 的结果。
class SubtitleGlossaryBuildResult {
  const SubtitleGlossaryBuildResult({
    required this.glossary,
    required this.regenerated,
    required this.usage,
    this.heardNames = const <String>[],
    this.missingNames = const <String>[],
  });

  /// 合并后的表（已含保留的 userEdited 条目）。[regenerated] 为 false 时就是已有表。
  final SubtitleGlossary glossary;

  /// 这次是否真的调了 AI 重新生成（调用方据此决定要不要存回）。
  final bool regenerated;
  final SubtitleAiUsageTally usage;

  /// 最终那张生成表的身份校验明细（没生成 / 没 ASR 文本时为空）。
  final List<String> heardNames;
  final List<String> missingNames;
}

/// S0 专名表生成器。
class SubtitleGlossaryBuilder {
  SubtitleGlossaryBuilder({
    required this.completer,
    this.webKnowledge,
    this.maxParseAttempts = 3,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AiTextCompleter completer;

  /// 百科页来源；null / 没启用站点 = 只用刮削数据。
  final WebKnowledgeClient? webKnowledge;
  final int maxParseAttempts;
  final DateTime Function() _clock;

  /// 生成（或复用）[context] 的专名表。
  ///
  /// [episodeTexts]：全部集的 ASR 文本（按集、按行），只用于身份确认与校验，不当
  /// 写法依据。[existing]：存储里已有的表（null = 没有）。[force]：资料没变也重新
  /// 生成（用户点「重新生成」）。
  Future<SubtitleGlossaryBuildResult> build({
    required SubtitleWorkContext context,
    required List<List<String>> episodeTexts,
    SubtitleGlossary? existing,
    bool force = false,
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
  }) async {
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    final WebKnowledgeClient? web = webKnowledge;
    final List<String> siteIds = web == null || !web.isEnabled
        ? const <String>[]
        : <String>[for (final WebKnowledgeSite s in web.sites) s.id];
    final String fingerprint = subtitleGlossaryFingerprint(
      context,
      webSiteIds: siteIds,
    );
    if (!force &&
        existing != null &&
        !existing.isEmpty &&
        existing.sourceFingerprint == fingerprint) {
      return SubtitleGlossaryBuildResult(
        glossary: existing,
        regenerated: false,
        usage: usage,
      );
    }

    throwIfSubtitleCancelled(cancel);
    final List<WebKnowledgePage> pages = web == null || !web.isEnabled
        ? const <WebKnowledgePage>[]
        : await web.search(context.japaneseTitle);
    final String sources = buildSubtitleGlossarySources(context, pages);
    final String spoken = <String>[
      for (final List<String> ep in episodeTexts) ...ep,
    ].join('\n');
    final String identity = spoken.isEmpty
        ? ''
        : kSubtitleGlossaryIdentity.replaceAll(
            '{lines}',
            subtitleGlossaryIdentitySample(episodeTexts).join('\n'),
          );
    String prompt(String extraIdentity) => kSubtitleGlossaryPrompt
        .replaceAll('{title}', context.japaneseTitle)
        .replaceAll('{sources}', sources)
        .replaceAll('{identity}', identity + extraIdentity);

    List<SubtitleGlossaryEntry> items = await _ask(prompt(''), usage, cancel);

    // 身份校验：不过就带「哪些名字没听到 + 实际听到的片假名词」重做，最多两次；
    // 两次重做后仍不过即失败（同基准的 for…else）。
    ({List<String> hit, List<String> miss}) coverage = (
      hit: const <String>[],
      miss: const <String>[],
    );
    if (spoken.isNotEmpty) {
      bool passed = false;
      for (int round = 0; round < 2; round++) {
        coverage = subtitleGlossaryCoverage(items, spoken);
        if (subtitleGlossaryCoveragePasses(coverage)) {
          passed = true;
          break;
        }
        final String feedback = kSubtitleGlossaryWrongWork
            .replaceAll('{miss}', coverage.miss.take(20).join('、'))
            .replaceAll('{heard}', mostCommonKatakana(spoken, 40).join('、'));
        items = await _ask(prompt(feedback), usage, cancel);
      }
      if (!passed) {
        coverage = subtitleGlossaryCoverage(items, spoken);
        final int total = coverage.hit.length + coverage.miss.length;
        if (coverage.hit.length <
            kSubtitleGlossaryCoverageThreshold * (total < 1 ? 1 : total)) {
          throw SubtitleGlossaryValidationFailure(
            problem: SubtitleGlossaryProblem.wrongWork,
            candidate: items,
            heardNames: coverage.hit,
            missingNames: coverage.miss,
          );
        }
      }
    }

    // 矛盾校验：不过就带问题清单重做，最多两次；仍有矛盾即失败。
    for (int round = 0; round < 2; round++) {
      final List<String> bad = subtitleGlossaryConflicts(items);
      if (bad.isEmpty) break;
      items = await _ask(
        kSubtitleGlossaryRecheck
            .replaceAll('{title}', context.japaneseTitle)
            .replaceAll('{sources}', sources)
            .replaceAll('{issues}', bad.join('\n'))
            .replaceAll(
              '{table}',
              jsonEncode(<Map<String, Object?>>[
                for (final SubtitleGlossaryEntry e in items) e.toJson(),
              ]),
            ),
        usage,
        cancel,
      );
    }
    final List<String> left = subtitleGlossaryConflicts(items);
    if (left.isNotEmpty) {
      throw SubtitleGlossaryValidationFailure(
        problem: SubtitleGlossaryProblem.conflicts,
        candidate: items,
        conflicts: left,
      );
    }
    if (spoken.isNotEmpty) coverage = subtitleGlossaryCoverage(items, spoken);

    return SubtitleGlossaryBuildResult(
      glossary: mergeSubtitleGlossary(
        existing: existing,
        generated: items,
        sourceFingerprint: fingerprint,
        generatedAt: _clock().millisecondsSinceEpoch,
      ),
      regenerated: true,
      usage: usage,
      heardNames: coverage.hit,
      missingNames: coverage.miss,
    );
  }

  /// 问一次、解析成条目；解析不出（不是 JSON 数组 / 没有一条有效条目）重试。
  Future<List<SubtitleGlossaryEntry>> _ask(
    String prompt,
    SubtitleAiUsageTally usage,
    SubtitleCancelToken cancel,
  ) async {
    for (int attempt = 0; attempt < maxParseAttempts; attempt++) {
      throwIfSubtitleCancelled(cancel);
      final AiChatCompletion reply = await completer.complete(prompt);
      usage.addCall(reply.usage);
      final List<SubtitleGlossaryEntry>? items = parseSubtitleGlossaryReply(
        reply.text,
      );
      if (items != null && items.isNotEmpty) return items;
    }
    throw const SubtitleAiRequestFailure(
      kSubtitleAiReplyIncomplete,
      detail: 'glossary: reply is not a JSON array of entries',
    );
  }
}

/// 回复里的 JSON 数组 → 条目（同基准 `re.search(r"\[.*\]", ..., re.S)`）；不是数组
/// 返回 null。`ja` 为空的条目丢弃，同一 `ja` 只留第一条。
List<SubtitleGlossaryEntry>? parseSubtitleGlossaryReply(String reply) {
  final int start = reply.indexOf('[');
  final int end = reply.lastIndexOf(']');
  if (start < 0 || end < start) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(reply.substring(start, end + 1));
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  final Set<String> seen = <String>{};
  final List<SubtitleGlossaryEntry> out = <SubtitleGlossaryEntry>[];
  for (final Object? item in decoded) {
    if (item is! Map) continue;
    final SubtitleGlossaryEntry e = SubtitleGlossaryEntry.fromJson(
      item.cast<String, Object?>(),
    ).copyWith(userEdited: false);
    if (e.ja.isEmpty || !seen.add(e.ja)) continue;
    out.add(e);
  }
  return out;
}

/// 新生成的表与已有表合并：已有表里 `userEdited` 的条目原样保留（排在前面），生成
/// 的条目中与它们同 `ja` 的丢弃；已有表里没被用户动过的条目整体被新表替换。
SubtitleGlossary mergeSubtitleGlossary({
  required SubtitleGlossary? existing,
  required List<SubtitleGlossaryEntry> generated,
  required String sourceFingerprint,
  required int generatedAt,
}) {
  final List<SubtitleGlossaryEntry> kept = <SubtitleGlossaryEntry>[
    for (final SubtitleGlossaryEntry e
        in existing?.entries ?? const <SubtitleGlossaryEntry>[])
      if (e.userEdited) e,
  ];
  final Set<String> keptJa = <String>{
    for (final SubtitleGlossaryEntry e in kept) e.ja,
  };
  return SubtitleGlossary(
    entries: <SubtitleGlossaryEntry>[
      ...kept,
      for (final SubtitleGlossaryEntry e in generated)
        if (!keptJa.contains(e.ja)) e,
    ],
    sourceFingerprint: sourceFingerprint,
    generatedAt: generatedAt,
    userEditedAt: existing?.userEditedAt,
  );
}

/// 不入库的实现：每个作品一个 JSON 文件（`<dir>/<sha1(workKey)>.json`），给独立
/// CLI 与测试用。app / 服务端走 Drift 表实现。
class SubtitleGlossaryFileStore implements SubtitleGlossaryStore {
  SubtitleGlossaryFileStore(this.directory);

  final Directory directory;

  File _fileFor(String workKey) => File(
    p.join(
      directory.path,
      '${sha1.convert(utf8.encode(workKey)).toString()}.json',
    ),
  );

  @override
  Future<SubtitleGlossary?> load(String workKey) async {
    final File f = _fileFor(workKey);
    if (!f.existsSync()) return null;
    try {
      return SubtitleGlossary.decode(await f.readAsString());
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(String workKey, SubtitleGlossary glossary) =>
      writeSubtitleJobFileAtomic(_fileFor(workKey), glossary.encode());
}
