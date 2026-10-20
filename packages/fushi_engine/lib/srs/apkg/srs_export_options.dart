/// 导出 Anki 包的选项（与导入的 [SrsAnkiImportOptions] 对称；所有者 2026-10-20：
/// 「导出同理，支持是否兼容 anki 等开关，这些开关都会记忆」）。
///
/// 默认值 = 此前唯一的导出行为：带学习进度、带牌组预设与参数、附带 fushi-ext。
library;

class SrsAnkiExportOptions {
  const SrsAnkiExportOptions({
    this.withScheduling = true,
    this.withDeckConfigs = true,
    this.ankiCompatible = false,
  });

  /// 导出复习记录与排程（含暂停）。关闭时所有卡片作为新卡导出（按原出卡顺序）、不写
  /// revlog，fushi-ext 也不带日志。
  final bool withScheduling;

  /// 导出牌组预设（步长 / 上限 / 最大间隔 / 期望保留率 / FSRS 参数…）。关闭时每个牌组
  /// 写 Anki 默认预设，fushi-ext 也不带牌组设置。
  final bool withDeckConfigs;

  /// 只写 Anki 认识的内容：不附带 fushi-ext（Fushi 完整日志、FSRS-7 参数等牌组原值、
  /// 笔记出处）。Anki 本来就忽略 fushi-ext；它只决定回导 Fushi 时能否无损恢复。
  final bool ankiCompatible;

  SrsAnkiExportOptions copyWith({
    bool? withScheduling,
    bool? withDeckConfigs,
    bool? ankiCompatible,
  }) => SrsAnkiExportOptions(
    withScheduling: withScheduling ?? this.withScheduling,
    withDeckConfigs: withDeckConfigs ?? this.withDeckConfigs,
    ankiCompatible: ankiCompatible ?? this.ankiCompatible,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'withScheduling': withScheduling,
    'withDeckConfigs': withDeckConfigs,
    'ankiCompatible': ankiCompatible,
  };

  /// 缺项 / 坏值回落到默认值。
  static SrsAnkiExportOptions fromJson(Map<String, Object?> json) {
    const SrsAnkiExportOptions d = SrsAnkiExportOptions();
    bool b(String k, bool fallback) {
      final Object? v = json[k];
      return v is bool ? v : fallback;
    }

    return SrsAnkiExportOptions(
      withScheduling: b('withScheduling', d.withScheduling),
      withDeckConfigs: b('withDeckConfigs', d.withDeckConfigs),
      ankiCompatible: b('ankiCompatible', d.ankiCompatible),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsAnkiExportOptions &&
      other.withScheduling == withScheduling &&
      other.withDeckConfigs == withDeckConfigs &&
      other.ankiCompatible == ankiCompatible;

  @override
  int get hashCode =>
      Object.hash(withScheduling, withDeckConfigs, ankiCompatible);
}
