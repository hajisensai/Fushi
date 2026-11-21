// 单条改动超过内核载荷上限（16 MiB，native/fushi_fsrs/src/gen4/op.rs `MAX_OP_PAYLOAD`）时，经真实 SrsDbStore（语句走
// 后台 isolate 往返）冒到调用方的是**类型化**的 [SrsOpTooLargeException]，界面据此给专门的本地化提示
// （fushi/lib/src/srs/srs_action_error_text.dart），不靠匹配内核英文原话：
// - 本机写入（加笔记）：整笔回滚、什么都没存；
// - .apkg 导入：落库的那一批整批回滚，错误不被包成「包损坏」（`SrsImportException.corrupt`）。
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'apkg/srs_apkg_import_test.dart'
    show
        crtSecs,
        kBasic,
        kDeckJp,
        kFullOptions,
        legacyDconf,
        legacyDecks,
        legacyModels,
        ms;
import 'support/srs_test_storage.dart';

/// 比上限多一个字节的字段（纯 ASCII：字节数 = 字符数）。
final String kOverCap = 'x' * (16 * 1024 * 1024 + 1);

void main() {
  late SrsDbStore store;

  setUp(() async {
    final Directory tmp = Directory.systemTemp.createTempSync('srs_too_big_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 句柄滞后：留给系统清理。
      }
    });
    final TestSrs srs = openTestSrsIn(tmp.path);
    store = await SrsDbStore.open(
      core: srs.core,
      profileUid: '01928c3e-0000-7000-8000-0000000b16b1',
      deviceId: 'too-big',
      engine: const FakeFsrsEngine(),
      fallbackRolloverHour: () => 4,
    );
  });

  test('本机加笔记超过上限：抛 SrsOpTooLargeException、什么都没存，之后照常能写', () async {
    final String field = srsLapisFieldId(store.profileUid, 'Expression');
    await expectLater(
      store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{field: kOverCap},
      ),
      throwsA(isA<SrsOpTooLargeException>()),
    );
    expect(await store.userNoteCount(), 0);
    await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{field: '食べる'},
    );
    expect(await store.userNoteCount(), 1);
  });

  test('.apkg 里一条笔记超过上限：抛 SrsOpTooLargeException（不是包损坏），这一批没落库', () async {
    final int base = ms(2025, 1, 1);
    FxNote note(int i, String front) => FxNote(
      id: base + i,
      guid: 'big-$i',
      mid: kBasic,
      fields: <String>[front, 'back $i'],
      cards: <FxCard>[
        FxCard(
          id: (base + i) * 2,
          ord: 0,
          did: kDeckJp,
          type: 0,
          queue: 0,
          due: i,
          ivl: 0,
          factor: 0,
          reps: 0,
        ),
      ],
    );
    final Uint8List bytes = zipOf(<String, List<int>>{
      'collection.anki21': buildLegacyCollection(
        crtSecs: crtSecs,
        conf: <String, Object?>{'rollover': 4, 'localOffset': 0},
        models: legacyModels(),
        decks: legacyDecks(),
        dconf: legacyDconf(),
        notes: <FxNote>[note(0, 'small'), note(1, kOverCap)],
      ),
      'media': '{}'.codeUnits,
    });
    Object? failure;
    try {
      await importAnkiPackage(
        store: store,
        bytes: bytes,
        storeMedia: (String name, Uint8List b) async => name,
        options: kFullOptions,
        zstdDecompress: (Uint8List b) => null,
      );
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<SrsOpTooLargeException>(), reason: '$failure');
    expect(await store.userNoteCount(), 0);
  });
}
