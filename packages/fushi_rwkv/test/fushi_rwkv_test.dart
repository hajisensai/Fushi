// 真库 + 真权重：库找不到、权重没下载都判红（硬依赖，不 skip）。
// 权重：native/fushi_rwkv/fetch_model.{sh,ps1}；库：native/fushi_rwkv/build_*.{ps1,sh} 或 FUSHI_RWKV_LIB。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:test/test.dart';

Directory _crateDir() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 8; i++) {
    final Directory candidate = Directory('${dir.path}/native/fushi_rwkv');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  throw StateError(
    'native/fushi_rwkv not found above ${Directory.current.path}',
  );
}

File _modelFile(String name) {
  final File file = File('${_crateDir().path}/model/$name');
  if (!file.existsSync()) {
    fail('$name missing: run native/fushi_rwkv/fetch_model.sh (or .ps1) first');
  }
  return file;
}

/// 小模型 int8 权重：从发布包里解出来落到临时文件（worker 按路径加载）。
File _smallWeights() {
  final Archive zip = ZipDecoder().decodeBytes(
    _modelFile('sm56-package.zip').readAsBytesSync(),
  );
  final ArchiveFile entry = zip.findFile('sm56/weights.int8.bin')!;
  final File out = File(
    '${Directory.systemTemp.createTempSync('fushi_rwkv').path}/sm56.int8.bin',
  )..writeAsBytesSync(entry.content as List<int>);
  return out;
}

/// 确定性小历史：40 张卡（两卡一笔记）、60 天；返回回放行与「今天」的作答行。
(RwkvRows, RwkvRows) _history() {
  final RwkvRows rows = RwkvRows();
  final List<(int, int)?> last = List<(int, int)?>.filled(40, null);
  int seed = 11;
  int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  void add(RwkvRows into, int card, int day, int ts, int ease) {
    final (int, int)? prev = last[card];
    into.add(
      cardId: 100 + card,
      noteId: 500 + card ~/ 2,
      deckId: 1 + card % 2,
      presetId: 1,
      ease: ease,
      durationMs: 3000,
      cardType: prev == null ? 0 : 2,
      dayOffset: day,
      elapsedDays: prev == null ? -1 : day - prev.$1,
      elapsedSeconds: prev == null ? -1 : ts - prev.$2,
    );
  }

  for (int day = 0; day < 60; day++) {
    int ts = day * 86400 + 32400;
    for (int card = 0; card < 40; card++) {
      final (int, int)? prev = last[card];
      final bool due = prev == null
          ? card ~/ 2 == day
          : day - prev.$1 >= 1 + next() % 7;
      if (!due) continue;
      add(rows, card, day, ts, const <int>[1, 3, 3, 3, 4, 2][next() % 6]);
      last[card] = (day, ts);
      ts += 20;
    }
  }
  final RwkvRows answer = RwkvRows();
  add(answer, 3, 60, 60 * 86400 + 32400, 0);
  return (rows, answer);
}

void main() {
  test('library loads with the expected ABI', () {
    final FushiRwkv lib = FushiRwkv.instance;
    expect(lib.libraryPath, isNotNull);
  });

  test('rows encode the C layout', () {
    final RwkvRows rows = RwkvRows(1)
      ..add(cardId: 7, ease: 3, dayOffset: 5, elapsedDays: -1)
      ..add(cardId: 8, noteId: 9, ease: 0);
    expect(rows.length, 2);
    expect(rows.bytes.length, 160);
    expect(rows.cardIdAt(1), 8);
    expect(rows.easeAt(0), 3);
    expect(rows.dayOffsetAt(0), 5);
    final ByteData data = ByteData.sublistView(rows.bytes);
    expect(
      data.getUint32(72, Endian.little),
      FrwkvPresent.dayOffset | FrwkvPresent.elapsedDays,
    );
    expect(data.getUint32(80 + 72, Endian.little), FrwkvPresent.noteId);
  });

  for (final String which in <String>['small', 'large']) {
    test(
      '$which model: streaming snapshots preserve bytes across native and worker APIs',
      () async {
        final Directory directory = Directory.systemTemp.createTempSync(
          'fushi_rwkv_stream_',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final File weights = which == 'small'
            ? _smallWeights()
            : _modelFile('RWKV_trained_on_5000_10000.bin');
        if (which == 'small') {
          addTearDown(() => weights.parent.deleteSync(recursive: true));
        }
        final RwkvNativeModel model = RwkvNativeModel.load(
          weights.readAsBytesSync(),
        );
        final RwkvNativeRuntime runtime = RwkvNativeRuntime.create(
          model,
          threads: 2,
        );
        addTearDown(runtime.dispose);
        final RwkvWorker worker = await RwkvWorker.spawn(
          modelPath: weights.path,
          threads: 2,
        );
        addTearDown(worker.close);
        final (RwkvRows history, RwkvRows answer) = _history();
        runtime.replay(history);
        final Uint8List expected = runtime.snapshot();
        final Float32List predictions = runtime.query(answer);
        final File streamed = File('${directory.path}/中文 状态.rwkv');
        runtime.snapshotToFile(streamed.path);
        expect(streamed.readAsBytesSync(), expected);

        // 新文件由旧字节接口恢复，旧快照文件由新流式接口恢复。
        await worker.restore(streamed.readAsBytesSync());
        expect(await worker.query(answer), predictions);
        final File legacy = File('${directory.path}/旧格式.rwkv')
          ..writeAsBytesSync(expected);
        await worker.reset();
        await worker.restoreFromFile(legacy.path);
        expect(await worker.snapshot(), expected);
        expect(await worker.query(answer), predictions);

        final File workerFile = File('${directory.path}/后台保存.rwkv');
        await worker.snapshotToFile(workerFile.path);
        expect(workerFile.readAsBytesSync(), expected);
        runtime.reset();
        runtime.restoreFromFile(workerFile.path);
        expect(runtime.snapshot(), expected);
        expect(runtime.query(answer), predictions);

        // 文件读错、截断或多出尾字节都不得留下部分恢复的状态。
        final File truncated = File('${directory.path}/截断.rwkv')
          ..writeAsBytesSync(expected.sublist(0, expected.length - 1));
        final File trailing = File('${directory.path}/尾部损坏.rwkv')
          ..writeAsBytesSync(<int>[...expected, 1]);
        // 当前状态与损坏文件的有效前缀不同，能发现原地恢复造成的部分覆盖。
        final RwkvRows newer = RwkvRows()
          ..add(
            cardId: 100,
            noteId: 500,
            deckId: 1,
            presetId: 1,
            ease: 3,
            dayOffset: 60,
            cardType: 2,
            elapsedDays: 5,
            elapsedSeconds: 5 * 86400,
          );
        runtime.replay(newer);
        await worker.replay(newer);
        final Uint8List protectedState = runtime.snapshot();
        expect(protectedState, isNot(expected));
        expect(await worker.snapshot(), protectedState);
        final List<String> invalidPaths = <String>[
          '${directory.path}/不存在.rwkv',
          truncated.path,
          trailing.path,
          '${legacy.path}\u0000ignored',
        ];
        for (final String path in invalidPaths) {
          expect(
            () => runtime.restoreFromFile(path),
            throwsA(isA<RwkvNativeException>()),
          );
          expect(runtime.snapshot(), protectedState);
          await expectLater(
            worker.restoreFromFile(path),
            throwsA(isA<RwkvNativeException>()),
          );
          expect(await worker.snapshot(), protectedState);
        }
        expect(
          () => runtime.snapshotToFile('${workerFile.path}\u0000ignored'),
          throwsA(isA<RwkvNativeException>()),
        );
        await expectLater(
          worker.snapshotToFile('${workerFile.path}\u0000ignored'),
          throwsA(isA<RwkvNativeException>()),
        );
        expect(workerFile.readAsBytesSync(), expected);

        runtime.dispose();
        expect(() => runtime.snapshotToFile(streamed.path), throwsStateError);
        expect(() => runtime.restoreFromFile(streamed.path), throwsStateError);
        await worker.close();
        await expectLater(
          worker.snapshotToFile(streamed.path),
          throwsStateError,
        );
        await expectLater(
          worker.restoreFromFile(streamed.path),
          throwsStateError,
        );
      },
    );

    test(
      '$which model: worker replays, queries, schedules and snapshots',
      () async {
        final File weights = which == 'small'
            ? _smallWeights()
            : _modelFile('RWKV_trained_on_5000_10000.bin');
        final RwkvWorker worker = await RwkvWorker.spawn(
          modelPath: weights.path,
          threads: 2,
        );
        addTearDown(worker.close);
        expect(
          worker.kind,
          which == 'small' ? RwkvModelKind.small : RwkvModelKind.large,
        );
        expect(
          worker.precision,
          which == 'small' ? RwkvPrecision.int4 : RwkvPrecision.int8,
        );
        final (RwkvRows history, RwkvRows answer) = _history();
        final Float32List? predictions = await worker.replay(
          history,
          predictions: true,
        );
        expect(predictions, hasLength(history.length));
        expect(
          predictions!.where((double p) => p.isFinite).length,
          history.length,
        );

        final RwkvStats stats = await worker.stats();
        expect(stats.reviews, history.length);
        expect(stats.cards, 40);

        final Uint8List snapshot = await worker.snapshot();
        final RwkvIntervals intervals = await worker.nextIntervals(
          answer,
          targetRetention: 0.85,
          maxIntervalDays: 365,
        );
        expect(intervals.days, hasLength(4));
        for (int i = 1; i < 4; i++) {
          expect(
            intervals.days[i],
            greaterThanOrEqualTo(intervals.days[i - 1]),
          );
        }
        expect(intervals.days.every((int d) => d >= 1 && d <= 365), isTrue);
        // 排程不改状态。
        expect(await worker.snapshot(), snapshot);

        final Float32List r = await worker.query(answer);
        expect(r.single, inInclusiveRange(0, 1));

        // 不合法的回放（日期倒退）整批拒收，错误码与信息都过 isolate 边界回来。
        final RwkvRows backwards = RwkvRows()
          ..add(cardId: 100, ease: 3, dayOffset: 1);
        await expectLater(
          worker.replay(backwards),
          throwsA(
            isA<RwkvNativeException>()
                .having((RwkvNativeException e) => e.isInput, 'isInput', isTrue)
                .having(
                  (RwkvNativeException e) => e.message,
                  'message',
                  contains('day_offset'),
                ),
          ),
        );

        await worker.reset();
        expect((await worker.stats()).reviews, 0);
        await worker.restore(snapshot);
        expect((await worker.stats()).reviews, history.length);
      },
    );
  }

  test(
    'worker: undo journal and score table cross the isolate boundary',
    () async {
      final RwkvWorker worker = await RwkvWorker.spawn(
        modelPath: _smallWeights().path,
        threads: 2,
      );
      addTearDown(worker.close);
      final (RwkvRows history, RwkvRows _) = _history();
      await worker.replay(history);
      final Uint8List before = await worker.snapshot();
      final RwkvRows today = RwkvRows()
        ..add(
          cardId: 103,
          noteId: 501,
          deckId: 2,
          presetId: 1,
          ease: 3,
          cardType: 2,
          dayOffset: 60,
          elapsedDays: 5,
          elapsedSeconds: 5 * 86400,
        );
      expect(await worker.append(today, <int>[77]), isTrue);
      expect(await worker.snapshot(), isNot(before));
      expect(await worker.unappend(76), isFalse);
      expect(await worker.unappend(77), isTrue);
      expect(await worker.snapshot(), before);

      final RwkvRows q = RwkvRows();
      for (int card = 0; card < 4; card++) {
        q.add(
          cardId: 100 + card,
          noteId: 500 + card ~/ 2,
          deckId: 1 + card % 2,
          presetId: 1,
          ease: 0,
          cardType: 2,
          dayOffset: 61,
          elapsedDays: 3,
          elapsedSeconds: 3 * 86400,
        );
      }
      final Float32List plain = await worker.query(q);
      final Float32List scored = await worker.updateScores(
        q,
        Uint64List.fromList(<int>[1, 2, 3, 4]),
        Int64List.fromList(<int>[-1, -1, -1, -1]),
      );
      expect(scored, plain);
      final RwkvScoreLookup hit = await worker.lookupScores(
        Int64List.fromList(<int>[100, 101, 102, 103]),
        Uint64List.fromList(<int>[1, 2, 9, 4]),
      );
      expect(hit.found, <int>[1, 1, 0, 1]);
      expect(hit.scores[0], plain[0]);
      expect(hit.scores[2].isNaN, isTrue);
      expect(await worker.requeryScores(61, 0), 4);
      // 永久清除的卡：项删掉（不存在的不算），整表重查只剩 3 项。
      expect(await worker.removeScores(Int64List.fromList(<int>[101, 999])), 1);
      expect(await worker.requeryScores(61, 0), 3);
      await worker.clearScores();
      expect(
        (await worker.lookupScores(
          Int64List.fromList(<int>[100]),
          Uint64List.fromList(<int>[1]),
        )).hits,
        0,
      );
    },
  );

  test('a damaged weight file is refused with a reason', () async {
    final File junk = File(
      '${Directory.systemTemp.createTempSync('fushi_rwkv').path}/junk.bin',
    )..writeAsBytesSync(<int>[1, 2, 3]);
    await expectLater(
      RwkvWorker.spawn(modelPath: junk.path),
      throwsA(
        isA<RwkvNativeException>().having(
          (RwkvNativeException e) => e.message,
          'message',
          contains('weights'),
        ),
      ),
    );
  });
}
