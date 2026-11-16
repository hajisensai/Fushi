// S1c：`apply` 回包按输入下标认领（srs_db_store.dart `srsWrittenByInput`）。纯 Dart，用假的内核回包：
// 新代把值没变的草稿丢掉（native/fushi_fsrs/src/store/gen4/cmd/writes.rs `drop_noops`），`edits` 里只剩真正落库的，
// 实体 ID 已归一，每项第 7 列是它来自第几条输入；整列表标签草稿在 `tagWrites` 里报一项。
import 'package:fushi_engine/srs/srs_db_store.dart'
    show SrsWrittenItem, srsWrittenByInput;
import 'package:test/test.dart';

List<Object?> _edit(
  String kind,
  String id,
  String key,
  String dev,
  int seq,
  int? at,
) => <Object?>[kind, id, key, dev, seq, 'v$seq', at];

SrsWrittenItem _item(
  String kind,
  String id,
  String key,
  String dev,
  int seq, {
  bool tags = false,
}) => (kind: kind, entity: id, key: key, writer: dev, seq: seq, tags: tags);

void main() {
  test(
    'a no-op draft does not claim another entity\'s edit on the same key',
    () {
      // editFieldsBatch：笔记 A、B 的同一个键，A 没变（内核丢掉）、B 变了。
      expect(
        srsWrittenByInput(2, <String, Object?>{
          'edits': <Object?>[_edit('note', 'B', 'f/front', 'dev', 7, 1)],
        }),
        <SrsWrittenItem?>[null, _item('note', 'B', 'f/front', 'dev', 7)],
      );
    },
  );

  test('a salted member claims its canonical edit by index', () {
    // 草稿点名的是别名类的非规范成员 A2，回包里是规范的 A：按下标认领，不必先把 A2 归一。
    expect(
      srsWrittenByInput(2, <String, Object?>{
        'edits': <Object?>[
          _edit('note', 'A', 'f/x', 'dev', 1, 0),
          _edit('note', 'A', 'f/x', 'dev', 2, 1),
        ],
      }),
      <SrsWrittenItem?>[
        _item('note', 'A', 'f/x', 'dev', 1),
        _item('note', 'A', 'f/x', 'dev', 2),
      ],
    );
  });

  test('tag list drafts claim their tagWrites item', () {
    expect(
      srsWrittenByInput(3, <String, Object?>{
        'edits': <Object?>[_edit('card', 'C', 'flag', 'dev', 9, 2)],
        'tagWrites': <Object?>[
          <Object?>[0, 'N', 'dev', 8],
        ],
      }),
      <SrsWrittenItem?>[
        _item('note', 'N', 'tags', 'dev', 8, tags: true),
        null,
        _item('card', 'C', 'flag', 'dev', 9),
      ],
    );
  });

  test('edits the command made up itself (no index) claim nothing', () {
    expect(
      srsWrittenByInput(1, <String, Object?>{
        'edits': <Object?>[_edit('card', 'C', 'deck', 'dev', 3, null)],
      }),
      <SrsWrittenItem?>[null],
    );
  });

  test('a double claim or an index out of range is a contract error', () {
    expect(
      () => srsWrittenByInput(1, <String, Object?>{
        'edits': <Object?>[
          _edit('note', 'A', 'f/x', 'dev', 1, 0),
          _edit('note', 'B', 'f/x', 'dev', 2, 0),
        ],
      }),
      throwsStateError,
    );
    expect(
      () => srsWrittenByInput(1, <String, Object?>{
        'tagWrites': <Object?>[
          <Object?>[1, 'N', 'dev', 8],
        ],
      }),
      throwsStateError,
    );
  });
}
