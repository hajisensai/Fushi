import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v69 -> v70 阅读器源键改写迁移（Fushi 终局清算 W2-1）的正确性证明：
/// `reader_ttu` -> `reader_fushi` + pref shortKey 死前缀 `ttu_` 剥除。
///
/// Seed 按 migration_book_key_test 的裸库范式手写 v69 形态：只建迁移步会触碰的
/// 三张表（preferences / profile_settings / media_items）+ FK 父表 profiles，
/// `PRAGMA user_version = 69` 后经 `forTesting` 打开触发 onUpgrade(69 -> 70)。
/// 断言覆盖：三个落库位逐一改写正确、无关行逐字节不动、新旧键并存时
/// UPDATE OR REPLACE 保留改写结果而不是让 onUpgrade 中断。
FushiDatabase _openMigratedFromV69() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        // 生产 _openDb 同款：FK 强制 ON。memory DB 默认 FK OFF，会让
        // profile_settings -> profiles 的外键断言形同虚设。
        raw.execute('PRAGMA foreign_keys = ON');

        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');
        raw.execute(
          "INSERT INTO preferences (key, value) VALUES "
          // ① 命名空间 + shortKey 双段改写。
          "('src:reader_ttu:ttu_font_size', 'd:22.0'), "
          // ② 命名空间改写、shortKey 本就无 ttu_ 前缀 -> 只换命名空间。
          "('src:reader_ttu:font_catalog', '{\"version\":1}'), "
          // ③ BUG-1317 规范 override 键：只换命名空间段，mediaId 段不动。
          "('src:reader_ttu:override_title://hoshi://book/我的书', 's:新名'), "
          // ④ BUG-1317 legacy override 键：命名空间段 + 内嵌双源键段都改写。
          "('src:reader_ttu:override_title://reader_ttu/reader_ttu/hoshi://book/我的书', 's:旧名'), "
          // ⑤ 新旧并存冲突：改写 ⑤a 会撞上已存在的同名新键 ⑤b ->
          //    UPDATE OR REPLACE 保留改写结果（旧行 value 胜出）。
          "('src:reader_ttu:ttu_view_mode', 's:paginated'), "
          "('src:reader_fushi:view_mode', 's:continuous'), "
          // ⑥ current_source/* 把源 uniqueKey 当值存：标签/裸两种形态都改写。
          "('current_source/reader', 's:reader_ttu'), "
          "('current_source/reader_legacy_bare', 'reader_ttu'), "
          // 无关行（不许动）：别的源命名空间 / 裸键 / 形近但非前缀 /
          // 值恰为旧串但键不是 current_source/*。
          "('src:reader_pdf:override_title://reader_pdf/reader_pdf/hoshi://book/x', 's:pdf名'), "
          "('src:reader_manga:some_key', 's:v'), "
          "('audiobook_pos_MyBook', '1000'), "
          "('src:reader_ttu_extra:key', 's:not-a-prefix-match'), "
          "('unrelated_value_holder', 's:reader_ttu')",
        );

        raw.execute('''
CREATE TABLE profiles (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO profiles (id, name, created_at, updated_at) "
          "VALUES (1, 'Default', 1, 1)",
        );
        raw.execute('''
CREATE TABLE profile_settings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE,
  category TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL
)''');
        raw.execute(
          "INSERT INTO profile_settings (profile_id, category, key, value) "
          "VALUES "
          // category='pref' 行存整串 pref key -> 与 preferences 同款双段改写。
          "(1, 'pref', 'src:reader_ttu:ttu_theme', 's:light'), "
          // 旧 'reader' 类别快照行存裸 shortKey -> 只剥 ttu_ 前缀。
          "(1, 'reader', 'ttu_font_size', 'd:20.0'), "
          // 无关行：非 ttu_ 前缀的裸 shortKey / 别的 pref key。
          "(1, 'reader', 'lyrics_font_size', 'd:30.0'), "
          "(1, 'pref', 'audiobook_pos_X', 'i:5')",
        );

        raw.execute('''
CREATE TABLE media_items (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  media_identifier TEXT NOT NULL,
  title TEXT NOT NULL,
  media_type_identifier TEXT NOT NULL,
  media_source_identifier TEXT NOT NULL,
  unique_key TEXT NOT NULL UNIQUE,
  base64_image TEXT,
  image_url TEXT,
  audio_url TEXT,
  author TEXT,
  author_identifier TEXT,
  extra_url TEXT,
  extra TEXT,
  source_metadata TEXT,
  position INTEGER NOT NULL,
  duration INTEGER NOT NULL,
  can_delete INTEGER NOT NULL,
  can_edit INTEGER NOT NULL,
  imported_at INTEGER NOT NULL DEFAULT 0
)''');
        raw.execute(
          "INSERT INTO media_items "
          "(media_identifier, title, media_type_identifier, media_source_identifier, unique_key, position, duration, can_delete, can_edit) "
          "VALUES "
          "('hoshi://book/A', 'A', 'reader', 'reader_ttu', 'reader_ttu/hoshi://book/A', 0, 0, 1, 1),"
          "('hoshi://book/B', 'B', 'reader', 'reader_pdf', 'reader_pdf/hoshi://book/B', 0, 0, 1, 1)",
        );

        raw.execute('PRAGMA user_version = 69');
      },
    ),
  );
}

Future<Map<String, String>> _tableAsMap(
  FushiDatabase db,
  String sql,
  String keyCol,
  String valueCol,
) async {
  final rows = await db.customSelect(sql).get();
  return <String, String>{
    for (final QueryRow r in rows)
      r.read<String>(keyCol): r.read<String>(valueCol),
  };
}

void main() {
  test('v69->v70 rewrites reader_ttu family values losslessly', () async {
    final FushiDatabase db = _openMigratedFromV69();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');

    // ── preferences ───────────────────────────────────────────────────
    final Map<String, String> prefs = await _tableAsMap(
        db, 'SELECT key, value FROM preferences', 'key', 'value');
    expect(prefs['src:reader_fushi:font_size'], 'd:22.0',
        reason: '① 命名空间 + shortKey 双段改写');
    expect(prefs['src:reader_fushi:font_catalog'], '{"version":1}',
        reason: '② 只换命名空间');
    expect(prefs['src:reader_fushi:override_title://hoshi://book/我的书'], 's:新名',
        reason: '③ 规范 override 键只换命名空间段（hoshi:// 段归后续迁移步）');
    expect(
        prefs[
            'src:reader_fushi:override_title://reader_fushi/reader_fushi/hoshi://book/我的书'],
        's:旧名',
        reason: '④ legacy override 键内嵌双源键段一并改写');
    expect(prefs['src:reader_fushi:view_mode'], 's:paginated',
        reason: '⑤ 新旧并存时 OR REPLACE 保留改写结果（旧行值胜出）');
    expect(prefs.keys.where((k) => k.contains('view_mode')).length, 1,
        reason: '⑤ 冲突行只留一条');
    // 无关行逐字节不动。
    expect(
        prefs[
            'src:reader_pdf:override_title://reader_pdf/reader_pdf/hoshi://book/x'],
        's:pdf名');
    expect(prefs['src:reader_manga:some_key'], 's:v');
    expect(prefs['audiobook_pos_MyBook'], '1000');
    expect(prefs['src:reader_ttu_extra:key'], 's:not-a-prefix-match',
        reason: '形近键（src:reader_ttu_extra:）不是前缀命中，不许动');
    expect(prefs['current_source/reader'], 's:reader_fushi',
        reason: '⑥ current_source/* 标签形态值改写');
    expect(prefs['current_source/reader_legacy_bare'], 'reader_fushi',
        reason: '⑥ current_source/* 历史裸值改写');
    expect(prefs['unrelated_value_holder'], 's:reader_ttu',
        reason: '⑥ 值恰为旧串但键不是 current_source/* 的行不许动');
    // 旧形态零残留。
    expect(prefs.keys.where((k) => k.startsWith('src:reader_ttu:')), isEmpty);
    expect(prefs.keys.where((k) => k.startsWith('src:reader_fushi:ttu_')),
        isEmpty);

    // ── profile_settings ─────────────────────────────────────────────
    final rows = await db
        .customSelect(
            'SELECT category, key, value FROM profile_settings ORDER BY id')
        .get();
    final List<List<String>> triples = rows
        .map((r) => <String>[
              r.read<String>('category'),
              r.read<String>('key'),
              r.read<String>('value'),
            ])
        .toList();
    expect(
        triples,
        containsAll(<List<String>>[
          <String>['pref', 'src:reader_fushi:theme', 's:light'],
          <String>['reader', 'font_size', 'd:20.0'],
          <String>['reader', 'lyrics_font_size', 'd:30.0'],
          <String>['pref', 'audiobook_pos_X', 'i:5'],
        ]));
    expect(triples.length, 4, reason: '不多不少：无关行不动、不产生新行');

    // ── media_items ──────────────────────────────────────────────────
    final mi = await db
        .customSelect('SELECT media_identifier, media_source_identifier, '
            'unique_key FROM media_items ORDER BY id')
        .get();
    expect(mi[0].read<String>('media_source_identifier'), 'reader_fushi');
    expect(mi[0].read<String>('unique_key'), 'reader_fushi/hoshi://book/A');
    expect(mi[0].read<String>('media_identifier'), 'hoshi://book/A',
        reason: 'mediaIdentifier 的 hoshi:// 段归后续迁移步，本步不动');
    expect(mi[1].read<String>('media_source_identifier'), 'reader_pdf');
    expect(mi[1].read<String>('unique_key'), 'reader_pdf/hoshi://book/B');
  });
}
