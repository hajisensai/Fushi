import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v70 -> v71 sasayaki 族存量值改写迁移（Fushi 终局清算 W2-2）的正确性证明：
/// `sasayaki://` scheme -> `fushi-cue://`、custom_themes 条目 JSON 键
/// `sasayakiColor` -> `sentenceAudioHighlightColor`、偏好键
/// `custom_theme_sasayaki_color` -> `custom_theme_sentence_audio_color`。
///
/// Seed 按 migration_book_key_test 的裸库范式手写 v70 形态，只建迁移步触碰的表。
FushiDatabase _openMigratedFromV70() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        // 生产 _openDb 同款：FK 强制 ON（memory DB 默认 OFF，会让
        // profile_settings -> profiles 外键形同虚设）。
        raw.execute('PRAGMA foreign_keys = ON');

        // 列名必须与**真实 v70 的 audio_cues** 一致：这张表的书键叫 `book_key`
        // （[AudioCues.bookKey]，至今未改名——改走 uid 的是 reader_positions /
        // revealed_images 那一族，v82）。seed 写成 `book_uid` 会让迁移阶梯里的
        // `_ensureIndexes()` 建 `idx_audio_cues_book_key ON audio_cues (book_key)`
        // 时炸 "no such column"，红的是 seed 不是迁移。
        raw.execute('''
CREATE TABLE audio_cues (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL,
  chapter_href TEXT NOT NULL,
  sentence_index INTEGER NOT NULL,
  text_fragment_id TEXT NOT NULL,
  cue_text TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  audio_file_index INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO audio_cues "
          "(book_key, chapter_href, sentence_index, text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) "
          "VALUES "
          // ① 命中 cue：scheme 前缀改写，query 段不动。
          "('BookA', 'c1.xhtml', 0, 'sasayaki://s=1&ns=100&ne=200', 'hi', 0, 1000, 0),"
          // 未命中 cue：srt:// 与 DOM id 原值不许动。
          "('BookA', 'c1.xhtml', 1, 'srt://5', 'yo', 1000, 2000, 0),"
          "('BookA', 'c1.xhtml', 2, 'frag-1', 'mm', 2000, 3000, 0)",
        );

        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');
        raw.execute(
          "INSERT INTO preferences (key, value) VALUES "
          // ② custom_themes 值：PrefCodec 编码的 List<String>，条目 JSON 的引号
          //    被转义（\"sasayakiColor\"），裸词 REPLACE 必须命中。
          "('custom_themes', '[\"{\\\"id\\\":\\\"t1\\\",\\\"seed\\\":1,\\\"sasayakiColor\\\":4278}\"]'), "
          // ③ 偏好键整键改名。
          "('custom_theme_sasayaki_color', 'i:123'), "
          // 无关行：键不是 custom_themes 的值即使含该词也不许动。
          "('unrelated_theme_holder', 'keep sasayakiColor as-is')",
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
          "(1, 'pref', 'custom_themes', '[\"{\\\"id\\\":\\\"t2\\\",\\\"sasayakiColor\\\":99}\"]'), "
          "(1, 'pref', 'custom_theme_sasayaki_color', 'i:5'), "
          "(1, 'pref', 'audio_highlight_color', 'i:7')",
        );

        raw.execute('PRAGMA user_version = 70');
      },
    ),
  );
}

void main() {
  test('v70->v71 rewrites sasayaki family values losslessly', () async {
    final FushiDatabase db = _openMigratedFromV70();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');

    // ── audio_cues.text_fragment_id ──────────────────────────────────
    final cues = await db
        .customSelect(
            'SELECT text_fragment_id FROM audio_cues ORDER BY sentence_index')
        .get();
    expect(cues.map((r) => r.read<String>('text_fragment_id')).toList(),
        <String>['fushi-cue://s=1&ns=100&ne=200', 'srt://5', 'frag-1']);

    // ── preferences ──────────────────────────────────────────────────
    final prefs = await db
        .customSelect('SELECT key, value FROM preferences')
        .get()
        .then((rows) => <String, String>{
              for (final QueryRow r in rows)
                r.read<String>('key'): r.read<String>('value'),
            });
    expect(prefs['custom_themes'],
        '["{\\"id\\":\\"t1\\",\\"seed\\":1,\\"sentenceAudioHighlightColor\\":4278}"]',
        reason: '② 条目 JSON 键改写，其余字节不动');
    expect(prefs['custom_theme_sentence_audio_color'], 'i:123',
        reason: '③ 偏好键整键改名，值不动');
    expect(prefs.containsKey('custom_theme_sasayaki_color'), isFalse);
    expect(prefs['unrelated_theme_holder'], 'keep sasayakiColor as-is',
        reason: '键不是 custom_themes 的值不许动');

    // ── profile_settings ─────────────────────────────────────────────
    final rows = await db
        .customSelect('SELECT key, value FROM profile_settings ORDER BY id')
        .get();
    final List<List<String>> pairs = rows
        .map((r) => <String>[r.read<String>('key'), r.read<String>('value')])
        .toList();
    expect(
        pairs,
        containsAll(<List<String>>[
          <String>[
            'custom_themes',
            '["{\\"id\\":\\"t2\\",\\"sentenceAudioHighlightColor\\":99}"]'
          ],
          <String>['custom_theme_sentence_audio_color', 'i:5'],
          <String>['audio_highlight_color', 'i:7'],
        ]));
    expect(pairs.length, 3);
  });
}
