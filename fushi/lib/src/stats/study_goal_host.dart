/// 目标面板 / 「语言目标」格语言选择要的那一小块宿主能力（[AppModel] 实现，调用方
/// 注入）。
///
/// 目标面板与共用视觉件被设置 schema（本就在大 import 环里）import；它们若直接
/// import AppModel，就跟着进环。只认这个窄接口，环不随目标功能变大。
library;

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show StudyGoalUnitChoice;

abstract interface class StudyGoalHost {
  /// 主库（候选语言、日面、媒体语言表）。
  FushiDatabase get database;

  /// 偏好仓库（目标分子的语言范围 / 单位）。
  PreferencesRepository get prefsRepo;

  /// 目标记录（按用户排的顺序）。
  List<StudyGoal> get studyGoals;

  /// 追加一条目标（列表末尾）。
  Future<void> addStudyGoal(StudyGoal goal);

  /// 按 id 整条替换。
  Future<void> updateStudyGoal(StudyGoal goal);

  /// 按 id 删除。
  Future<void> removeStudyGoal(String id);

  /// 放回第 [index] 位（删除后撤销）。
  Future<void> insertStudyGoal(StudyGoal goal, int index);

  /// 全局文字单位选择（auto / 字 / 词）。
  StudyGoalUnitChoice get readingGoalTextUnit;

  /// 默认内容语言（没有自身语言的内容按它算）。
  String get defaultContentLanguage;

  /// 复习目标此刻为什么在首页上不出现（null = 正常出现）。
  StudyGoalReviewsHidden? get studyGoalReviewsHidden;
}
