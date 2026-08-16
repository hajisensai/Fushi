import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v63（删除废弃的 galgame 全局超分偏好）与 v65（Mihon 漫画扩展生态五张新表）
/// 在两条并行的分支上都曾写作 v63。合并时 v65 顺延到 v63 之后，本测试守住
/// 「两条迁移都必须跑到、且互不依赖对方的顺序」这个不变式——撞号一旦复发，
/// 其中一条会对已升级用户永远不执行，而且不报错。
const String _obsoleteKey = 'galgame_magpie_upscaling_mode';

const List<String> _mangaTables = <String>[
  'manga_extension_stores',
  'manga_extensions',
  'manga_online_sources',
  'manga_source_preferences',
  'manga_trusted_signers',
];

/// v62 形状：有 v63 要清理的废弃偏好行，没有 v65 要建的五张表。
void _seedV62(
  sqlite3.Database db, {
  int userVersion = 62,
  bool includeObsoleteRows = true,
  bool preCreateMangaTables = false,
}) {
  db.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)
''');
  db.execute('''
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

  db.execute(
    "INSERT INTO preferences (key, value) VALUES ('theme', 's:dark')",
  );
  if (includeObsoleteRows) {
    db.execute(
      "INSERT INTO preferences (key, value) VALUES ('$_obsoleteKey', 's:auto')",
    );
    db.execute(
      '''INSERT INTO profile_settings (profile_id, category, key, value) '''
      '''VALUES (1, 'pref', '$_obsoleteKey', 's:auto')''',
    );
  }
  db.execute(
    "INSERT INTO galgames (id, upscaling_mode) VALUES ('auto-game', 'auto')",
  );

  if (preCreateMangaTables) {
    // 半升级过的库：v65 的表已经在（例如用户跑过撞号版本），迁移必须原地
    // no-op 而不是 CREATE TABLE 报 already exists 把整条 onUpgrade 打断。
    for (final String table in _mangaTables) {
      db.execute('CREATE TABLE $table (probe TEXT NOT NULL PRIMARY KEY)');
    }
  }

  db.execute('PRAGMA user_version = $userVersion');
}

Future<Set<String>> _tableNames(FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

Future<int> _userVersion(FushiDatabase db) async {
  final QueryRow row = await db.customSelect('PRAGMA user_version').getSingle();
  return row.read<int>('user_version');
}

Future<int> _countRows(FushiDatabase db, String sql) async {
  final QueryRow row =
      await db.customSelect('SELECT COUNT(*) AS n FROM ($sql)').getSingle();
  return row.read<int>('n');
}

void main() {
  test(
      'v62 -> current runs BOTH v63 (obsolete pref delete) and v65 '
      '(Mihon tables); neither swallows the other', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(setup: _seedV62),
    );
    addTearDown(db.close);

    expect(db.schemaVersion, 88);
    expect(await _userVersion(db), db.schemaVersion);

    // v63 真跑了：两处废弃偏好都没了。
    expect(
      await _countRows(
        db,
        "SELECT 1 FROM preferences WHERE key = '$_obsoleteKey'",
      ),
      0,
      reason: 'v63 未执行——撞号会让它对已升级用户永远静默跳过',
    );
    expect(
      await _countRows(
        db,
        "SELECT 1 FROM profile_settings WHERE category = 'pref' "
        "AND key = '$_obsoleteKey'",
      ),
      0,
      reason: 'v63 未执行（profile_settings 侧）',
    );
    // v63 只删该删的。
    expect(
      await _countRows(db, "SELECT 1 FROM preferences WHERE key = 'theme'"),
      1,
    );

    // v65 真跑了：五张表都在。
    final Set<String> tables = await _tableNames(db);
    for (final String table in _mangaTables) {
      expect(tables, contains(table), reason: 'v65 未执行：缺 $table');
    }

    // 建出来的是真 schema，不是空壳。
    await db.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: 'https://repo.example/index.json',
        name: 'Fixture repository',
        format: 'currentJson',
        signingKey: const Value('aabb'),
      ),
    );
    expect(
      await _countRows(db, 'SELECT 1 FROM manga_extension_stores'),
      1,
    );
  });

  test('v63 -> current still runs v65, order-independent from v63/v64',
      () async {
    // 已经跑过 v63 的库（废弃行本就不在），还差 v64（collection_scrape_meta）
    // 和 v65（Mihon 五表）。这里只断言 v65 那一段照跑，不依赖它是最后一步。
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (sqlite3.Database raw) => _seedV62(
          raw,
          userVersion: 63,
          includeObsoleteRows: false,
        ),
      ),
    );
    addTearDown(db.close);

    expect(await _userVersion(db), db.schemaVersion);
    final Set<String> tables = await _tableNames(db);
    for (final String table in _mangaTables) {
      expect(tables, contains(table), reason: 'from=63 时 v65 必须仍然建表：缺 $table');
    }
  });

  test('v65 is idempotent when the Mihon tables already exist', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (sqlite3.Database raw) =>
            _seedV62(raw, preCreateMangaTables: true),
      ),
    );
    addTearDown(db.close);

    // 表已存在不能让 onUpgrade 抛异常——抛了 v63 的删除也会一起回滚。
    expect(await _userVersion(db), db.schemaVersion);
    expect(
      await _countRows(
        db,
        "SELECT 1 FROM preferences WHERE key = '$_obsoleteKey'",
      ),
      0,
      reason: 'v65 CREATE TABLE 报错会把同一次 onUpgrade 里的 v63 一并打断',
    );
    final Set<String> tables = await _tableNames(db);
    for (final String table in _mangaTables) {
      expect(tables, contains(table));
    }
  });

  test('reopening an already-migrated DB is a no-op', () async {
    final FushiDatabase first = FushiDatabase.forTesting(
      NativeDatabase.memory(setup: _seedV62),
    );
    expect(await _userVersion(first), first.schemaVersion);
    await first.close();

    // 同一份内存库不能跨实例复用，这里改用「第二次打开已是 v65 的形状」：
    // 直接 seed user_version = 64 且五张表齐全，断言不再触发任何迁移副作用。
    final FushiDatabase second = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (sqlite3.Database raw) => _seedV62(
          raw,
          userVersion: 67,
          includeObsoleteRows: false,
          preCreateMangaTables: true,
        ),
      ),
    );
    addTearDown(second.close);
    expect(await _userVersion(second), second.schemaVersion);
    expect(
      await _countRows(second, "SELECT 1 FROM preferences WHERE key = 'theme'"),
      1,
    );
  });
}
