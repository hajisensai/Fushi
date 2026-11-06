import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000a2';

/// 导入攒的「新笔记」草稿是**初值**：攒批期间同一条笔记（ID 由 guid 确定性派生）已经被写进
/// 本机（同步应用了对端的迁移与编辑，或本机别处建了它），落库时这些键不再写——否则初值在落库
/// 时才分配 HLC，会支配那条更新的编辑，把用户的新值盖回源里的旧值。
void main() {
  int t = DateTime.utc(2026, 10, 19, 12).millisecondsSinceEpoch;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device() =>
      openTestStore(profileUid: kProfile, deviceId: 'a', now: () => t);

  String fushi(String key) => srsFushiCardFieldId(kProfile, key);

  test('initial drafts never override a note written while the batch was '
      'being built', () async {
    final SrsDbStore s = await device();
    const String guid = 'guid-import-race';
    // 攒批：导入器以为本机还没有这条笔记（current: null）。
    final List<SrsEventDraft> drafts = s.newNoteDrafts(
      noteTypeId: s.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        fushi('Expression'): '琢磨',
        fushi('MiscInfo'): 'Anki old',
      },
      guid: guid,
      tags: const <String>['from-anki'],
    );
    // 攒批期间：同一条笔记已经落库并被用户改过（同一 guid → 同一 noteId）。
    t += 1000;
    final String id = await s.createNote(
      noteTypeId: s.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        fushi('Expression'): '琢磨',
        fushi('MiscInfo'): 'Anki old',
      },
      guid: guid,
    );
    t += 1000;
    await s.editFields(SrsEntityKind.note, id, <String, Object?>{
      SrsFieldKeys.noteField(fushi('MiscInfo')): 'user edit',
    });

    t += 1000;
    await s.importDrafts(drafts);

    final SrsNoteView n = (await s.note(id))!;
    expect(n.field(fushi('MiscInfo')), 'user edit');
    expect(n.field(fushi('Expression')), '琢磨');
    // 本机还没写过的键（标签）照常作为初值落下。
    expect(n.tags, <String>['from-anki']);
  });

  test('initial drafts for a genuinely new note land in full', () async {
    final SrsDbStore s = await device();
    final List<SrsEventDraft> drafts = s.newNoteDrafts(
      noteTypeId: s.fushiCardNoteTypeId,
      fieldsById: <String, String>{fushi('Expression'): '新'},
      guid: 'guid-new',
    );
    await s.importDrafts(drafts);
    final SrsNoteView n = (await s.note(SrsIds.note(kProfile, 'guid-new')))!;
    expect(n.field(fushi('Expression')), '新');
  });
}
