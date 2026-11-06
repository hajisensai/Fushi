import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<Set<String>> _columnNames(FushiDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect('PRAGMA table_info($table)')
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

Future<Set<String>> _indexNames(FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

void main() {
  test('fresh v48 database contains all v48 hot-path indexes', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.getPref('force-open');
    expect(await _columnNames(db, 'epub_books'), contains('completed_at'));
    expect(
      await _columnNames(db, 'revealed_images'),
      containsAll(<String>['book_uid', 'image_key', 'revealed_at']),
    );
    expect(
      await _indexNames(db),
      containsAll(<String>[
        'idx_audio_cues_book_chapter_sentence',
        // v79 五张标签映射表合一：per-table tag_id 索引随旧表消亡，
        // 统一表一条索引覆盖全部 kind。
        'idx_tag_assignments_tag_id',
        'idx_favorite_words_source_type',
      ]),
    );
  });
}
