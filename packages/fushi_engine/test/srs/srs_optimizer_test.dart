import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_optimizer.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000aa';

FfiFsrsEngine? _realEngine() {
  final String sep = Platform.pathSeparator;
  final String name = Platform.isWindows
      ? 'windows-x64${sep}fushi_fsrs.dll'
      : Platform.isMacOS
      ? 'macos${sep}libfushi_fsrs.dylib'
      : 'linux-x64${sep}libfushi_fsrs.so';
  final String path =
      Platform.environment['FUSHI_FSRS_LIB'] ??
      '..$sep..${sep}native${sep}fushi_fsrs${sep}prebuilt$sep$name';
  return File(path).existsSync()
      ? FfiFsrsEngine.tryCreate(libraryPath: path)
      : null;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('触发判定', () {
    SrsDeckView deck({int? baseAt, int? baseN, bool auto = true}) {
      final SrsEditWriter w = SrsEditWriter(writerId: 'w');
      SrsFieldEdit e(String k, Object? v) => w.create(
        profileUid: kProfile,
        entityKind: SrsEntityKind.deck,
        entityId: 'd',
        fieldKey: k,
        value: v,
        hlc: const Hlc(1, 0, 'w'),
        timeSource: SrsTimeSource.wall,
      );
      return srsMaterializeDecks(<SrsEntitySource>[
        SrsEntitySource.record(
          const SrsEntityRecord(
            id: 'd',
            profileUid: kProfile,
            kind: SrsEntityKind.deck,
            payload: <String, Object?>{},
          ),
          <SrsEditItem>[
            for (final SrsFieldEdit x in <SrsFieldEdit>[
              if (baseAt != null)
                e(SrsFieldKeys.deckOptimizeBaseline, <String, Object?>{
                  'at': baseAt,
                  'n': baseN,
                }),
              e(SrsFieldKeys.deckAutoOptimize, auto),
            ])
              SrsEditItem.of(x, null),
          ],
        ),
      ]).single;
    }

    test('门槛、增长比例、30 天、关闭开关、不认识的 rev', () {
      expect(
        srsShouldOptimize(
          owner: deck(),
          reviewCount: 399,
          nowMs: 0,
          knownAlgorithmRev: true,
        ),
        isFalse,
      );
      expect(
        srsShouldOptimize(
          owner: deck(),
          reviewCount: 400,
          nowMs: 0,
          knownAlgorithmRev: true,
        ),
        isTrue,
      );
      expect(
        srsShouldOptimize(
          owner: deck(baseAt: 0, baseN: 1000),
          reviewCount: 1100,
          nowMs: 1,
          knownAlgorithmRev: true,
        ),
        isFalse,
      );
      expect(
        srsShouldOptimize(
          owner: deck(baseAt: 0, baseN: 1000),
          reviewCount: 1200,
          nowMs: 1,
          knownAlgorithmRev: true,
        ),
        isTrue,
      );
      expect(
        srsShouldOptimize(
          owner: deck(baseAt: 0, baseN: 1000),
          reviewCount: 1000,
          nowMs: kSrsOptimizeIntervalMs,
          knownAlgorithmRev: true,
        ),
        isTrue,
      );
      expect(
        srsShouldOptimize(
          owner: deck(auto: false),
          reviewCount: 5000,
          nowMs: 0,
          knownAlgorithmRev: true,
        ),
        isFalse,
      );
      expect(
        srsShouldOptimize(
          owner: deck(),
          reviewCount: 5000,
          nowMs: 0,
          knownAlgorithmRev: false,
        ),
        isFalse,
      );
    });
  });

  final FfiFsrsEngine? engine = _realEngine();
  group(
    '真实 FFI：准备 → 优化 → 写回',
    () {
      test('合成复习历史上跑出参数并以机器产出写回', () async {
        int t = DateTime.utc(2026, 1, 1, 12).millisecondsSinceEpoch;
        final SrsStorage srsStorage = await openTestSrsStorage();
        final SrsDbStore store = await SrsDbStore.open(
          db: srsStorage.db,
          core: srsStorage.core,
          profileUid: kProfile,
          deviceId: 'dev',
          engine: engine,
          trustedClock: SrsTrustedClock(wallClockMs: () => t, bootId: 'b'),
        );
        final Random r = Random(7);
        final List<String> cards = <String>[];
        for (int i = 0; i < 150; i++) {
          final String noteId = await store.createNote(
            noteTypeId: store.lapisNoteTypeId,
            fieldsById: <String, String>{
              srsLapisFieldId(kProfile, 'Expression'): 'w$i',
            },
          );
          cards.add((await store.cardsOfNote(noteId)).single.id);
        }
        // 每张卡每隔几天复习一次，按难度随机给分。
        for (int day = 0; day < 60; day++) {
          t += 86400000;
          for (final String c in cards) {
            final SrsCardCacheRow row = (await store.cardRow(c))!;
            final int today = (await store.dayContext()).dayIndexOf(t);
            final bool due =
                row.queue == SrsQueue.newCard.wire ||
                (row.queue == SrsQueue.review.wire &&
                    (row.dueDay ?? 0) <= today) ||
                (row.dueAt ?? 0) <= t;
            if (!due) continue;
            await store.answer(c, r.nextInt(10) == 0 ? 1 : 3);
          }
        }
        final SrsOptimizationInput? input = await srsPrepareOptimization(
          store,
          store.defaultDeckId,
        );
        expect(input, isNotNull);
        expect(input!.reviewCount, greaterThan(kSrsOptimizeMinItems));
        final SrsOptimizationResult res = srsRunOptimization(engine!, input);
        expect(res.params, hasLength(SrsAlgorithm.fsrs7.paramCount));
        await srsApplyOptimization(store, res, fsrsRev: engine.fsrsRev);
        final SrsDeckView deck = (await store.deckTree())[store.defaultDeckId]!;
        expect(deck.optimizeBaselineCount, input.reviewCount);
        if (res.adopted) {
          expect(deck.fsrs7!.params, res.params);
          expect(
            deck.edits[SrsFieldKeys.deckFsrs7Params]!.winner!.machine,
            isTrue,
          );
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    },
    skip: engine == null
        ? 'native fushi_fsrs not built (run native/fushi_fsrs/build_windows_dll.ps1)'
        : false,
  );
}
