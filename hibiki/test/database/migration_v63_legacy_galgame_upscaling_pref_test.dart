import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

const String _obsoleteKey = 'galgame_magpie_upscaling_mode';

void _seedV62(
  sqlite3.Database db, {
  bool includeObsoleteRows = true,
  bool malformedProfileSettings = false,
}) {
  db.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)
''');
  db.execute(malformedProfileSettings
      ? '''
CREATE TABLE profile_settings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  profile_id INTEGER NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL
)
'''
      : '''
CREATE TABLE profile_settings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  profile_id INTEGER NOT NULL,
  category TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  UNIQUE (profile_id, category, key)
)
''');
  db.execute('''
CREATE TABLE galgames (
  id TEXT NOT NULL PRIMARY KEY,
  upscaling_mode TEXT NOT NULL DEFAULT ''
)
''');
  db.execute('''
CREATE TABLE unrelated_table (
  id INTEGER NOT NULL PRIMARY KEY,
  payload TEXT NOT NULL
)
''');

  db.execute(
    '''INSERT INTO preferences (key, value) VALUES '''
    '''('theme', 's:dark'), ('download_custom_proxy', 's:127.0.0.1:7890')''',
  );
  if (includeObsoleteRows) {
    db.execute(
      "INSERT INTO preferences (key, value) VALUES ('$_obsoleteKey', 's:auto')",
    );
  }

  if (malformedProfileSettings) {
    db.execute(
      '''INSERT INTO profile_settings (profile_id, key, value) '''
      '''VALUES (1, '$_obsoleteKey', 's:auto')''',
    );
  } else {
    db.execute(
      '''INSERT INTO profile_settings (profile_id, category, key, value) VALUES '''
      '''(1, 'pref', '$_obsoleteKey', 's:auto'), '''
      '''(2, 'pref', '$_obsoleteKey', 's:installed_only'), '''
      '''(1, 'pref', 'font_size', 'i:20'), '''
      '''(1, 'legacy_non_pref', '$_obsoleteKey', 'must-survive'), '''
      '''(2, 'dictionary', '$_obsoleteKey', 'also-survives')''',
    );
  }
  db.execute(
    '''INSERT INTO galgames (id, upscaling_mode) VALUES '''
    '''('old-default-off', ''), '''
    '''('auto-game', 'auto'), '''
    '''('installed-game', 'installed_only')''',
  );
  db.execute(
    "INSERT INTO unrelated_table (id, payload) VALUES (1, 'untouched')",
  );
  db.execute('PRAGMA user_version = 62');
}

Map<String, String> _tableSql(sqlite3.Database db) => <String, String>{
      for (final row in db.select(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      ))
        row['name'] as String: row['sql'] as String,
    };

Future<Map<String, String>> _tableSqlFromDrift(FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  return <String, String>{
    for (final QueryRow row in rows)
      row.read<String>('name'): row.read<String>('sql'),
  };
}

void main() {
  test(
      'v63 deletes only the legacy live/pref Profile rows and leaves schema, '
      'per-game modes, and unrelated data untouched', () async {
    late Map<String, String> schemaBefore;
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (sqlite3.Database rawDb) {
          _seedV62(rawDb);
          schemaBefore = _tableSql(rawDb);
        },
      ),
    );
    addTearDown(db.close);

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 70);
    expect(db.schemaVersion, 70);

    final List<QueryRow> preferences = await db
        .customSelect(
          'SELECT key, value FROM preferences ORDER BY key',
        )
        .get();
    expect(
      preferences.map((QueryRow row) =>
          (row.read<String>('key'), row.read<String>('value'))),
      <(String, String)>[
        ('download_custom_proxy', 's:127.0.0.1:7890'),
        ('theme', 's:dark'),
      ],
    );

    final List<QueryRow> profileRows = await db
        .customSelect(
          'SELECT category, key, value FROM profile_settings '
          'ORDER BY profile_id, category, key',
        )
        .get();
    expect(
      profileRows.map((QueryRow row) => (
            row.read<String>('category'),
            row.read<String>('key'),
            row.read<String>('value'),
          )),
      <(String, String, String)>[
        ('legacy_non_pref', _obsoleteKey, 'must-survive'),
        ('pref', 'font_size', 'i:20'),
        ('dictionary', _obsoleteKey, 'also-survives'),
      ],
      reason: '只删 category=pref 的旧键，同名非 pref 与普通 pref 必须保留',
    );

    final List<QueryRow> gameRows = await db
        .customSelect(
          'SELECT id, upscaling_mode FROM galgames ORDER BY id',
        )
        .get();
    expect(
      gameRows.map((QueryRow row) => (
            row.read<String>('id'),
            row.read<String>('upscaling_mode'),
          )),
      <(String, String)>[
        ('auto-game', 'auto'),
        ('installed-game', 'installed_only'),
        ('old-default-off', ''),
      ],
      reason: '每游戏真值与老游戏默认关闭不受旧全局数据清理影响',
    );
    expect(
      (await db.customSelect('SELECT payload FROM unrelated_table').getSingle())
          .read<String>('payload'),
      'untouched',
    );
    // 本用例 seed 的是 v62 库，因此这一次打开会连跑 v63、v64（collection_scrape_meta，
    // BUG-1310）、v65（Mihon 五表）、v66（collection_relations）**和** v68
    // （media_images）。断言据此拆成两半，原意图一分不弱化：
    //  ① 既有表逐张全文比对 —— v63 只能删行，不得 ALTER/DROP/rebuild 或留影子表；
    //  ② 新增表必须**恰好**是 v64 一张 + v65 五张 + v66 一张 + v68 一张 —— v63
    //     自己仍然一张表都不许建。
    final Map<String, String> schemaAfter = await _tableSqlFromDrift(db);
    for (final MapEntry<String, String> entry in schemaBefore.entries) {
      expect(schemaAfter[entry.key], entry.value,
          reason: 'v63 只能删行，不得 ALTER/DROP/rebuild 既有表 ${entry.key}');
    }
    expect(
      schemaAfter.keys.toSet().difference(schemaBefore.keys.toSet()),
      <String>{
        'collection_scrape_meta',
        'manga_extension_stores',
        'manga_extensions',
        'manga_online_sources',
        'manga_source_preferences',
        'manga_trusted_signers',
        'collection_relations',
        'media_images',
      },
      reason: '除 v64 的 collection_scrape_meta、v65 的 Mihon 五表、v66 的 '
          'collection_relations 与 v68 的 media_images 外，升级不得新增任何表',
    );
  });

  test('v63 is idempotent when the obsolete rows are already absent', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (sqlite3.Database rawDb) {
          _seedV62(rawDb, includeObsoleteRows: false);
        },
      ),
    );
    addTearDown(db.close);

    expect(await db.getPref(_obsoleteKey), isNull);
    expect(await db.getPref('theme'), 's:dark');
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 70);
  });

  test(
      'backup source opened through atFile upgrades once and cannot resurrect '
      'the obsolete rows on reopen', () async {
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_v63_backup_upgrade');
    final String dbPath =
        '${tempDir.path}${Platform.pathSeparator}backup-source.db';
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      _seedV62(raw);
    } finally {
      raw.dispose();
    }

    FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    expect(await migrated.getPref(_obsoleteKey), isNull);
    expect(await migrated.getPref('theme'), 's:dark');
    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 70);
      expect(
        probe.select(
          'SELECT 1 FROM profile_settings '
          "WHERE category = 'pref' AND key = ?",
          <Object?>[_obsoleteKey],
        ),
        isEmpty,
      );
      expect(
        probe.select(
          'SELECT value FROM profile_settings '
          "WHERE category = 'legacy_non_pref' AND key = ?",
          <Object?>[_obsoleteKey],
        ).single['value'],
        'must-survive',
      );
    } finally {
      probe.dispose();
    }

    migrated = FushiDatabase.atFile(dbPath, isMainProcess: false);
    expect(await migrated.getPref(_obsoleteKey), isNull,
        reason: '第二次打开 user_version=65，不得产生复活或重复迁移副作用');
    await migrated.close();
  });

  test('a failure in the second delete rolls the first delete back as a batch',
      () async {
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_v63_rollback');
    final String dbPath = '${tempDir.path}${Platform.pathSeparator}rollback.db';
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      _seedV62(raw, malformedProfileSettings: true);
    } finally {
      raw.dispose();
    }

    final FushiDatabase broken =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await expectLater(
      broken.getPref('theme'),
      throwsA(anything),
      reason: '缺 category 列必须让第二条 DELETE 失败，不能吞异常假装升级成功',
    );
    try {
      await broken.close();
    } catch (_) {
      // The lazy connection failed during migration; close may repeat it.
    }

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 62,
          reason: '失败升级不得推进 user_version');
      expect(
        probe.select(
          'SELECT value FROM preferences WHERE key = ?',
          <Object?>[_obsoleteKey],
        ).single['value'],
        's:auto',
        reason: '第二条失败后第一条 DELETE 必须回滚，整批同成同败',
      );
    } finally {
      probe.dispose();
    }
  });
}
