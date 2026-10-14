/// Anki 导入报告（可序列化给 UI 显示）。
library;

/// 一条不导入 / 有冲突的笔记。
class SrsImportNoteIssue {
  const SrsImportNoteIssue({
    required this.guid,
    required this.noteType,
    required this.reason,
  });

  final String guid;
  final String noteType;

  /// [SrsImportIssueReason] 之一。
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'guid': guid,
    'noteType': noteType,
    'reason': reason,
  };
}

/// 报告里的原因代码（UI 按它选文案；冻结）。
abstract final class SrsImportIssueReason {
  /// 本机同 ID 的笔记类型是另一种 kind（普通 ↔ 填空）。
  static const String noteTypeKindMismatch = 'noteTypeKindMismatch';

  /// 同 guid 的本机笔记属于别的笔记类型。
  static const String noteTypeChanged = 'noteTypeChanged';

  /// 来源笔记引用了包里不存在的笔记类型。
  static const String missingNoteType = 'missingNoteType';
}

/// 被截掉的步长（≥ 1 天的项）。
class SrsImportTruncatedSteps {
  const SrsImportTruncatedSteps({
    required this.preset,
    required this.kind,
    required this.removed,
    required this.kept,
  });

  final String preset;

  /// 'learn' / 'relearn'。
  final String kind;
  final List<double> removed;
  final List<double> kept;

  Map<String, Object?> toJson() => <String, Object?>{
    'preset': preset,
    'kind': kind,
    'removed': removed,
    'kept': kept,
  };
}

/// 来源已删、本机保留的字段 / 模板。
class SrsImportRemovedItem {
  const SrsImportRemovedItem({
    required this.noteType,
    required this.name,
    required this.isTemplate,
  });

  final String noteType;
  final String name;
  final bool isTemplate;

  Map<String, Object?> toJson() => <String, Object?>{
    'noteType': noteType,
    'name': name,
    'template': isTemplate,
  };
}

class SrsImportReport {
  int notesAdded = 0;
  int notesUpdated = 0;

  /// 已存在且未开 updateExisting：本地字段不动。
  int notesSkipped = 0;

  /// 新增笔记带来的卡片数。
  int cardsAdded = 0;

  /// 写入的来源 revlog 日志数（被识别为本机原生 / fushi-ext 已有的不算）。
  int reviewLogsImported = 0;
  int anchorsWritten = 0;

  /// 从 fushi-ext 恢复的 Fushi 日志数。
  int fushiLogsRestored = 0;

  /// 与 fushi-ext 一一对上的 revlog 数（只作校验）。
  int revlogsVerifiedByExt = 0;

  /// 包里有 fushi-ext、却对不上任何 Fushi 日志的 revlog（Anki 端导出后又复习的），按普通 revlog 导入。
  int revlogsNotInExt = 0;

  int mediaStored = 0;

  /// 被引用但包里没有的媒体文件名。
  final Set<String> mediaMissing = <String>{};

  /// 新格式（collection.anki21b）。
  bool latestFormat = false;

  final List<SrsImportNoteIssue> conflictNotes = <SrsImportNoteIssue>[];
  final List<SrsImportTruncatedSteps> truncatedSteps =
      <SrsImportTruncatedSteps>[];

  /// 开了 RWKV、改用 FSRS 的预设名。
  final List<String> rwkvPresetsFellBack = <String>[];

  /// 参数校验不过、没写参数的预设：预设名 → 原因。
  final Map<String, String> invalidParams = <String, String>{};

  final List<SrsImportRemovedItem> removedInSource = <SrsImportRemovedItem>[];

  /// 来源时刻晚于本机可信时间 10 分钟以上、没导入排程的卡（来源卡片数字 id）。
  final List<int> futureCards = <int>[];

  Map<String, Object?> toJson() => <String, Object?>{
    'notesAdded': notesAdded,
    'notesUpdated': notesUpdated,
    'notesSkipped': notesSkipped,
    'cardsAdded': cardsAdded,
    'reviewLogsImported': reviewLogsImported,
    'anchorsWritten': anchorsWritten,
    'fushiLogsRestored': fushiLogsRestored,
    'revlogsVerifiedByExt': revlogsVerifiedByExt,
    'revlogsNotInExt': revlogsNotInExt,
    'mediaStored': mediaStored,
    'mediaMissing': mediaMissing.toList()..sort(),
    'latestFormat': latestFormat,
    'conflictNotes': <Map<String, Object?>>[
      for (final SrsImportNoteIssue i in conflictNotes) i.toJson(),
    ],
    'truncatedSteps': <Map<String, Object?>>[
      for (final SrsImportTruncatedSteps s in truncatedSteps) s.toJson(),
    ],
    'rwkvPresetsFellBack': rwkvPresetsFellBack,
    'invalidParams': invalidParams,
    'removedInSource': <Map<String, Object?>>[
      for (final SrsImportRemovedItem r in removedInSource) r.toJson(),
    ],
    'futureCards': futureCards,
  };
}
