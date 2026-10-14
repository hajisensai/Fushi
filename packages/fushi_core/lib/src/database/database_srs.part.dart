part of 'database.dart';

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
