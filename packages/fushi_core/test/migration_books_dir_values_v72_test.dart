import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v71 -> v72 书库目录名库内路径改写迁移（Fushi 终局清算 W2-7）的正确性证明：
/// `hoshi_books` 目录段 -> `fushi_books`（extract_dir 正/反斜杠两形态 +
/// image_url file:// URI）+ 已删功能残留偏好 `google_drive_hoshi_compat` 清行。
FushiDatabase _openMigratedFromV71() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');

        raw.execute('''
CREATE TABLE epub_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  epub_path TEXT NOT NULL,
  extract_dir TEXT NOT NULL,
  chapter_count INTEGER NOT NULL,
  chapters_json TEXT NOT NULL,
  imported_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO epub_books "
          "(book_key, title, epub_path, extract_dir, chapter_count, chapters_json, imported_at) "
          "VALUES "
          // ① Windows 反斜杠形态。
          "('A', 'A', 'a.epub', 'D:\\Docs\\hoshi_books\\A', 1, '[]', 1), "
          // ② POSIX 正斜杠形态。
          "('B', 'B', 'b.epub', '/home/u/Documents/hoshi_books/B', 1, '[]', 2), "
          // 无关行：不含目录段。
          "('C', 'C', 'c.epub', '/data/other_dir/C', 1, '[]', 3)",
        );

        raw.execute('''
CREATE TABLE media_items (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  media_identifier TEXT NOT NULL,
  title TEXT NOT NULL,
  media_type_identifier TEXT NOT NULL,
  media_source_identifier TEXT NOT NULL,
  unique_key TEXT NOT NULL UNIQUE,
  image_url TEXT,
  position INTEGER NOT NULL,
  duration INTEGER NOT NULL,
  can_delete INTEGER NOT NULL,
  can_edit INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO media_items "
          "(media_identifier, title, media_type_identifier, media_source_identifier, unique_key, image_url, position, duration, can_delete, can_edit) "
          "VALUES "
          // ③ file:// URI（恒正斜杠）。
          "('hoshi://book/A', 'A', 'reader', 'reader_fushi', 'reader_fushi/hoshi://book/A', "
          "'file:///D:/Docs/hoshi_books/A/cover.jpg', 0, 0, 1, 1), "
          // 无关行：image_url NULL。
          "('hoshi://book/B', 'B', 'reader', 'reader_fushi', 'reader_fushi/hoshi://book/B', "
          "NULL, 0, 0, 1, 1)",
        );

        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');
        raw.execute(
          "INSERT INTO preferences (key, value) VALUES "
          // ④ 已删功能残留：清行。
          "('google_drive_hoshi_compat', 'b:true'), "
          "('sync_backend_type', 's:googleDrive')",
        );

        raw.execute('PRAGMA user_version = 71');
      },
    ),
  );
}

void main() {
  test('v71->v72 rewrites hoshi_books paths and clears dead pref', () async {
    final FushiDatabase db = _openMigratedFromV71();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion);

    final rows = await db
        .customSelect(
            'SELECT book_key, extract_dir FROM epub_books ORDER BY id')
        .get();
    expect(rows[0].read<String>('extract_dir'), r'D:\Docs\fushi_books\A',
        reason: '① 反斜杠形态改写');
    expect(
        rows[1].read<String>('extract_dir'), '/home/u/Documents/fushi_books/B',
        reason: '② 正斜杠形态改写');
    expect(rows[2].read<String>('extract_dir'), '/data/other_dir/C',
        reason: '无关行不动');

    final mi = await db
        .customSelect('SELECT image_url FROM media_items ORDER BY id')
        .get();
    expect(mi[0].read<String?>('image_url'),
        'file:///D:/Docs/fushi_books/A/cover.jpg',
        reason: '③ file:// URI 改写');
    expect(mi[1].read<String?>('image_url'), isNull);

    final prefs =
        await db.customSelect('SELECT key FROM preferences ORDER BY key').get();
    expect(prefs.map((r) => r.read<String>('key')).toList(),
        <String>['sync_backend_type'],
        reason: '④ google_drive_hoshi_compat 清行，无关键保留');
  });
}
