import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/study_goal_language.dart';

/// 一种目标语言的分子范围（[language] 为 null = 全部语言，不过滤）。没有自身语言的
/// 内容按默认内容语言判定（[StudyGoalLanguageScope.fallbackLanguage]）；单位跟全局
/// 文字单位选择（auto = 按 [language]）。
///
/// 只读偏好（[PreferencesRepository]），不碰 AppModel：本文件在统计层，被设置 schema /
/// 首页 / 小组件快照共用，接 AppModel 会把它拖进大 import 环。
StudyGoalLanguageScope studyGoalScopeFor(
  String? language,
  PreferencesRepository prefs, {
  Map<String, String> mediaLanguages = const <String, String>{},
}) {
  final String tag = language?.trim() ?? '';
  return StudyGoalLanguageScope(
    language: tag.isEmpty ? null : tag,
    onlyLanguage: tag.isNotEmpty,
    fallbackLanguage: prefs.defaultContentLanguage,
    unitChoice: prefs.readingGoalTextUnit,
    mediaLanguages: mediaLanguages,
  );
}

/// 媒体身份 → 内容语言。只有某条目标限定了语言时才查库（全部语言的目标不过滤）。
Future<Map<String, String>> loadStudyGoalMediaLanguagesFor(
  FushiDatabase db,
  Iterable<StudyGoal> goals,
) async {
  if (!goals.any((StudyGoal g) => g.language != null)) {
    return const <String, String>{};
  }
  return loadStudyGoalMediaLanguages(db);
}

/// 新建目标 / 「语言目标」格可选的语言：已有目标用到的语言 ∪ 默认内容语言 ∪ 绑到
/// 当前 Profile 的语言（`language_profiles`）。后两者一律取整门语言（`zh-Hans` /
/// `zh-TW` → `zh`，`ja-JP` → `ja`；只算某种文字要用户另选）；已有目标照它自己的
/// 写法（规范化：`zh-TW` 记成 `zh-Hant`）。按 [resolveStudyGoalLanguage] 去重，顺序 =
/// 上面的来源顺序。
Future<List<String>> loadStudyGoalCandidateLanguages(
  FushiDatabase db,
  PreferencesRepository prefs,
) async {
  final int profileId = await db.resolveActiveProfileId();
  final List<LanguageProfileRow> bound = await db.getAllLanguageProfiles();
  return studyGoalCandidateLanguages(
    goals: prefs.studyGoals,
    defaultContentLanguage: prefs.defaultContentLanguage,
    profileLanguages: <String>[
      for (final LanguageProfileRow row in bound)
        if (row.profileId == profileId) row.languageTag,
    ],
  );
}

/// [loadStudyGoalCandidateLanguages] 的纯函数部分。
List<String> studyGoalCandidateLanguages({
  required Iterable<StudyGoal> goals,
  required String defaultContentLanguage,
  required Iterable<String> profileLanguages,
}) {
  final List<String> out = <String>[];
  final Set<StudyGoalLanguage> seen = <StudyGoalLanguage>{};
  void add(String? tag, {required bool combined}) {
    final StudyGoalLanguage? resolved = resolveStudyGoalLanguage(tag);
    if (resolved == null) return;
    final StudyGoalLanguage key = combined ? resolved.combined : resolved;
    if (!seen.add(key)) return;
    out.add(key.tag);
  }

  for (final StudyGoal g in goals) {
    add(g.language, combined: false);
  }
  add(defaultContentLanguage, combined: true);
  for (final String tag in profileLanguages) {
    add(tag, combined: true);
  }
  return out;
}

/// [a] 与 [b] 是不是同一种目标语言（[resolveStudyGoalLanguage] 相同：`ja-JP` = `ja`，
/// `zh-TW` = `zh-Hant`，但 `zh` ≠ `zh-Hans`；都为 null = 都是全部语言）。
bool studyGoalSameLanguage(String? a, String? b) =>
    resolveStudyGoalLanguage(a) == resolveStudyGoalLanguage(b);

/// [language] 可另选的「只算某种文字」写法（`zh` → `zh-Hans`、`zh-Hant`）；没有文字
/// 之分的语言为空。数据见 [kStudyGoalScriptVariants]。
List<String> studyGoalScriptVariantsOf(String? language) {
  final StudyGoalLanguage? resolved = resolveStudyGoalLanguage(language);
  if (resolved == null) return const <String>[];
  return <String>[
    for (final String script
        in kStudyGoalScriptVariants[resolved.primary] ?? const <String>[])
      StudyGoalLanguage(resolved.primary, script).tag,
  ];
}
