/// 设置 › 目标「我的目标」按语言分组（第五轮）：纯数据，不碰 widget。
///
/// 分组规则（一处定义，设置行与测试共用）：
/// - 指定了语言的目标按**主语言**归组（「只算简体」的中文目标也在「中文」组里）；
///   组的先后 = 该语言第一条目标在列表里出现的先后（用户排的顺序就是真值）；
/// - 之后是「全部语言」组（分语言的度量、没指定语言）；
/// - 最后是「不分语言」组（复习 / 制卡：本来就没有语言）。它不并进「全部语言」：
///   「全部语言」是「各语言加总」，复习 / 制卡没有语言可加总，放一起会误导。
///
/// 顺序只有一份真值：目标记录列表本身（[StudyGoal] 的先后）。组内重排
/// （[reorderStudyGoalsInGroup]）只在该组占着的那些位置之间挪，别的组的位置不动。
library;

import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show studyGoalPrimaryLanguage;

/// 组的种类。
enum StudyGoalGroupKind { language, allLanguages, anyLanguage }

/// 一组目标。
class StudyGoalGroup {
  const StudyGoalGroup({
    required this.id,
    required this.kind,
    required this.goals,
    this.language,
  });

  /// 组的稳定 id：语言组 = 主语言标签（`zh` / `ja`），另两组 = `all` / `any`。
  /// 折叠状态与测试 key 都按它认。
  final String id;
  final StudyGoalGroupKind kind;

  /// 语言组的主语言标签；另两组为 null。
  final String? language;

  /// 组内目标（保持记录列表里的先后）。
  final List<StudyGoal> goals;

  List<String> get goalIds => <String>[for (final StudyGoal g in goals) g.id];
}

/// 「全部语言」组的 id。
const String kStudyGoalGroupAll = 'all';

/// 「不分语言」组的 id。
const String kStudyGoalGroupAny = 'any';

/// [goal] 归哪一组（[StudyGoalGroup.id]）。
String studyGoalGroupIdOf(StudyGoal goal) {
  if (!goal.metric.languageScoped) return kStudyGoalGroupAny;
  return studyGoalPrimaryLanguage(goal.language) ?? kStudyGoalGroupAll;
}

/// 把 [goals] 分组：语言组（按首次出现）→ 全部语言 → 不分语言；空组不出现。
List<StudyGoalGroup> groupStudyGoals(List<StudyGoal> goals) {
  final Map<String, List<StudyGoal>> byId = <String, List<StudyGoal>>{};
  for (final StudyGoal goal in goals) {
    byId.putIfAbsent(studyGoalGroupIdOf(goal), () => <StudyGoal>[]).add(goal);
  }
  final List<StudyGoalGroup> out = <StudyGoalGroup>[
    for (final MapEntry<String, List<StudyGoal>> e in byId.entries)
      if (e.key != kStudyGoalGroupAll && e.key != kStudyGoalGroupAny)
        StudyGoalGroup(
          id: e.key,
          kind: StudyGoalGroupKind.language,
          language: e.key,
          goals: e.value,
        ),
  ];
  final List<StudyGoal>? all = byId[kStudyGoalGroupAll];
  if (all != null) {
    out.add(
      StudyGoalGroup(
        id: kStudyGoalGroupAll,
        kind: StudyGoalGroupKind.allLanguages,
        goals: all,
      ),
    );
  }
  final List<StudyGoal>? any = byId[kStudyGoalGroupAny];
  if (any != null) {
    out.add(
      StudyGoalGroup(
        id: kStudyGoalGroupAny,
        kind: StudyGoalGroupKind.anyLanguage,
        goals: any,
      ),
    );
  }
  return out;
}

/// 组内把第 [from] 条挪到**最终下标** [to]（`FushiReorderableColumn` 语义），落回完整
/// 记录列表：只重排 [groupIds] 那些目标占着的位置，其余目标位置不动。返回新的 id
/// 顺序（[AppModel.reorderStudyGoals] 的入参）。越界 / 无变化原样返回。
List<String> reorderStudyGoalsInGroup({
  required List<String> allIds,
  required List<String> groupIds,
  required int from,
  required int to,
}) {
  if (from == to ||
      from < 0 ||
      to < 0 ||
      from >= groupIds.length ||
      to >= groupIds.length) {
    return <String>[...allIds];
  }
  final List<String> moved = <String>[...groupIds];
  moved.insert(to, moved.removeAt(from));
  final Set<String> slots = groupIds.toSet();
  int next = 0;
  return <String>[
    for (final String id in allIds) slots.contains(id) ? moved[next++] : id,
  ];
}
