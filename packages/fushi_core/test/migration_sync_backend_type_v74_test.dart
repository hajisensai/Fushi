import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v73 -> v74（Fushi 终局清算 W9-6）：`SyncBackendType.hibikiServer` 改名
/// `fushiServer` 后，偏好里存量的枚举值必须一并改写。
///
/// 值形态是 drift 偏好的字符串前缀编码 `s:<enum name>`。不改的后果不是报错而是
/// 静默失能：用户「同步方式＝互联」的选择在新版读不出来，resolveSyncBackend
/// 落回默认后端 = 互联被悄悄关掉。preferences 与 profile_settings 两处都要扫，
/// 因为偏好在每 Profile 快照里也可能有一份。
FushiDatabase _openMigratedFromV73() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');

        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');
        raw.execute(
          'INSERT INTO preferences (key, value) VALUES '
          // ① 待改写的存量值。
          "('sync_backend_type', 's:hibikiServer'), "
          // ② 同键不同值：不能被误改。
          "('other_backend_key', 's:hibikiServer')",
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
        // profile_settings 必须按**真实**表形建（每 Profile 一行快照 + profile_id
        // 外键）。原来 seed 写成裸 `(key, value)` 两列：迁移阶梯跑到
        // `_ensureIndexes()` 建 `idx_profile_settings_profile ON
        // profile_settings (profile_id)` 时炸 "no such column"，红的是 seed 不是迁移。
        raw.execute('''
CREATE TABLE profile_settings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE,
  category TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL
)''');
        raw.execute(
          'INSERT INTO profile_settings (profile_id, category, key, value) '
          // ③ 每 Profile 快照里的同一键，同样要改。
          "VALUES (1, 'pref', 'sync_backend_type', 's:hibikiServer')",
        );

        raw.execute('PRAGMA user_version = 73');
      },
    ),
  );
}

void main() {
  test('v73->v74 rewrites sync_backend_type hibikiServer -> fushiServer',
      () async {
    final FushiDatabase db = _openMigratedFromV73();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion);

    final prefs = await db
        .customSelect('SELECT key, value FROM preferences ORDER BY key')
        .get();
    final Map<String, String> prefMap = <String, String>{
      for (final QueryRow r in prefs)
        r.read<String>('key'): r.read<String>('value'),
    };
    expect(prefMap['sync_backend_type'], 's:fushiServer',
        reason: '① 存量枚举值改写；漏掉=用户的互联选择读不出来，静默落回默认后端');
    expect(prefMap['other_backend_key'], 's:hibikiServer',
        reason: '② 只按 key 精确匹配，同值的无关键不动');

    final ps = await db
        .customSelect('SELECT value FROM profile_settings WHERE '
            "key = 'sync_backend_type'")
        .getSingle();
    expect(ps.read<String>('value'), 's:fushiServer',
        reason: '③ profile_settings 的每 Profile 快照同样改写');
  });
}
