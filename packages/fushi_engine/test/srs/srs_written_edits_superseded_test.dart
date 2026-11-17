// 第五波（写接口契约）：同一批里后一条写入盖掉前一条时，内核回包把前一项明确标成「被盖掉」
// （native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头「回包」修改行），[SrsDbStore.writeEdits] 只交回落库后活着的
// 那条（同一个键取最后一条），不再因为前一项没有行而抛 StateError。走真内核。
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show openTestStore;

const String _profile = 'p-w5-superseded';

void main() {
  test('同批同键写两次：只交回最后一条，值与落库一致；标签同理', () async {
    int t = DateTime.utc(2026, 11, 18, 9).millisecondsSinceEpoch;
    final SrsDbStore s = await openTestStore(
      profileUid: _profile,
      deviceId: 'dev-w5',
      now: () => t,
    );
    final String field = srsLapisFieldId(_profile, 'Expression');
    final String noteId = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{field: '一'},
    );
    t += 1000;
    final String key = SrsFieldKeys.noteField(field);
    final List<SrsFieldEdit> written = await s.writeEdits(<SrsEditSpec>[
      SrsEditSpec(SrsEntityKind.note, noteId, key, '二'),
      SrsEditSpec(SrsEntityKind.note, noteId, SrsFieldKeys.noteTags, <String>[
        'x',
      ]),
      SrsEditSpec(SrsEntityKind.note, noteId, key, '三'),
      SrsEditSpec(SrsEntityKind.note, noteId, SrsFieldKeys.noteTags, <String>[
        'y',
        'x',
      ]),
    ]);
    expect(written.map((SrsFieldEdit e) => e.value).toList(), <Object?>[
      '三',
      <String>['y', 'x'],
    ]);
    expect(
      written.map((SrsFieldEdit e) => e.fieldKey).toSet(),
      hasLength(2),
      reason: 'one edit per key',
    );
    final SrsNoteView note = (await s.note(noteId))!;
    expect(note.fields.values, contains('三'));
    expect(note.tags.toSet(), <String>{'x', 'y'});
  });
}
