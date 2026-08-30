import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v90（统一代理）：下载域独立的代理三态（`download_network_proxy_mode` +
/// `download_custom_proxy`）删除，全应用只剩系统设置里的一个代理项
/// `update_custom_proxy`（留空 = 自动）。
///
/// 迁移必须做到：
///  1. 用户在下载页显式选了 custom 且填了地址、全局项为空 → 地址搬进全局项
///     （升级后搜番剧/字幕继续走同一个代理，never break userspace）。
///  2. 全局项已有值 → 以全局为准，不被下载页的旧值覆盖。
///  3. mode 是 auto / direct（或根本没有 mode 行）→ 孤立的地址不归并。
///  4. 无论哪种情况，两行死键及其 `category = 'pref'` 的 Profile 副本都删掉，
///     同名非 pref 行与无关行原样保留。
///  5. 幂等：迁移后再次打开不再有可归并的东西，全局项不会被改回去。
///
/// 迁移之后 [FushiDatabase.getPref] 读回的是带 `s:` 前缀的原始编码值。

/// v88 形状的 `preferences`（v84 起带 `updated_at`）+ `profile_settings`。
void _seedV88(
  dynamic rawDb, {
  String? downloadMode,
  String? downloadProxy,
  String? globalProxy,
}) {
  rawDb.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL DEFAULT 0
)
''');
  rawDb.execute('''
CREATE TABLE profile_settings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  profile_id INTEGER NOT NULL,
  category TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  UNIQUE (profile_id, category, key)
)
''');
  rawDb.execute(
    "INSERT INTO preferences (key, value) VALUES ('theme', 's:dark')",
  );
  if (downloadMode != null) {
    rawDb.execute(
      'INSERT INTO preferences (key, value) VALUES '
      "('download_network_proxy_mode', 's:$downloadMode')",
    );
  }
  if (downloadProxy != null) {
    rawDb.execute(
      'INSERT INTO preferences (key, value) VALUES '
      "('download_custom_proxy', 's:$downloadProxy')",
    );
  }
  if (globalProxy != null) {
    rawDb.execute(
      'INSERT INTO preferences (key, value) VALUES '
      "('update_custom_proxy', 's:$globalProxy')",
    );
  }
  rawDb.execute(
    'INSERT INTO profile_settings (profile_id, category, key, value) VALUES '
    "(1, 'pref', 'download_network_proxy_mode', 's:custom'), "
    "(1, 'pref', 'download_custom_proxy', 's:10.0.0.1:1'), "
    "(2, 'pref', 'download_custom_proxy', 's:10.0.0.2:2'), "
    "(1, 'pref', 'font_size', 'i:20'), "
    "(1, 'legacy_non_pref', 'download_custom_proxy', 'must-survive')",
  );
  rawDb.execute('PRAGMA user_version = 88');
}

Future<Map<String, String>> _prefs(FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect('SELECT key, value FROM preferences ORDER BY key')
      .get();
  return <String, String>{
    for (final QueryRow row in rows)
      row.read<String>('key'): row.read<String>('value'),
  };
}

Future<List<(String, String, String)>> _profileRows(FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT category, key, value FROM profile_settings '
        'ORDER BY profile_id, category, key',
      )
      .get();
  return rows
      .map((QueryRow row) => (
            row.read<String>('category'),
            row.read<String>('key'),
            row.read<String>('value'),
          ))
      .toList();
}

void main() {
  FushiDatabase open({
    String? downloadMode,
    String? downloadProxy,
    String? globalProxy,
  }) {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (dynamic rawDb) => _seedV88(
          rawDb,
          downloadMode: downloadMode,
          downloadProxy: downloadProxy,
          globalProxy: globalProxy,
        ),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v88 -> v90：custom + 地址 + 全局为空 → 地址搬进全局项，死键删除', () async {
    final FushiDatabase db = open(
      downloadMode: 'custom',
      downloadProxy: ' 127.0.0.1:7890 ',
      globalProxy: '',
    );

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 93);
    expect(db.schemaVersion, 93);

    expect(await _prefs(db), <String, String>{
      'theme': 's:dark',
      'update_custom_proxy': 's:127.0.0.1:7890',
    });
  });

  test('custom + 地址，但全局没有行（从未打开过系统设置）→ 同样归并', () async {
    final FushiDatabase db = open(
      downloadMode: 'custom',
      downloadProxy: 'proxy.lan:3128',
    );
    expect(await _prefs(db), <String, String>{
      'theme': 's:dark',
      'update_custom_proxy': 's:proxy.lan:3128',
    });
  });

  test('全局项已有值 → 以全局为准，下载页旧值不覆盖', () async {
    final FushiDatabase db = open(
      downloadMode: 'custom',
      downloadProxy: '127.0.0.1:7890',
      globalProxy: '127.0.0.1:1080',
    );
    expect(await _prefs(db), <String, String>{
      'theme': 's:dark',
      'update_custom_proxy': 's:127.0.0.1:1080',
    });
  });

  for (final String? mode in <String?>['auto', 'direct', null]) {
    test('mode = ${mode ?? '<无行>'} 的孤立地址不归并，只删死键', () async {
      final FushiDatabase db = open(
        downloadMode: mode,
        downloadProxy: '127.0.0.1:7890',
      );
      expect(await _prefs(db), <String, String>{'theme': 's:dark'});
    });
  }

  test('custom 但地址为空 → 没东西可搬，全局项保持不存在', () async {
    final FushiDatabase db = open(downloadMode: 'custom', downloadProxy: '  ');
    expect(await _prefs(db), <String, String>{'theme': 's:dark'});
  });

  test('Profile 副本：只删 category = pref 的两个键，其余原样保留', () async {
    final FushiDatabase db = open(downloadMode: 'custom', downloadProxy: 'x:1');
    expect(await _profileRows(db), <(String, String, String)>[
      ('legacy_non_pref', 'download_custom_proxy', 'must-survive'),
      ('pref', 'font_size', 'i:20'),
    ]);
  });

  test('幂等：迁移后用户清空全局项，旧地址不会在下一次打开时复活', () async {
    final FushiDatabase db = open(
      downloadMode: 'custom',
      downloadProxy: '127.0.0.1:7890',
    );
    expect(await db.getPref('update_custom_proxy'), 's:127.0.0.1:7890');
    // 用户在系统设置里清空 = 回到自动。
    await db.setPref('update_custom_proxy', 's:');
    // 死键已经没了，v90 的归并条件永远不会再成立——这是把 mode/地址删掉而不是
    // 留着的原因：留着的话「清空 → 重启 → 旧值回来」会变成一个新 bug。
    final Map<String, String> after = await _prefs(db);
    expect(after.containsKey('download_network_proxy_mode'), isFalse);
    expect(after.containsKey('download_custom_proxy'), isFalse);
    expect(after['update_custom_proxy'], 's:');
  });
}
