/// Anki 包导入选项（对齐 Anki 23.10+ 新导入器的 `ImportAnkiPackageOptions`，
/// rslib `import_export/package/apkg/import`）。
///
/// 默认值与 Anki 一致：rslib 的这几个 BoolKey 不在「默认为真」名单里，
/// UpdateCondition 的零值是 IF_NEWER。
library;

/// 已存在的笔记 / 笔记类型什么时候用导入内容更新（Anki `UpdateCondition`）。
enum SrsImportUpdateCondition {
  /// 来源的修改时刻晚于本机最后一次修改。
  ifNewer('ifNewer'),

  /// 内容不同就更新。
  always('always'),

  /// 从不更新已有的。
  never('never');

  const SrsImportUpdateCondition(this.wire);

  /// 持久化值（冻结）。
  final String wire;

  static SrsImportUpdateCondition? tryParse(Object? wire) {
    for (final SrsImportUpdateCondition c in values) {
      if (c.wire == wire) return c;
    }
    return null;
  }

  /// [localMs] = 本机最后修改时刻，[sourceMs] = 来源修改时刻（都是毫秒）。
  bool shouldUpdate({required int localMs, required int sourceMs}) =>
      switch (this) {
        SrsImportUpdateCondition.ifNewer => localMs < sourceMs,
        SrsImportUpdateCondition.always => true,
        SrsImportUpdateCondition.never => false,
      };
}

class SrsAnkiImportOptions {
  const SrsAnkiImportOptions({
    this.mergeNoteTypes = false,
    this.updateNotes = SrsImportUpdateCondition.ifNewer,
    this.updateNoteTypes = SrsImportUpdateCondition.ifNewer,
    this.withScheduling = false,
    this.withDeckConfigs = false,
  });

  /// 来源笔记类型与本机同一笔记类型的字段 / 模板不一致时：
  /// - true：合并进本机那一个（来源新增的字段 / 模板加进来，本机多出来的保留）；
  /// - false：来源笔记类型另建一份（确定性 ID），本机那一个不动；已存在的同 guid 笔记
  ///   记为冲突、不更新（与 Anki 相同）。
  final bool mergeNoteTypes;

  final SrsImportUpdateCondition updateNotes;

  /// 笔记类型的名字、CSS、模板正文、字段 / 模板的名字与顺序。来源新增的字段 / 模板
  /// （合并时）不受它限制——不加进来笔记就存不下。
  final SrsImportUpdateCondition updateNoteTypes;

  /// 导入复习记录与排程（含暂停）。关闭时一律作为新卡导入、不写复习日志，
  /// 并去掉 marked / leech 系统标签（与 Anki 相同）。
  final bool withScheduling;

  /// 新建的牌组写入来源预设（步长 / 上限 / 算法 / 参数…）；关闭时用本机默认设置。
  final bool withDeckConfigs;

  SrsAnkiImportOptions copyWith({
    bool? mergeNoteTypes,
    SrsImportUpdateCondition? updateNotes,
    SrsImportUpdateCondition? updateNoteTypes,
    bool? withScheduling,
    bool? withDeckConfigs,
  }) => SrsAnkiImportOptions(
    mergeNoteTypes: mergeNoteTypes ?? this.mergeNoteTypes,
    updateNotes: updateNotes ?? this.updateNotes,
    updateNoteTypes: updateNoteTypes ?? this.updateNoteTypes,
    withScheduling: withScheduling ?? this.withScheduling,
    withDeckConfigs: withDeckConfigs ?? this.withDeckConfigs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'mergeNoteTypes': mergeNoteTypes,
    'updateNotes': updateNotes.wire,
    'updateNoteTypes': updateNoteTypes.wire,
    'withScheduling': withScheduling,
    'withDeckConfigs': withDeckConfigs,
  };

  /// 缺项 / 坏值回落到默认值。
  static SrsAnkiImportOptions fromJson(Map<String, Object?> json) {
    const SrsAnkiImportOptions d = SrsAnkiImportOptions();
    bool b(String k, bool fallback) {
      final Object? v = json[k];
      return v is bool ? v : fallback;
    }

    return SrsAnkiImportOptions(
      mergeNoteTypes: b('mergeNoteTypes', d.mergeNoteTypes),
      updateNotes:
          SrsImportUpdateCondition.tryParse(json['updateNotes']) ??
          d.updateNotes,
      updateNoteTypes:
          SrsImportUpdateCondition.tryParse(json['updateNoteTypes']) ??
          d.updateNoteTypes,
      withScheduling: b('withScheduling', d.withScheduling),
      withDeckConfigs: b('withDeckConfigs', d.withDeckConfigs),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsAnkiImportOptions &&
      other.mergeNoteTypes == mergeNoteTypes &&
      other.updateNotes == updateNotes &&
      other.updateNoteTypes == updateNoteTypes &&
      other.withScheduling == withScheduling &&
      other.withDeckConfigs == withDeckConfigs;

  @override
  int get hashCode => Object.hash(
    mergeNoteTypes,
    updateNotes,
    updateNoteTypes,
    withScheduling,
    withDeckConfigs,
  );
}
