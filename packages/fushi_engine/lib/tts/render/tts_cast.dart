/// 多声优配音的「选角表」：每句台词归哪个角色、每个角色用哪份声音预设。
///
/// - 句子按 `(章, 句首匹配偏移)` 指认（[ttsLineKey]），不按计划下标：计划随发音词典 /
///   分句规则变化会整体平移，坐标锚在正文上才稳定。
/// - 角色标注可以来自 LLM（[TtsCastSource.llm]）或用户手改（[TtsCastSource.user]，
///   重新标注时保留，不被 LLM 覆盖）。
/// - 没有归属的句子、归给「旁白」的句子、角色没配声音的句子，一律用任务的默认声音
///   （旁白声音）。
/// - 每本书一个 JSON 文件，原子写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 旁白（叙述）的固定角色名。
const String kTtsNarrator = '__narrator__';

/// 是台词、但判断不出是谁说的（与旁白分开：用户可以一次性把它们指给某个角色，
/// 或给「不明」单独配一个声音）。
const String kTtsUnknown = '__unknown__';

String ttsLineKey(int section, int matchStart) => '$section:$matchStart';

enum TtsCastSource { llm, user }

/// 归属依据（小说说话人识别的三类：有「X 说」明确提示 / 靠代词或称谓回指 / 无任何
/// 提示、靠对话轮次推断）。复核界面优先列后两类。
enum TtsCastEvidence { explicit, anaphoric, implicit }

class TtsCastLine {
  const TtsCastLine({
    required this.speaker,
    required this.source,
    this.emotion,
    this.confidence,
    this.evidence,
  });

  /// 角色名；[kTtsNarrator] = 旁白，[kTtsUnknown] = 说话人不明。
  final String speaker;
  final TtsCastSource source;

  /// LLM 给的情绪 / 语气提示（目前只展示，合成不用）。
  final String? emotion;

  /// LLM 自报的把握（0..1）；用户手改的行为 null（视为确定）。
  final double? confidence;
  final TtsCastEvidence? evidence;

  /// 需要人看一眼：不明、把握低于 0.7、或无提示推断的台词。
  bool get needsReview =>
      source == TtsCastSource.llm &&
      speaker != kTtsNarrator &&
      (speaker == kTtsUnknown ||
          (confidence ?? 1) < 0.7 ||
          evidence == TtsCastEvidence.implicit);

  Map<String, Object?> toJson() => <String, Object?>{
    's': speaker,
    'src': source.name,
    if (emotion != null) 'e': emotion,
    if (confidence != null) 'c': confidence,
    if (evidence != null) 'ev': evidence!.name,
  };

  static TtsCastLine? fromJson(Object? raw) {
    if (raw is! Map || raw['s'] is! String) return null;
    final Object? c = raw['c'];
    TtsCastEvidence? evidence;
    for (final TtsCastEvidence e in TtsCastEvidence.values) {
      if (e.name == raw['ev']) evidence = e;
    }
    return TtsCastLine(
      speaker: raw['s'] as String,
      source: raw['src'] == TtsCastSource.user.name
          ? TtsCastSource.user
          : TtsCastSource.llm,
      emotion: raw['e'] is String ? raw['e'] as String : null,
      confidence: c is num ? c.toDouble().clamp(0.0, 1.0) : null,
      evidence: evidence,
    );
  }
}

/// 角色表里的一个人：规范名 + 别名 + 选角用的特征（LLM 第一遍抽取，用户可改）。
class TtsCastCharacter {
  const TtsCastCharacter({
    required this.name,
    this.aliases = const <String>[],
    this.gender,
    this.age,
    this.description,
  });

  final String name;
  final List<String> aliases;

  /// `female` / `male` / null（不明）。
  final String? gender;

  /// `child` / `teen` / `adult` / `elderly` / null。
  final String? age;

  /// 一句人设（口吻、身份），选声音时参考。
  final String? description;

  Map<String, Object?> toJson() => <String, Object?>{
    'n': name,
    if (aliases.isNotEmpty) 'a': aliases,
    if (gender != null) 'g': gender,
    if (age != null) 'age': age,
    if (description != null) 'd': description,
  };

  static TtsCastCharacter? fromJson(Object? raw) {
    if (raw is! Map || raw['n'] is! String) return null;
    final Object? a = raw['a'];
    return TtsCastCharacter(
      name: raw['n'] as String,
      aliases: <String>[
        if (a is List)
          for (final Object? v in a)
            if (v is String && v.isNotEmpty) v,
      ],
      gender: raw['g'] is String ? raw['g'] as String : null,
      age: raw['age'] is String ? raw['age'] as String : null,
      description: raw['d'] is String ? raw['d'] as String : null,
    );
  }
}

class TtsCast {
  TtsCast({
    Map<String, TtsCastLine>? lines,
    Map<String, String>? voices,
    Map<String, TtsCastCharacter>? roster,
    this.annotatedSections = const <int>{},
  }) : lines = lines ?? <String, TtsCastLine>{},
       voices = voices ?? <String, String>{},
       roster = roster ?? <String, TtsCastCharacter>{};

  /// 行键（[ttsLineKey]）→ 角色。
  final Map<String, TtsCastLine> lines;

  /// 角色 → 声音预设 id。旁白也可以单独配（否则用任务默认声音）。
  final Map<String, String> voices;

  /// 角色表：规范名 → 角色（别名 / 性别 / 年龄 / 人设）。LLM 第一遍按章增量抽取，
  /// 第二遍逐句归属只能从这里选（或 [kTtsUnknown]）。
  final Map<String, TtsCastCharacter> roster;

  /// 已经跑过 LLM 标注的章（UI 显示进度、重新标注跳过已完成的章）。
  Set<int> annotatedSections;

  bool get isEmpty => lines.isEmpty && voices.isEmpty;

  String speakerOf(int section, int matchStart) =>
      lines[ttsLineKey(section, matchStart)]?.speaker ?? kTtsNarrator;

  /// 这一句用哪份声音预设；null = 用任务默认声音。
  String? presetFor(int section, int matchStart) =>
      voices[speakerOf(section, matchStart)];

  /// 出现过的角色（不含旁白）及台词数，按台词数降序。
  List<({String speaker, int count})> speakers() {
    final Map<String, int> counts = <String, int>{};
    for (final TtsCastLine line in lines.values) {
      if (line.speaker == kTtsNarrator) continue;
      counts[line.speaker] = (counts[line.speaker] ?? 0) + 1;
    }
    final List<({String speaker, int count})> out =
        <({String speaker, int count})>[
          for (final MapEntry<String, int> e in counts.entries)
            (speaker: e.key, count: e.value),
        ]..sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  /// 并入 LLM 的一章标注：用户手改过的行保留。
  void mergeLlm(int section, Map<String, TtsCastLine> annotated) {
    lines.removeWhere(
      (String key, TtsCastLine line) =>
          key.startsWith('$section:') && line.source == TtsCastSource.llm,
    );
    annotated.forEach((String key, TtsCastLine line) {
      final TtsCastLine? existing = lines[key];
      if (existing != null && existing.source == TtsCastSource.user) return;
      lines[key] = line;
    });
    annotatedSections = <int>{...annotatedSections, section};
  }

  /// 并入第一遍抽到的角色：同名合并别名、空特征用新值补上（不覆盖已有值）。
  void mergeRoster(Iterable<TtsCastCharacter> found) {
    for (final TtsCastCharacter c in found) {
      final TtsCastCharacter? old = roster[c.name];
      if (old == null) {
        roster[c.name] = c;
        continue;
      }
      roster[c.name] = TtsCastCharacter(
        name: old.name,
        aliases: <String>{...old.aliases, ...c.aliases}.toList(),
        gender: old.gender ?? c.gender,
        age: old.age ?? c.age,
        description: old.description ?? c.description,
      );
    }
  }

  /// 需要人工复核的行数（不明 / 低把握 / 无提示推断）。
  int get reviewCount =>
      lines.values.where((TtsCastLine l) => l.needsReview).length;

  /// 用户手动改一句的角色。
  void setUserSpeaker(int section, int matchStart, String speaker) {
    lines[ttsLineKey(section, matchStart)] = TtsCastLine(
      speaker: speaker,
      source: TtsCastSource.user,
    );
  }

  /// 把一个角色改名 / 合并进另一个角色（LLM 常把同一人标成两个名字）。
  void renameSpeaker(String from, String to) {
    if (from == to) return;
    lines.updateAll(
      (String _, TtsCastLine line) => line.speaker == from
          ? TtsCastLine(
              speaker: to,
              source: line.source,
              emotion: line.emotion,
              confidence: line.confidence,
              evidence: line.evidence,
            )
          : line,
    );
    final String? voice = voices.remove(from);
    if (voice != null) voices.putIfAbsent(to, () => voice);
    // 角色表：旧名成为新名的别名（下次标注时 LLM 会把它认作同一人）。
    final TtsCastCharacter? gone = roster.remove(from);
    if (gone != null && to != kTtsUnknown && to != kTtsNarrator) {
      mergeRoster(<TtsCastCharacter>[
        TtsCastCharacter(
          name: to,
          aliases: <String>[from, ...gone.aliases],
          gender: gone.gender,
          age: gone.age,
          description: gone.description,
        ),
      ]);
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'lines': <String, Object?>{
      for (final MapEntry<String, TtsCastLine> e in lines.entries)
        e.key: e.value.toJson(),
    },
    'voices': voices,
    'roster': <Object?>[
      for (final TtsCastCharacter c in roster.values) c.toJson(),
    ],
    'annotated': annotatedSections.toList()..sort(),
  };

  static TtsCast fromJson(Object? raw) {
    if (raw is! Map) return TtsCast();
    final Object? lines = raw['lines'];
    final Object? voices = raw['voices'];
    final Object? annotated = raw['annotated'];
    final Object? roster = raw['roster'];
    return TtsCast(
      roster: <String, TtsCastCharacter>{
        if (roster is List)
          for (final Object? r in roster)
            if (TtsCastCharacter.fromJson(r) case final TtsCastCharacter c)
              c.name: c,
      },
      lines: <String, TtsCastLine>{
        if (lines is Map)
          for (final MapEntry<Object?, Object?> e in lines.entries)
            if (e.key is String)
              if (TtsCastLine.fromJson(e.value) case final TtsCastLine line)
                e.key! as String: line,
      },
      voices: <String, String>{
        if (voices is Map)
          for (final MapEntry<Object?, Object?> e in voices.entries)
            if (e.key is String && e.value is String)
              e.key! as String: e.value! as String,
      },
      annotatedSections: <int>{
        if (annotated is List)
          for (final Object? v in annotated)
            if (v is int) v,
      },
    );
  }
}

/// 每本书一份选角表：`<root>/<sha1(bookKey)>.json`。
class TtsCastStore {
  TtsCastStore(this.root);

  final Directory root;

  File _file(String bookKey) =>
      File(p.join(root.path, '${sha1.convert(utf8.encode(bookKey))}.json'));

  Future<TtsCast> load(String bookKey) async {
    final File f = _file(bookKey);
    if (!await f.exists()) return TtsCast();
    try {
      return TtsCast.fromJson(jsonDecode(await f.readAsString()));
    } on FormatException {
      await f.rename('${f.path}.corrupt');
      return TtsCast();
    }
  }

  Future<void> save(String bookKey, TtsCast cast) async {
    final File f = _file(bookKey);
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(cast.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}
