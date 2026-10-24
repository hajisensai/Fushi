part of 'database.dart';

/// 「卡片前身链接」修改记录（`historyFrom/<前身卡>`，更改笔记类型时写）的筛选条件：v120 的部分索引
/// `idx_srs_field_edits_history_from` 的 WHERE，fushi_engine `SrsDbStore` 找后继卡的查询也用这一句。
///
/// 必须是字面量（不用绑定参数）、两处逐字相同：SQLite 只在查询的 WHERE 逐项包含部分索引的
/// WHERE 时才用它。查询里别的条件要写成 `+列`（不让它去用别的索引，否则规划器会挑
/// `(entity_kind, entity_id)` 那个索引、扫全部卡片修改记录）。前缀与 fushi_srs
/// `SrsFieldKeys.cardHistoryFromPrefix` 相同（fushi_core 不依赖 fushi_srs，这里另写一次；
/// fushi_engine 的测试钉住两者一致、且查询计划真走这个索引）。
const String kSrsHistoryFromCondition =
    "substr(field_key, 1, 12) = 'historyFrom/'";

/// v117 建的 8 张 srs_* 表（v121 再加 srs_sent_batches）。
const List<String> kLegacySrsV117Tables = <String>[
  'srs_entities',
  'srs_field_edits',
  'srs_review_logs',
  'srs_unknown_events',
  'srs_event_local',
  'srs_local_state',
  'srs_notes_cache',
  'srs_cards_cache',
];

/// 老库 srs_* 表的建表语句：与 2026-10-23 之前 Drift 声明生成的表逐列相同（列序也相同）。
/// 这些表已不在 Drift 声明里（归 Rust 的 srs.db），迁移阶梯上的老库仍按当年的形状建出来，
/// 好让 SRS 的一次性搬迁原样搬走。
const Map<String, String> kLegacySrsTableDdl = <String, String>{
  'srs_entities':
      'CREATE TABLE IF NOT EXISTS "srs_entities" ("id" TEXT NOT NULL, '
      '"profile_uid" TEXT NOT NULL, "kind" TEXT NOT NULL, '
      '"payload_json" TEXT NOT NULL, "created_at" INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY ("id"))',
  'srs_field_edits':
      'CREATE TABLE IF NOT EXISTS "srs_field_edits" ("id" TEXT NOT NULL, '
      '"profile_uid" TEXT NOT NULL, "entity_kind" TEXT NOT NULL, '
      '"entity_id" TEXT NOT NULL, "field_key" TEXT NOT NULL, '
      '"writer_id" TEXT NOT NULL, "seq" INTEGER NOT NULL, "json" TEXT NOT NULL, '
      'PRIMARY KEY ("id"))',
  'srs_review_logs':
      'CREATE TABLE IF NOT EXISTS "srs_review_logs" ("id" TEXT NOT NULL, '
      '"profile_uid" TEXT NOT NULL, "card_id" TEXT NOT NULL, '
      '"kind" TEXT NOT NULL, "rating" INTEGER NULL, '
      '"occurred_at" INTEGER NOT NULL, "review_type" TEXT NOT NULL, '
      '"origin" TEXT NOT NULL, "duration_ms" INTEGER NOT NULL DEFAULT 0, '
      '"json" TEXT NOT NULL, PRIMARY KEY ("id"))',
  'srs_unknown_events':
      'CREATE TABLE IF NOT EXISTS "srs_unknown_events" ("id" TEXT NOT NULL, '
      '"profile_uid" TEXT NOT NULL, "json" TEXT NOT NULL, PRIMARY KEY ("id"))',
  'srs_event_local':
      'CREATE TABLE IF NOT EXISTS "srs_event_local" ("event_id" TEXT NOT NULL, '
      '"profile_uid" TEXT NOT NULL, "outbox_seq" INTEGER NULL, '
      '"server_time" INTEGER NULL, "received_at" INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY ("event_id"))',
  'srs_local_state':
      'CREATE TABLE IF NOT EXISTS "srs_local_state" ("profile_uid" TEXT NOT NULL, '
      '"json" TEXT NOT NULL, PRIMARY KEY ("profile_uid"))',
  'srs_sent_batches':
      'CREATE TABLE IF NOT EXISTS "srs_sent_batches" ("profile_uid" TEXT NOT NULL, '
      '"writer_id" TEXT NOT NULL, "batch_no" INTEGER NOT NULL, '
      '"bytes" BLOB NOT NULL, PRIMARY KEY ("profile_uid", "writer_id", "batch_no"))',
  'srs_notes_cache':
      'CREATE TABLE IF NOT EXISTS "srs_notes_cache" ("id" TEXT NOT NULL, '
      '"profile_uid" TEXT NOT NULL, "note_type_id" TEXT NOT NULL, '
      '"guid" TEXT NOT NULL, "created_at" INTEGER NOT NULL, '
      '"deck_id" TEXT NULL, "deleted_at" INTEGER NULL, '
      '"term_key" TEXT NOT NULL DEFAULT \'\', "reading_key" TEXT NOT NULL DEFAULT \'\', '
      '"sort_field" TEXT NOT NULL DEFAULT \'\', "tags_json" TEXT NOT NULL DEFAULT \'[]\', '
      '"pending_decision" INTEGER NOT NULL DEFAULT 0 '
      'CHECK ("pending_decision" IN (0, 1)), '
      '"updated_at" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("id"))',
  'srs_cards_cache':
      'CREATE TABLE IF NOT EXISTS "srs_cards_cache" ("id" TEXT NOT NULL, '
      '"profile_uid" TEXT NOT NULL, "note_id" TEXT NOT NULL, '
      '"template_id" TEXT NOT NULL, "cloze_ord" INTEGER NOT NULL DEFAULT 0, '
      '"deck_id" TEXT NOT NULL, "suspended" INTEGER NOT NULL DEFAULT 0 '
      'CHECK ("suspended" IN (0, 1)), "buried_until_day" INTEGER NULL, '
      '"flag" INTEGER NOT NULL DEFAULT 0, "hidden" INTEGER NOT NULL DEFAULT 0 '
      'CHECK ("hidden" IN (0, 1)), "queue" TEXT NOT NULL DEFAULT \'new\', '
      '"due_day" INTEGER NULL, "due_at" INTEGER NULL, '
      '"scheduled_days" INTEGER NOT NULL DEFAULT 0, "reps" INTEGER NOT NULL DEFAULT 0, '
      '"lapses" INTEGER NOT NULL DEFAULT 0, "stability" REAL NULL, '
      '"difficulty" REAL NULL, "last_reviewed_at" INTEGER NULL, '
      '"last_log_id" TEXT NULL, "scheduler" TEXT NOT NULL DEFAULT \'fushi\', '
      '"note_created_at" INTEGER NOT NULL DEFAULT 0, "new_position" INTEGER NULL, '
      'PRIMARY KEY ("id"))',
};

/// v117 SRS：profile 全局身份与（老库）srs_* 表的索引。SRS 的读写逻辑在
/// packages/fushi_engine/lib/srs/（直接用生成的表），本 mixin 只放迁移与身份辅助。
mixin _FushiDbSrs on _$FushiDatabase {
  Future<bool> _srsTableExists(String name) async => (await customSelect(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    variables: <Variable<Object>>[Variable<String>(name)],
  ).get()).isNotEmpty;

  Future<void> _createLegacySrsTables(List<String> names) async {
    for (final String n in names) {
      if (!await _srsTableExists(n)) {
        await customStatement(kLegacySrsTableDdl[n]!);
      }
    }
  }

  static final Random _uidRandom = Random.secure();

  /// RFC 9562 UUIDv7（与 fushi_srs 的 uuidV7 同格式；fushi_core 不依赖 fushi_srs）。
  static String newProfileUid() {
    final int ms = DateTime.now().millisecondsSinceEpoch;
    final List<int> b = List<int>.filled(16, 0);
    for (int i = 0; i < 6; i++) {
      b[i] = (ms >> (8 * (5 - i))) & 0xff;
    }
    for (int i = 6; i < 16; i++) {
      b[i] = _uidRandom.nextInt(256);
    }
    b[6] = (b[6] & 0x0f) | 0x70;
    b[8] = (b[8] & 0x3f) | 0x80;
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) sb.write('-');
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// 为还没有 uid 的 profile 行生成（迁移与惰性补齐共用）。
  Future<void> _backfillProfileUids() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT id FROM profiles WHERE uid IS NULL OR uid = \'\'',
    ).get();
    for (final QueryRow r in rows) {
      await customStatement(
        'UPDATE profiles SET uid = ? WHERE id = ?',
        <Object>[newProfileUid(), r.read<int>('id')],
      );
    }
  }

  /// profiles.uid 的唯一索引。与 [_ensureSrsIndexes] 分开：迁移阶梯上 profiles 表
  /// 可能不存在（极老 / 合成库），调用方先确认表在再建。
  Future<void> _ensureProfileUidIndex() async {
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_uid ON profiles (uid) '
      "WHERE uid IS NOT NULL AND uid != ''",
    );
  }

  /// 老库的 srs_* 表索引（只在表还在时补；搬迁到 srs.db 后旧表已删，什么都不做）。
  Future<void> _ensureSrsIndexes() async {
    if (!await _srsTableExists('srs_entities')) return;
    const List<String> stmts = <String>[
      'CREATE INDEX IF NOT EXISTS idx_srs_entities_profile_kind '
          'ON srs_entities (profile_uid, kind)',
      'CREATE INDEX IF NOT EXISTS idx_srs_field_edits_entity '
          'ON srs_field_edits (entity_kind, entity_id)',
      'CREATE INDEX IF NOT EXISTS idx_srs_review_logs_card '
          'ON srs_review_logs (card_id)',
      'CREATE INDEX IF NOT EXISTS idx_srs_review_logs_profile_time '
          'ON srs_review_logs (profile_uid, occurred_at)',
      'CREATE INDEX IF NOT EXISTS idx_srs_event_local_outbox '
          'ON srs_event_local (profile_uid, outbox_seq)',
      'CREATE INDEX IF NOT EXISTS idx_srs_notes_cache_term '
          'ON srs_notes_cache (profile_uid, term_key)',
      'CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_note '
          'ON srs_cards_cache (note_id)',
      'CREATE INDEX IF NOT EXISTS idx_srs_cards_cache_queue '
          'ON srs_cards_cache (profile_uid, deck_id, queue, due_day)',
      // v120：前身链接的部分覆盖索引（只含 historyFrom/ 那几行）。缓存刷新每次都要找「哪些卡继承了
      // 这张卡的历史」，以前按无索引的 field_key 全表扫描修改记录表（BUG-3543）。
      'CREATE INDEX IF NOT EXISTS idx_srs_field_edits_history_from '
          'ON srs_field_edits (field_key, entity_kind, entity_id) '
          'WHERE $kSrsHistoryFromCondition',
      // v125：写入路径周边的读放大。
      // ① 同步冲突角标（SrsDbStore.syncConflicts）按 profile 对 (实体, 字段键) GROUP BY：以前只有
      //    (entity_kind, entity_id) 索引，每次都全表扫描修改记录表（连同笔记正文 json）。这条覆盖
      //    索引让分组只扫索引。
      'CREATE INDEX IF NOT EXISTS idx_srs_field_edits_profile_register '
          'ON srs_field_edits (profile_uid, entity_kind, entity_id, field_key)',
      // ② 笔记类型的成员查找（改笔记类型后刷新缓存、按类型列笔记 / 计数）。
      'CREATE INDEX IF NOT EXISTS idx_srs_notes_cache_type '
          'ON srs_notes_cache (profile_uid, note_type_id)',
      // ③ 待裁决笔记（冲突角标）：只含 pending_decision = 1 的那几行。
      'CREATE INDEX IF NOT EXISTS idx_srs_notes_cache_pending '
          'ON srs_notes_cache (profile_uid) WHERE pending_decision = 1',
    ];
    for (final String s in stmts) {
      await customStatement(s);
    }
  }

  /// profile 的全局身份；没有就当场生成并写回（新建的 profile 行不必改各处插入点）。
  Future<String> profileUidOf(int profileId) async {
    final QueryRow? row = await customSelect(
      'SELECT uid FROM profiles WHERE id = ?',
      variables: <Variable<Object>>[Variable<int>(profileId)],
    ).getSingleOrNull();
    if (row == null) {
      throw StateError('profile $profileId does not exist');
    }
    final String? uid = row.read<String?>('uid');
    if (uid != null && uid.isNotEmpty) return uid;
    final String fresh = newProfileUid();
    await customStatement('UPDATE profiles SET uid = ? WHERE id = ?', <Object>[
      fresh,
      profileId,
    ]);
    return fresh;
  }

  /// 关联到已有 profile 时采用对端的 uid（铁律 E）。调用方负责先检查「没有用户笔记且从未发布过批次」。
  Future<void> adoptProfileUid(int profileId, String uid) async {
    await customStatement('UPDATE profiles SET uid = ? WHERE id = ?', <Object>[
      uid,
      profileId,
    ]);
  }
}
