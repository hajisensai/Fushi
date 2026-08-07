import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v72 -> v73 mediaIdentifier scheme 前缀改写迁移（Fushi 终局清算 W2-3）的
/// 正确性证明：`hoshi://book/` / `hoshi://srtbook/` -> `fushi://book/` /
/// `fushi://srtbook/`。重点回归：unique_key 是 `<源键>/<mediaId>` 复合形态，
/// 迁移只换 URI 段、**保留源键段**。
FushiDatabase _openMigratedFromV72() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');

        raw.execute('''
CREATE TABLE media_items (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  media_identifier TEXT NOT NULL,
  title TEXT NOT NULL,
  media_type_identifier TEXT NOT NULL,
  media_source_identifier TEXT NOT NULL,
  unique_key TEXT NOT NULL UNIQUE,
  position INTEGER NOT NULL,
  duration INTEGER NOT NULL,
  can_delete INTEGER NOT NULL,
  can_edit INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO media_items "
          "(media_identifier, title, media_type_identifier, media_source_identifier, unique_key, position, duration, can_delete, can_edit) "
          "VALUES "
          // ① book 前缀：identifier + 复合 unique_key 同改，源键段保留。
          "('hoshi://book/我的书', '我的书', 'reader', 'reader_fushi', 'reader_fushi/hoshi://book/我的书', 0, 0, 1, 1), "
          // ② srtbook 前缀。
          "('hoshi://srtbook/uid-1', 'S', 'reader', 'reader_fushi', 'reader_fushi/hoshi://srtbook/uid-1', 0, 0, 1, 1), "
          // ③ pdf 源的 book 条目：源键段 reader_pdf 不许被改。
          "('hoshi://book/P', 'P', 'reader', 'reader_pdf', 'reader_pdf/hoshi://book/P', 0, 0, 1, 1), "
          // ⑥ 裸形态 unique_key（v16 阶梯给 v15 旧库写出的、无源键段）：
          //    由前缀锚定改写补齐。
          "('hoshi://book/裸', '裸', 'reader', 'reader_fushi', 'hoshi://book/裸', 0, 0, 1, 1), "
          // 无关行：视频条目（文件路径 identifier）。
          "('D:/v/e1.mkv', 'E1', 'video', 'player', 'player/D:/v/e1.mkv', 0, 0, 1, 1)",
        );

        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');
        raw.execute(
          "INSERT INTO preferences (key, value) VALUES "
          // ④ 规范 override 键（BUG-1317 后）。
          "('src:reader_fushi:override_title://hoshi://book/我的书', 's:新名'), "
          // ⑤ legacy override 键（BUG-1317 前，双源键段 + URI 段）。
          "('src:reader_fushi:override_title://reader_fushi/reader_fushi/hoshi://book/我的书', 's:旧名'), "
          // 无关行：非 override 键即使含 hoshi:// 也不动（不存在此类真实键，
          // 造一条验证 WHERE 的收敛面）。
          "('some_other_key_hoshi://book/x', 's:keep')",
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
          "(1, 'pref', 'src:reader_fushi:override_title://hoshi://srtbook/uid-1', 's:标'), "
          "(1, 'pref', 'audiobook_pos_X', 'i:5')",
        );

        raw.execute('PRAGMA user_version = 72');
      },
    ),
  );
}

void main() {
  test('v72->v73 rewrites hoshi:// identifier prefixes losslessly', () async {
    final FushiDatabase db = _openMigratedFromV72();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion);

    final mi = await db
        .customSelect('SELECT media_identifier, unique_key FROM media_items '
            'ORDER BY id')
        .get();
    expect(mi[0].read<String>('media_identifier'), 'fushi://book/我的书');
    expect(mi[0].read<String>('unique_key'), 'reader_fushi/fushi://book/我的书',
        reason: '① 复合 unique_key 只换 URI 段，源键段保留');
    expect(mi[1].read<String>('media_identifier'), 'fushi://srtbook/uid-1');
    expect(
        mi[1].read<String>('unique_key'), 'reader_fushi/fushi://srtbook/uid-1');
    expect(mi[2].read<String>('unique_key'), 'reader_pdf/fushi://book/P',
        reason: '③ 别的源键段不许被碰');
    expect(mi[3].read<String>('media_identifier'), 'fushi://book/裸');
    expect(mi[3].read<String>('unique_key'), 'fushi://book/裸',
        reason: '⑥ 裸形态 unique_key（v16 遗产）由前缀锚定改写补齐');
    expect(mi[4].read<String>('media_identifier'), 'D:/v/e1.mkv',
        reason: '无关行不动');
    expect(mi[4].read<String>('unique_key'), 'player/D:/v/e1.mkv');

    final prefs = await db
        .customSelect('SELECT key, value FROM preferences')
        .get()
        .then((rows) => <String, String>{
              for (final QueryRow r in rows)
                r.read<String>('key'): r.read<String>('value'),
            });
    expect(prefs['src:reader_fushi:override_title://fushi://book/我的书'], 's:新名',
        reason: '④ 规范 override 键 URI 段改写');
    expect(
        prefs[
            'src:reader_fushi:override_title://reader_fushi/reader_fushi/fushi://book/我的书'],
        's:旧名',
        reason: '⑤ legacy override 键 URI 段改写、双源键段不动');
    expect(prefs['some_other_key_hoshi://book/x'], 's:keep',
        reason: '非 override 键不动（WHERE 收敛面）');

    final ps = await db
        .customSelect('SELECT key FROM profile_settings ORDER BY id')
        .get();
    expect(ps[0].read<String>('key'),
        'src:reader_fushi:override_title://fushi://srtbook/uid-1');
    expect(ps[1].read<String>('key'), 'audiobook_pos_X');
  });
}
