/// SRS 的 9 张表（Drift 声明，执行在 Rust 独占的 srs.db 上，见
/// docs/specs/2026-10-23-srs-rust-store.md）。列与 native/fushi_fsrs/src/store/schema.rs 逐列相同。
library;

import 'package:drift/drift.dart';

// ── SRS（v117，docs/specs/2026-10-14-fushi-srs-design.md）──────────────
//
// 同步的只有三种事件：身份记录（srs_entities）、修改记录（srs_field_edits）、复习日志（srs_review_logs）。
// 卡片行、笔记缓存都是本机可重建的缓存，不同步。事件创建即不可变：同 ID 内容必须相同。

/// 不可变身份记录（牌组 / 笔记类型 / 笔记）。
@DataClassName('SrsEntityRow')
class SrsEntities extends Table {
  TextColumn get id => text()();
  TextColumn get profileUid => text()();

  /// deck / notetype / note（SrsEntityKind.wire）。
  TextColumn get kind => text()();

  /// 规范 JSON（SrsEntityRecord.payload）。
  TextColumn get payloadJson => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 修改记录（铁律 H）。只保留同一字段键上没被支配的记录。
@DataClassName('SrsFieldEditRow')
class SrsFieldEdits extends Table {
  TextColumn get id => text()();
  TextColumn get profileUid => text()();
  TextColumn get entityKind => text()();
  TextColumn get entityId => text()();
  TextColumn get fieldKey => text()();
  TextColumn get writerId => text()();
  IntColumn get seq => integer()();

  /// 完整事件的规范 JSON（含 ctx / 值 / hlc），读回时整条解析，不靠列拼装。
  TextColumn get json => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 复习日志（只追加）。[json] 是完整事件内容（含不认识的字段，原样保留）；其余列只为查询。
@DataClassName('SrsReviewLogRow')
class SrsReviewLogs extends Table {
  TextColumn get id => text()();
  TextColumn get profileUid => text()();
  TextColumn get cardId => text()();
  TextColumn get kind => text()();
  IntColumn get rating => integer().nullable()();
  IntColumn get occurredAt => integer()();
  TextColumn get reviewType => text()();
  TextColumn get origin => text()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  TextColumn get json => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 本机不认识的同步事件（更新版本写来的）：原样保留、原样转写。
@DataClassName('SrsUnknownEventRow')
class SrsUnknownEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileUid => text()();
  TextColumn get json => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 事件的本机发布元信息（与事件内容分离，不同步）。
@DataClassName('SrsEventLocalRow')
class SrsEventLocal extends Table {
  TextColumn get eventId => text()();
  TextColumn get profileUid => text()();

  /// 本机产生的事件在发件箱里的顺序；null = 对端来的或已发布。
  IntColumn get outboxSeq => integer().nullable()();

  /// S(e)：所有已见到的、包含该事件的批次的 S 的最小值。
  IntColumn get serverTime => integer().nullable()();
  IntColumn get receivedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {eventId};
}

/// 每个 profile 的本机同步 / 写入者状态（SrsSyncLocalState、写入者 seq、已应用上下文、HLC、时间锚点），JSON。
@DataClassName('SrsLocalStateRow')
class SrsLocalState extends Table {
  TextColumn get profileUid => text()();
  TextColumn get json => text()();

  @override
  Set<Column> get primaryKey => {profileUid};
}

/// v121：本机已冻结批次的留存（不同步、不进备份）。一台设备可以同时用几个同步目录
/// （云盘、互联 host、本机作 host 时自己的目录），同一个批次要逐字节相同地传到每一个；
/// 留存到最近同步过的所有目录都确认收到为止（fushi_srs 的 `SrsSyncEngine`）。
@DataClassName('SrsSentBatchRow')
class SrsSentBatches extends Table {
  TextColumn get profileUid => text()();
  TextColumn get writerId => text()();

  /// 批次号（写入者内从 1 起连续）。
  IntColumn get batchNo => integer()();

  /// 冻结后的批次文件字节（自校验格式，见 fushi_srs `SrsBatch`）。
  BlobColumn get bytes => blob()();

  @override
  Set<Column> get primaryKey => {profileUid, writerId, batchNo};
}

/// 笔记缓存（本机可重建，不同步）。
@DataClassName('SrsNoteCacheRow')
class SrsNotesCache extends Table {
  TextColumn get id => text()();
  TextColumn get profileUid => text()();
  TextColumn get noteTypeId => text()();
  TextColumn get guid => text()();
  IntColumn get createdAt => integer()();
  TextColumn get deckId => text().nullable()();
  IntColumn get deletedAt => integer().nullable()();

  /// 词状态索引：词形 / 读音归一化（第六轮审查第 20 条）。
  TextColumn get termKey => text().withDefault(const Constant(''))();
  TextColumn get readingKey => text().withDefault(const Constant(''))();

  /// 排序 / 列表显示用的第一个字段（去 HTML）。
  TextColumn get sortField => text().withDefault(const Constant(''))();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  BoolColumn get pendingDecision =>
      boolean().withDefault(const Constant(false))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 卡片缓存（本机可重建，不同步）：可编辑字段的生效值 + 最后一条有效日志的排程结果。
@DataClassName('SrsCardCacheRow')
class SrsCardsCache extends Table {
  TextColumn get id => text()();
  TextColumn get profileUid => text()();
  TextColumn get noteId => text()();
  TextColumn get templateId => text()();
  IntColumn get clozeOrd => integer().withDefault(const Constant(0))();
  TextColumn get deckId => text()();
  BoolColumn get suspended => boolean().withDefault(const Constant(false))();
  IntColumn get buriedUntilDay => integer().nullable()();
  IntColumn get flag => integer().withDefault(const Constant(0))();

  /// 生成门（铁律 D，第六轮审查第 13 条）：笔记已删 / 模板已删 / 条件模板为空 / cN 已删时为真，
  /// 查询层据此不显示、不进队列，不写任何同步行。
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();
  TextColumn get queue => text().withDefault(const Constant('new'))();
  IntColumn get dueDay => integer().nullable()();
  IntColumn get dueAt => integer().nullable()();
  IntColumn get scheduledDays => integer().withDefault(const Constant(0))();
  IntColumn get reps => integer().withDefault(const Constant(0))();
  IntColumn get lapses => integer().withDefault(const Constant(0))();
  RealColumn get stability => real().nullable()();
  RealColumn get difficulty => real().nullable()();
  IntColumn get lastReviewedAt => integer().nullable()();
  TextColumn get lastLogId => text().nullable()();
  TextColumn get scheduler => text().withDefault(const Constant('fushi'))();

  /// 新卡出卡顺序的兜底键（笔记 createdAt, cardId）：没有 [newPosition] 的新卡按它排。
  IntColumn get noteCreatedAt => integer().withDefault(const Constant(0))();

  /// v123：新卡在出卡队列里的位置（卡片修改记录 `newPos` 的生效值，「按词频重排新卡」
  /// 写它）。NULL = 从没排过：有位置的新卡先出（位置升序），没位置的排在后面并保持
  /// 原有的（笔记 createdAt, cardId）顺序——老数据出卡顺序不变。
  IntColumn get newPosition => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
