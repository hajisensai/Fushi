// G7-5 复核修复：修改记录草稿 ↔ `apply` 回包 `edits` 的配对（srs_db_store.dart `srsMatchWrittenEdits`）。
// 纯 Dart，用假的内核回包：新代把值没变的草稿丢掉（native/fushi_fsrs/src/store/gen4/cmd/writes.rs `drop_noops`），
// `edits` 里只剩真正落库的，实体 ID 已归一。
import 'package:fushi_engine/srs/srs_db_store.dart' show srsMatchWrittenEdits;
import 'package:test/test.dart';

List<Object?> _edit(String kind, String id, String key, String dev, int seq) =>
    <Object?>[kind, id, key, dev, seq, 'v$seq'];

void main() {
  test(
    'a no-op draft does not claim another entity\'s edit on the same key',
    () {
      // editFieldsBatch：笔记 A、B 的同一个键，A 没变（内核丢掉）、B 变了。
      final List<Object?> b = _edit('note', 'B', 'f/front', 'dev', 7);
      final List<List<Object?>?> m = srsMatchWrittenEdits(
        <(String, String, String)>[
          ('note', 'A', 'f/front'),
          ('note', 'B', 'f/front'),
        ],
        <Object?>[b],
      );
      expect(m, <List<Object?>?>[null, b]);
    },
  );

  test('drafts on the same entity and key claim in order', () {
    final List<Object?> first = _edit('note', 'A', 'f/x', 'dev', 1);
    final List<Object?> second = _edit('note', 'A', 'f/x', 'dev', 2);
    expect(
      srsMatchWrittenEdits(
        <(String, String, String)>[('note', 'A', 'f/x'), ('note', 'A', 'f/x')],
        <Object?>[first, second],
      ),
      <List<Object?>?>[first, second],
    );
  });

  test('kind and key both have to match', () {
    final List<Object?> deck = _edit('deck', 'A', 'name', 'dev', 3);
    final List<Object?> other = _edit('note', 'A', 'f/y', 'dev', 4);
    expect(
      srsMatchWrittenEdits(
        <(String, String, String)>[
          ('note', 'A', 'name'),
          ('note', 'A', 'f/x'),
          ('deck', 'A', 'name'),
        ],
        <Object?>[deck, other],
      ),
      <List<Object?>?>[null, null, deck],
    );
  });

  test('mixed batch: every written edit goes to its own draft', () {
    final List<Object?> c = _edit('card', 'C', 'flag', 'dev', 10);
    final List<Object?> n2 = _edit('note', 'N2', 'f/front', 'dev', 11);
    final List<Object?> n3 = _edit('note', 'N3', 'f/front', 'dev', 12);
    expect(
      srsMatchWrittenEdits(
        <(String, String, String)>[
          ('note', 'N1', 'f/front'), // 没变
          ('card', 'C', 'flag'),
          ('note', 'N2', 'f/front'),
          ('note', 'N4', 'f/front'), // 没变
          ('note', 'N3', 'f/front'),
        ],
        <Object?>[c, n2, n3],
      ),
      <List<Object?>?>[null, c, n2, null, n3],
    );
  });
}
