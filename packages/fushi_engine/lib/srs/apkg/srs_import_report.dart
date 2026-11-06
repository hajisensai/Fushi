/// Anki 导入报告（可序列化给 UI 显示）。
library;

import 'package:fushi_engine/srs/apkg/srs_import_options.dart';
import 'package:fushi_srs/fushi_srs.dart';

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

  /// 已存在、按「更新笔记」选项没更新（或来源内容与本机相同）：本地字段不动。
  int notesSkipped = 0;

  /// 先前导入过、后来在本机删掉，这次恢复的笔记数（不计入 [notesAdded] / [notesUpdated]）。
  int notesRestored = 0;

  /// 「从 Anki 迁移」选了「导入后把旧 Lapis 迁到 Fushi 卡片」：迁过去 / 补迁的笔记数。
  int lapisNotesMigrated = 0;

  /// 同时选了「牌组名里的 Lapis 改成 Fushi Card」：改名的牌组数。
  int lapisDecksRenamed = 0;

  /// 上面那一步失败（导入本身已落库；笔记仍是旧 Lapis，可在笔记类型页重试）。
  bool lapisMigrationFailed = false;

  /// 本次用的选项。
  SrsAnkiImportOptions options = const SrsAnkiImportOptions();

  /// 有修改写入的已有笔记类型数（「更新笔记模板」放行、或合并时来源新增字段 / 模板）。
  int noteTypesUpdated = 0;

  /// 「不合并笔记模板」时因结构不同另建的笔记类型（来源名字）。
  final List<String> noteTypesDuplicated = <String>[];

  /// 先前导入过、后来在本机删掉，这次恢复的笔记类型（来源名字）。它的笔记一并按「恢复」导回
  /// （计入 [notesRestored]）。
  final List<String> noteTypesRestored = <String>[];

  /// 不含排程：来源里学过 / 暂停过、本次作为新卡导入的卡片数。
  int cardsResetToNew = 0;

  /// 不含排程：包里没导入的 revlog 条数。
  int reviewLogsSkipped = 0;

  /// 不含牌组预设：新建牌组没用上的来源预设个数。
  int deckPresetsSkipped = 0;

  /// 新增笔记带来的卡片数。
  int cardsAdded = 0;

  /// 本机已有、从没排过位置的新卡补上了来源的新卡位置（重新导入时的补救）。
  int newPositionsRepaired = 0;

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

  /// 开了 RWKV 的预设名（导入后照旧用 RWKV）。
  final List<String> rwkvPresets = <String>[];

  /// 带着 FSRS 参数导入、改用 RWKV 的预设：预设名 → 原算法（FSRS-6 / FSRS-7）。参数照样存下。
  final Map<String, SrsAlgorithm> fsrsPresets = <String, SrsAlgorithm>{};

  /// 没有可用 FSRS 参数（SM-2 或没训练过）、导入后用默认算法的预设名。
  final List<String> defaultAlgorithmPresets = <String>[];

  /// 导入时关了 RWKV（[SrsAnkiImportOptions.useRwkv]）：Anki 里开了 RWKV、改用 FSRS-7 的预设名。
  final List<String> rwkvPresetsOnFsrs = <String>[];

  /// 导入时关了 RWKV：没有可用 FSRS 参数、用 FSRS-7 默认参数的预设名。
  final List<String> defaultFsrsPresets = <String>[];

  /// 本次新建、自己管参数、由 FSRS 预设改用 RWKV 的牌组：牌组 ID → 原算法
  /// （导入报告的「继续用 FSRS」按这份改回）。
  final Map<String, SrsAlgorithm> fsrsDecks = <String, SrsAlgorithm>{};

  /// 参数校验不过、没写参数的预设：预设名 → 原因。
  final Map<String, String> invalidParams = <String, String>{};

  final List<SrsImportRemovedItem> removedInSource = <SrsImportRemovedItem>[];

  /// 来源时刻晚于本机可信时间 10 分钟以上、没导入排程的卡（来源卡片数字 id）。
  final List<int> futureCards = <int>[];

  Map<String, Object?> toJson() => <String, Object?>{
    'notesAdded': notesAdded,
    'notesUpdated': notesUpdated,
    'notesSkipped': notesSkipped,
    'notesRestored': notesRestored,
    'lapisNotesMigrated': lapisNotesMigrated,
    'lapisMigrationFailed': lapisMigrationFailed,
    'options': options.toJson(),
    'noteTypesUpdated': noteTypesUpdated,
    'noteTypesDuplicated': noteTypesDuplicated,
    'noteTypesRestored': noteTypesRestored,
    'cardsResetToNew': cardsResetToNew,
    'reviewLogsSkipped': reviewLogsSkipped,
    'deckPresetsSkipped': deckPresetsSkipped,
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
    'rwkvPresets': rwkvPresets,
    'fsrsPresets': <String, String>{
      for (final MapEntry<String, SrsAlgorithm> e in fsrsPresets.entries)
        e.key: e.value.wire,
    },
    'defaultAlgorithmPresets': defaultAlgorithmPresets,
    'rwkvPresetsOnFsrs': rwkvPresetsOnFsrs,
    'defaultFsrsPresets': defaultFsrsPresets,
    'fsrsDecks': <String, String>{
      for (final MapEntry<String, SrsAlgorithm> e in fsrsDecks.entries)
        e.key: e.value.wire,
    },
    'invalidParams': invalidParams,
    'removedInSource': <Map<String, Object?>>[
      for (final SrsImportRemovedItem r in removedInSource) r.toJson(),
    ],
    'futureCards': futureCards,
  };
}
