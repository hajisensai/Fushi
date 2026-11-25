/// srs.db 缓存表的行（内核读命令 `read` 的 `cards` / `notes`，native/fushi_fsrs/src/store/reads.rs）。
///
/// 表结构与 SQL 只在内核里（store/schema.rs、store/reads.rs）；Dart 只拿到按列编码的结果，组装成这两个值类。
/// 以前它们是 Drift 生成的数据类（srs.db 上的 Drift 视图已删）：字段、构造函数与 `toJson` 的键保持原样。
library;

/// 卡片缓存的一行（`srs_cards_cache`）。
final class SrsCardCacheRow {
  const SrsCardCacheRow({
    required this.id,
    required this.profileUid,
    required this.noteId,
    required this.templateId,
    required this.clozeOrd,
    required this.deckId,
    required this.suspended,
    this.buriedUntilDay,
    required this.flag,
    required this.hidden,
    required this.queue,
    this.dueDay,
    this.dueAt,
    required this.scheduledDays,
    required this.reps,
    required this.lapses,
    this.stability,
    this.difficulty,
    this.lastReviewedAt,
    this.lastLogId,
    required this.scheduler,
    required this.noteCreatedAt,
    this.newPosition,
    this.freqRank,
  });

  final String id;
  final String profileUid;
  final String noteId;
  final String templateId;
  final int clozeOrd;
  final String deckId;
  final bool suspended;
  final int? buriedUntilDay;
  final int flag;

  /// 生成门（铁律 D）：笔记已删 / 模板已删 / 条件模板为空 / cN 已删时为真，查询层据此不显示、不进队列。
  final bool hidden;
  final String queue;
  final int? dueDay;
  final int? dueAt;
  final int scheduledDays;
  final int reps;
  final int lapses;
  final double? stability;
  final double? difficulty;
  final int? lastReviewedAt;
  final String? lastLogId;
  final String scheduler;

  /// 新卡出卡顺序的兜底键（笔记 createdAt, cardId）：没有 [newPosition] 的新卡按它排。
  final int noteCreatedAt;

  /// 新卡在出卡队列里的位置（卡片修改记录 `newPos` 的生效值）。null = 从没排过。
  final int? newPosition;

  /// 笔记词频序字段解析出的名次，越小越常见；null = 没有。
  final int? freqRank;

  /// [toJson] 的逆（远端 store 的回包，packages/fushi_engine/lib/srs/srs_remote_store.dart）。
  factory SrsCardCacheRow.fromJson(Map<String, Object?> json) =>
      SrsCardCacheRow(
        id: json['id']! as String,
        profileUid: json['profileUid']! as String,
        noteId: json['noteId']! as String,
        templateId: json['templateId']! as String,
        clozeOrd: json['clozeOrd']! as int,
        deckId: json['deckId']! as String,
        suspended: json['suspended']! as bool,
        buriedUntilDay: json['buriedUntilDay'] as int?,
        flag: json['flag']! as int,
        hidden: json['hidden']! as bool,
        queue: json['queue']! as String,
        dueDay: json['dueDay'] as int?,
        dueAt: json['dueAt'] as int?,
        scheduledDays: json['scheduledDays']! as int,
        reps: json['reps']! as int,
        lapses: json['lapses']! as int,
        stability: (json['stability'] as num?)?.toDouble(),
        difficulty: (json['difficulty'] as num?)?.toDouble(),
        lastReviewedAt: json['lastReviewedAt'] as int?,
        lastLogId: json['lastLogId'] as String?,
        scheduler: json['scheduler']! as String,
        noteCreatedAt: json['noteCreatedAt']! as int,
        newPosition: json['newPosition'] as int?,
        freqRank: json['freqRank'] as int?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'profileUid': profileUid,
    'noteId': noteId,
    'templateId': templateId,
    'clozeOrd': clozeOrd,
    'deckId': deckId,
    'suspended': suspended,
    'buriedUntilDay': buriedUntilDay,
    'flag': flag,
    'hidden': hidden,
    'queue': queue,
    'dueDay': dueDay,
    'dueAt': dueAt,
    'scheduledDays': scheduledDays,
    'reps': reps,
    'lapses': lapses,
    'stability': stability,
    'difficulty': difficulty,
    'lastReviewedAt': lastReviewedAt,
    'lastLogId': lastLogId,
    'scheduler': scheduler,
    'noteCreatedAt': noteCreatedAt,
    'newPosition': newPosition,
    'freqRank': freqRank,
  };

  List<Object?> get _props => <Object?>[
    id,
    profileUid,
    noteId,
    templateId,
    clozeOrd,
    deckId,
    suspended,
    buriedUntilDay,
    flag,
    hidden,
    queue,
    dueDay,
    dueAt,
    scheduledDays,
    reps,
    lapses,
    stability,
    difficulty,
    lastReviewedAt,
    lastLogId,
    scheduler,
    noteCreatedAt,
    newPosition,
    freqRank,
  ];

  @override
  bool operator ==(Object other) =>
      other is SrsCardCacheRow && _listEquals(_props, other._props);

  @override
  int get hashCode => Object.hashAll(_props);

  @override
  String toString() => 'SrsCardCacheRow(${toJson()})';
}

/// 笔记缓存的一行（`srs_notes_cache`）。
final class SrsNoteCacheRow {
  const SrsNoteCacheRow({
    required this.id,
    required this.profileUid,
    required this.noteTypeId,
    required this.guid,
    required this.createdAt,
    this.deckId,
    this.deletedAt,
    required this.termKey,
    required this.readingKey,
    required this.sortField,
    required this.tagsJson,
    required this.pendingDecision,
    required this.updatedAt,
    required this.mediaRefs,
  });

  final String id;
  final String profileUid;
  final String noteTypeId;
  final String guid;
  final int createdAt;
  final String? deckId;
  final int? deletedAt;

  /// 词状态索引：词形 / 读音归一化。
  final String termKey;
  final String readingKey;

  /// 排序 / 列表显示用的第一个字段（去 HTML）。
  final String sortField;
  final String tagsJson;
  final bool pendingDecision;
  final int updatedAt;

  /// 这条笔记当前字段值引用的媒体文件名（换行分隔，去重排序）。已删笔记为空。
  final String mediaRefs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'profileUid': profileUid,
    'noteTypeId': noteTypeId,
    'guid': guid,
    'createdAt': createdAt,
    'deckId': deckId,
    'deletedAt': deletedAt,
    'termKey': termKey,
    'readingKey': readingKey,
    'sortField': sortField,
    'tagsJson': tagsJson,
    'pendingDecision': pendingDecision,
    'updatedAt': updatedAt,
    'mediaRefs': mediaRefs,
  };

  List<Object?> get _props => <Object?>[
    id,
    profileUid,
    noteTypeId,
    guid,
    createdAt,
    deckId,
    deletedAt,
    termKey,
    readingKey,
    sortField,
    tagsJson,
    pendingDecision,
    updatedAt,
    mediaRefs,
  ];

  @override
  bool operator ==(Object other) =>
      other is SrsNoteCacheRow && _listEquals(_props, other._props);

  @override
  int get hashCode => Object.hashAll(_props);

  @override
  String toString() => 'SrsNoteCacheRow(${toJson()})';
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
