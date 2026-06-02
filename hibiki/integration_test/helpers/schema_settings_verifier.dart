/// 单个设置项的五步判定结论。
class ItemVerdict {
  ItemVerdict({
    required this.id,
    required this.controlType,
    required this.reached,
    required this.changed,
    required this.persisted,
    required this.effectVerified,
    required this.restored,
    required this.note,
  });

  final String id;
  final String controlType;
  final bool reached;
  final bool changed;
  final bool persisted;
  final bool effectVerified;
  final bool restored;
  final String note;

  /// PASS = 五步全绿（设计 §5：只写穿 DB 不算过）。
  bool get isPass =>
      reached && changed && persisted && effectVerified && restored;

  @override
  String toString() => '[$controlType] $id '
      'reached=$reached changed=$changed persisted=$persisted '
      'effect=$effectVerified restored=$restored '
      '${isPass ? "PASS" : "FAIL"}${note.isEmpty ? "" : " — $note"}';
}

/// 纯逻辑校验器：给定读值/改值/生效探针/还原四个闭包，跑五步判定。
/// reached 由调用方（焦点驱动器）传入，这里默认 true 供逻辑测试用。
ItemVerdict verifyItemLogic({
  required String id,
  required String controlType,
  required Object? Function() readValue,
  required void Function() applyChange,
  required bool Function()? effect,
  required void Function(Object? before) restore,
  bool reached = true,
}) {
  final Object? before = readValue();
  applyChange();
  final Object? after = readValue();
  final bool changed = before != after;
  // persisted：本逻辑层用“值确实变了”近似；集成层用 prefsSnapshot 回读 diff。
  final bool persisted = changed;

  final bool hasProbe = effect != null;
  final bool effectVerified = hasProbe && effect();

  restore(before);
  final bool restored = readValue() == before;

  final String note = hasProbe ? '' : 'EFFECT UNVERIFIED: no probe for $id';
  return ItemVerdict(
    id: id,
    controlType: controlType,
    reached: reached,
    changed: changed,
    persisted: persisted,
    effectVerified: effectVerified,
    restored: restored,
    note: note,
  );
}
