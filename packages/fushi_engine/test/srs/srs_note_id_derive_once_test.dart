// G5b 审查 G5B-1：新笔记的 ID 每条只向内核要一次。
//
// newNoteDrafts 收 noteId 参数，但调用方都没传，同一条笔记的 ID 重复派生（apkg 新笔记一条 3 次：块预读、
// 逐条处理、newNoteDrafts 里再一次）。现在 apkg 导入整块一次 FFI 要齐（_prefetchExisting），逐条处理按 guid
// 直接取；createNote / AnkiConnect addNotes 算一次、交给 newNoteDrafts 复用。用 SrsKernelIds.debugOnAsk
// 数跨边界的 'note' 请求：哪处再逐条派生，这里的计数就变多。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'ankiconnect/ankiconnect_harness.dart';
import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000aa';
const int kDeck = 1700000000010;
const int kMid = 1700000000077;

/// 跨边界的 'note' 请求：每次 FFI 一项（该次请求里 'note' 的个数）。
final List<int> noteAsks = <int>[];

void _record(List<List<Object?>> items) {
  final int n = items.where((List<Object?> i) => i.first == 'note').length;
  if (n > 0) noteAsks.add(n);
}

Uint8List apkgOf(List<String> guids) => zipOf(<String, List<int>>{
  'collection.anki21': buildLegacyCollection(
    crtSecs: DateTime.utc(2026, 1, 1, 4).millisecondsSinceEpoch ~/ 1000,
    conf: <String, Object?>{'rollover': 4, 'localOffset': 0},
    models: <String, Object?>{
      '$kMid': <String, Object?>{
        'id': kMid,
        'name': 'Basic',
        'type': 0,
        'css': '',
        'flds': <Object?>[
          <String, Object?>{'name': 'Front', 'ord': 0, 'id': 9000},
          <String, Object?>{'name': 'Back', 'ord': 1, 'id': 9001},
        ],
        'tmpls': <Object?>[
          <String, Object?>{
            'name': 'Card 1',
            'ord': 0,
            'qfmt': '{{Front}}',
            'afmt': '{{Back}}',
            'id': 9100,
          },
        ],
      },
    },
    decks: <String, Object?>{
      '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
      '$kDeck': <String, Object?>{
        'id': kDeck,
        'name': '日本語',
        'dyn': 0,
        'conf': 1,
      },
    },
    dconf: <String, Object?>{
      '1': <String, Object?>{'id': 1, 'name': 'Default'},
    },
    notes: <FxNote>[
      for (int i = 0; i < guids.length; i++)
        FxNote(
          id: 1754006400000 + i,
          guid: guids[i],
          mid: kMid,
          fields: <String>['語$i', 'word$i'],
          cards: <FxCard>[FxCard(id: 100 + i, ord: 0, did: kDeck)],
        ),
    ],
  ),
  'media': utf8.encode('{}'),
});

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final int now = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;

  setUp(noteAsks.clear);
  tearDown(() => SrsKernelIds.debugOnAsk = null);

  test('apkg 导入：一块新笔记的 ID 整块一次 FFI，每条只派生一次', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => now,
    );
    const List<String> guids = <String>['g0', 'g1', 'g2'];
    final Uint8List bytes = apkgOf(guids);
    SrsKernelIds.debugOnAsk = _record;
    final SrsImportReport rep = await importAnkiPackage(
      store: s,
      bytes: bytes,
      storeMedia: (String n, Uint8List b) async => 'h_$n',
      options: const SrsAnkiImportOptions(),
      zstdDecompress: (Uint8List b) => null,
    );
    SrsKernelIds.debugOnAsk = null;
    expect(rep.notesAdded, guids.length);
    expect(noteAsks, <int>[guids.length]);
    // 落库的就是内核答的那几个 ID。
    expect(
      (await s.entityIds(SrsEntityKind.note)).toSet(),
      containsAll(s.kernelIds.notes(guids)),
    );
  });

  test('createNote：ID 只派生一次', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => now,
    );
    final String ntId = s.lapisNoteTypeId;
    SrsKernelIds.debugOnAsk = _record;
    final String id = await s.createNote(
      noteTypeId: ntId,
      fieldsById: const <String, String>{},
      guid: 'gc',
    );
    SrsKernelIds.debugOnAsk = null;
    expect(noteAsks, <int>[1]);
    expect(id, s.kernelIds.note('gc'));
  });

  test('AnkiConnect addNotes：每条笔记的 ID 只派生一次', () async {
    final AcHarness h = await AcHarness.create();
    SrsKernelIds.debugOnAsk = _record;
    final Object? out = await h.ok('addNotes', <String, Object?>{
      'notes': <Object?>[yomitanNote('一'), yomitanNote('二')],
    });
    SrsKernelIds.debugOnAsk = null;
    expect(out, <Object?>[isA<int>(), isA<int>()]);
    expect(noteAsks, <int>[1, 1]);
  });
}
