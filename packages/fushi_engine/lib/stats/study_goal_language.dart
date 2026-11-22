/// 学习字数目标的**语言维度**：目标用哪种单位（字 / 词）、预设给多大、分子要不要
/// 只算目标语言的内容。
///
/// ## 为什么目标要跟语言走
///
/// 「字数」本身已经是按文字自适应的学习单位（[countStudyChars]：汉字 / 假名 /
/// 谚文按码点计，拉丁 / 西里尔等按词计），所以同一个 `chars` 列在英语书里其实是
/// **词数**。但目标对话框以前只有一套按日语调好的预设（3k / 5k / 10k / 20k 字），
/// 单位文案也恒为「字」——学英语的人看到的是「10000 字」，实际要读一万个词。
///
/// 目标语言不是一个新的全局「学习语言」设置（那个假抽象 2026-07-26 已删且有守卫）：
/// 它是**本 Profile 的目标偏好**，缺省跟随 Profile 绑定的内容语言
/// （`language_profiles`），再缺省跟随默认内容语言；解析在 app 侧做，这里只吃结果。
///
/// ## 只算目标语言（可选）
///
/// 一个 Profile 里同时读日语书和英语书时，两种单位直接相加没有意义。打开
/// [StudyGoalLanguageScope.onlyLanguage] 后分子只累加**内容语言与目标语言主子标签
/// 相同**的媒体。媒体自己没有语言（没标 `dc:language` 的书、没设语言的视频 /
/// 游戏、legacy 无身份行）时按 app 内容语言链的第三档——**默认内容语言**
/// （[StudyGoalLanguageScope.fallbackLanguage]）——判定；连默认内容语言也没设的
/// 一律**不计**：开关的字面意思是「只算 X」，不知道是不是 X 的就不算。初版曾让
/// 未知照算，结果视频库大多没设语言、选了韩语目标分子几乎不变（用户实测）。
///
/// 目标还可以只算某种文字（「简体中文」= `zh-Hans`）：媒体的文字由文字子标签或
/// 地区推出（[resolveStudyGoalLanguage]）；只标了 `zh` 的媒体只计入整门「中文」目标。
library;

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

/// 目标的计量单位。决定文案（「字」/「词」）与预设量级，**不**改变计数口径——
/// 计数恒为 [countStudyChars]。
enum StudyGoalUnit {
  /// 不用空格分词的文字（日 / 中 / 韩 / 泰…）：一个码点一个单位。
  chars,

  /// 空格分词的文字（英 / 法 / 俄…）：一个词一个单位。
  words,
}

/// 文字目标单位的**用户选择**：自动（按目标语言，[studyGoalUnitFor]）或固定字 / 词。
enum StudyGoalUnitChoice {
  auto('auto'),
  chars('chars'),
  words('words');

  const StudyGoalUnitChoice(this.wire);
  final String wire;

  static StudyGoalUnitChoice fromWire(String? wire) {
    for (final StudyGoalUnitChoice c in values) {
      if (c.wire == wire) return c;
    }
    return auto;
  }

  /// 固定单位；[auto] 为 null。
  StudyGoalUnit? get fixed => switch (this) {
    auto => null,
    chars => StudyGoalUnit.chars,
    words => StudyGoalUnit.words,
  };
}

/// BCP-47 标签的主语言子标签（小写）；空 / 未确定（`und`）返回 null。
///
/// `ja-JP` 与 `ja` 相同。文字（简 / 繁等）见 [resolveStudyGoalLanguage]。
String? studyGoalPrimaryLanguage(String? tag) =>
    resolveStudyGoalLanguage(tag)?.primary;

/// 目标语言的身份：主语言 + 可选的文字（ISO 15924，首字母大写：`Hans` / `Hant`）。
///
/// 目标的 [script] 为 null = 这门语言的全部内容（「中文」= 简繁都算）；不为 null
/// = 只算解析出同一文字的内容。媒体的 [script] 为 null = 只标了语言、看不出文字
/// （只计入不限文字的目标）。
class StudyGoalLanguage {
  const StudyGoalLanguage(this.primary, [this.script]);

  /// 主语言子标签（小写）。
  final String primary;

  /// 文字子标签（`Hans`）；null = 不限 / 未知。
  final String? script;

  /// 规范写法：`zh`、`zh-Hans`。用作目标的语言值、去重键。
  String get tag => script == null ? primary : '$primary-$script';

  /// 去掉文字的同一语言（「简体中文」→「中文」）。
  StudyGoalLanguage get combined => StudyGoalLanguage(primary);

  /// 作为**目标**时是否计入语言为 [media] 的内容。
  bool includes(StudyGoalLanguage? media) =>
      media != null &&
      media.primary == primary &&
      (script == null || media.script == script);

  @override
  bool operator ==(Object other) =>
      other is StudyGoalLanguage &&
      other.primary == primary &&
      other.script == script;

  @override
  int get hashCode => Object.hash(primary, script);

  @override
  String toString() => tag;
}

/// 有多种文字写法的语言：主语言 → 可单独选的文字（目标里在「整门语言」之外另给
/// 「只算这种文字」的选项）。加一门语言只改这张表和 [_kRegionScripts]。
const Map<String, List<String>> kStudyGoalScriptVariants =
    <String, List<String>>{
      'zh': <String>['Hans', 'Hant'],
    };

/// 没写文字子标签时，按地区推出文字（`zh-TW` → 繁体）。只列有文字之分的语言。
const Map<String, Map<String, String>> _kRegionScripts =
    <String, Map<String, String>>{
      'zh': <String, String>{
        'CN': 'Hans',
        'SG': 'Hans',
        'MY': 'Hans',
        'TW': 'Hant',
        'HK': 'Hant',
        'MO': 'Hant',
      },
    };

/// 解析 BCP-47 标签成目标语言身份（唯一的解析器：目标匹配、去重、候选都走它）。
///
/// 文字：显式文字子标签（4 个字母，任何语言都认）优先，其次按 [_kRegionScripts]
/// 由地区推出；都没有 = null。空 / `und` 返回 null。
StudyGoalLanguage? resolveStudyGoalLanguage(String? tag) {
  final String trimmed = tag?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final List<String> parts = trimmed.replaceAll('_', '-').split('-');
  final String primary = parts.first.toLowerCase();
  if (primary.isEmpty || primary == 'und') return null;
  String? script;
  String? region;
  for (final String part in parts.skip(1)) {
    if (part.length == 4 && script == null && _isAlpha(part)) {
      script = part[0].toUpperCase() + part.substring(1).toLowerCase();
    } else if (region == null &&
        ((part.length == 2 && _isAlpha(part)) ||
            (part.length == 3 && int.tryParse(part) != null))) {
      region = part.toUpperCase();
    }
  }
  script ??= _kRegionScripts[primary]?[region];
  return StudyGoalLanguage(primary, script);
}

bool _isAlpha(String s) => RegExp(r'^[A-Za-z]+$').hasMatch(s);

/// 目标语言 [goalTag] 是否计入内容语言 [mediaTag]（见 [StudyGoalLanguage.includes]）。
bool studyGoalLanguageIncludes(String? goalTag, String? mediaTag) {
  final StudyGoalLanguage? goal = resolveStudyGoalLanguage(goalTag);
  return goal != null && goal.includes(resolveStudyGoalLanguage(mediaTag));
}

/// 新目标的默认语言写法：整门语言（`zh-Hans` / `zh-TW` → `zh`，`ja-JP` → `ja`）。
/// 只算某种文字要用户另选。
String? studyGoalCombinedLanguageTag(String? tag) =>
    resolveStudyGoalLanguage(tag)?.combined.tag;

/// 计数口径里「每码点计 1」的文字对应的主语言（与 `study_char_count.dart` 的第 2
/// 类同一判据：汉字 / 假名 / 谚文 / 泰 / 老挝 / 高棉 / 缅甸 / 藏 / 彝）。
const Set<String> _kPerCharLanguages = <String>{
  'ja',
  'zh',
  'yue',
  'wuu',
  'ko',
  'th',
  'lo',
  'km',
  'my',
  'bo',
  'ii',
};

/// [languageTag] 的目标单位。语言未知时按 [StudyGoalUnit.chars]（存量行为）。
StudyGoalUnit studyGoalUnitFor(String? languageTag) {
  final String? primary = studyGoalPrimaryLanguage(languageTag);
  if (primary == null || _kPerCharLanguages.contains(primary)) {
    return StudyGoalUnit.chars;
  }
  return StudyGoalUnit.words;
}

/// 每日目标预设（单位见 [studyGoalUnitFor]）。
///
/// 量级按「大约 20 分钟 / 半小时 / 1 小时 / 2 小时」的学习者阅读量估：
/// - 日语：存量预设 3k / 5k / 10k / 20k 字（≈ 万字 / 时的中级读速）；
/// - 中文：同样信息量的汉字更少（没有假名），2k / 4k / 7k / 14k；
/// - 韩语：谚文按音节计，信息密度介于两者之间，2k / 4k / 8k / 15k；
/// - 空格分词语言按词：1.5k / 3k / 6k / 12k 词（≈ 学习者 100–150 词 / 分钟）。
///
/// [unit] 是用户固定的单位（null = 按语言）：固定成「词」一律给词预设；按字计但
/// 语言是空格分词语言时退回日语量级（没有更合适的参照）。
List<int> studyGoalDailyPresetsFor(String? languageTag, {StudyGoalUnit? unit}) {
  final String? primary = studyGoalPrimaryLanguage(languageTag);
  if ((unit ?? studyGoalUnitFor(languageTag)) == StudyGoalUnit.words) {
    return const <int>[1500, 3000, 6000, 12000];
  }
  return switch (primary) {
    'zh' || 'yue' || 'wuu' => const <int>[2000, 4000, 7000, 14000],
    'ko' => const <int>[2000, 4000, 8000, 15000],
    _ => const <int>[3000, 5000, 10000, 20000],
  };
}

/// 每周目标预设：日语（及按字计的其他非中韩情形）保留存量的 20k / 35k / 70k /
/// 140k，其余按日预设 × 7。
List<int> studyGoalWeeklyPresetsFor(
  String? languageTag, {
  StudyGoalUnit? unit,
}) {
  final List<int> daily = studyGoalDailyPresetsFor(languageTag, unit: unit);
  if (identical(daily, const <int>[3000, 5000, 10000, 20000])) {
    return const <int>[20000, 35000, 70000, 140000];
  }
  return <int>[for (final int d in daily) d * 7];
}

/// 目标分子的语言范围。不可变；app 每次加载统计时随日面一起解析出来。
class StudyGoalLanguageScope {
  const StudyGoalLanguageScope({
    required this.language,
    required this.onlyLanguage,
    this.mediaLanguages = const <String, String>{},
    this.fallbackLanguage,
    this.unitChoice = StudyGoalUnitChoice.auto,
  });

  /// 不限语言、语言未知：存量行为（单位「字」、日语预设、全部行都算）。
  static const StudyGoalLanguageScope all = StudyGoalLanguageScope(
    language: null,
    onlyLanguage: false,
  );

  /// 目标语言（BCP-47，已解析好的有效值）；null = 未知。
  final String? language;

  /// 是否只算 [language] 的内容（见库注释）。[language] 为 null 时无效。
  final bool onlyLanguage;

  /// 媒体身份（[StatFact.mediaKey]）→ 内容语言，只含**已知**语言的媒体。
  /// [onlyLanguage] 关着时不需要，留空。
  final Map<String, String> mediaLanguages;

  /// 媒体没有语言时用的语言（默认内容语言）；null / 空 = 没有兜底，此类媒体不计。
  final String? fallbackLanguage;

  /// 文字目标单位的用户选择（auto = 按 [language]）。
  final StudyGoalUnitChoice unitChoice;

  /// 目标单位。
  StudyGoalUnit get unit => unitChoice.fixed ?? studyGoalUnitFor(language);

  /// 过滤真正生效（开了开关且目标语言已知）。
  bool get filters =>
      onlyLanguage && studyGoalPrimaryLanguage(language) != null;

  /// [f] 是否计入目标分子。
  bool includes(StatFact f) {
    if (!filters) return true;
    final StudyGoalLanguage? media =
        resolveStudyGoalLanguage(mediaLanguages[f.mediaKey]) ??
        resolveStudyGoalLanguage(fallbackLanguage);
    return resolveStudyGoalLanguage(language)!.includes(media);
  }
}

/// 读出书 / 视频 / 游戏的内容语言，键与 [StatFact.mediaKey] 同一身份
/// （书 bookKey、视频 bookUid、游戏 galgames.id）。只收非空语言。
///
/// 三张表各一条只取两列的查询，不拉章节 JSON 等大列。
Future<Map<String, String>> loadStudyGoalMediaLanguages(
  FushiDatabase db,
) async {
  final Map<String, String> out = <String, String>{};
  void addAll(
    List<TypedResult> rows,
    Expression<String> key,
    Expression<String> language,
  ) {
    for (final TypedResult row in rows) {
      final String? k = row.read(key);
      final String? lang = row.read(language);
      if (k == null || k.isEmpty || lang == null || lang.trim().isEmpty) {
        continue;
      }
      out[k] = lang;
    }
  }

  final List<TypedResult> books =
      await (db.selectOnly(db.epubBooks)
            ..addColumns(<Expression<Object>>[
              db.epubBooks.bookKey,
              db.epubBooks.language,
            ])
            ..where(db.epubBooks.language.isNotNull()))
          .get();
  addAll(books, db.epubBooks.bookKey, db.epubBooks.language);
  final List<TypedResult> videos =
      await (db.selectOnly(db.videoBooks)
            ..addColumns(<Expression<Object>>[
              db.videoBooks.bookUid,
              db.videoBooks.language,
            ])
            ..where(db.videoBooks.language.isNotNull()))
          .get();
  addAll(videos, db.videoBooks.bookUid, db.videoBooks.language);
  final List<TypedResult> games =
      await (db.selectOnly(db.galgames)
            ..addColumns(<Expression<Object>>[
              db.galgames.id,
              db.galgames.language,
            ])
            ..where(db.galgames.language.isNotNull()))
          .get();
  addAll(games, db.galgames.id, db.galgames.language);
  return out;
}
