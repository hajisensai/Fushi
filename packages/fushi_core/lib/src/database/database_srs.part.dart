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

/// v117 SRS：profile 全局身份与 srs_* 表的索引。SRS 的读写逻辑在
/// packages/fushi_engine/lib/srs/（直接用生成的表），本 mixin 只放迁移与身份辅助。
mixin _FushiDbSrs on _$FushiDatabase {
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
      await customStatement('UPDATE profiles SET uid = ? WHERE id = ?', <Object>[
        newProfileUid(),
        r.read<int>('id'),
      ]);
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

  Future<void> _ensureSrsIndexes() async {
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

  /// v129 有效复习投影的索引（与 [_ensureSrsIndexes] 分开：v117 步调它时这张表还不存在）。
  /// 按 profile + 时刻读统计；按产出卡整卡替换。
  Future<void> _ensureSrsStatIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_srs_stat_reviews_profile_time '
      'ON srs_stat_reviews (profile_uid, occurred_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_srs_stat_reviews_card '
      'ON srs_stat_reviews (card_id)',
    );
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
