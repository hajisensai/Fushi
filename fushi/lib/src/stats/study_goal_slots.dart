/// 学习目标的「算什么」（`StudyGoal.metric`）。纯 Dart（偏好层也要读）。
library;

/// 目标的度量（wire 值与小组件快照 `goals[].id`、记录 JSON 的 `metric` 同值，冻结）。
enum StudyGoalId {
  total('total'),
  reading('reading'),
  listening('listening'),
  watching('watching'),
  reviews('reviews'),
  mined('mined'),
  chars('chars');

  const StudyGoalId(this.wire);
  final String wire;

  /// 时长类目标：进度的 value / target 是毫秒。
  bool get isTime =>
      this == total || this == reading || this == listening || this == watching;

  /// 能按语言过滤（字数与时长按媒体内容语言；复习 / 制卡没有语言）。
  bool get languageScoped => this != reviews && this != mined;

  static StudyGoalId? fromWire(String wire) {
    for (final StudyGoalId g in values) {
      if (g.wire == wire) return g;
    }
    return null;
  }
}
