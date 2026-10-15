// native/fushi_fsrs（fsrs-rs C ABI）的真实 FFI 调用测试。
//
// 库定位：环境变量 FUSHI_FSRS_LIB，缺省用本仓 native/fushi_fsrs/prebuilt/<平台>/ 下
// 构建脚本的产物。库不可用时整组 skip 并打印原因（CI 用输出里的 'native library not found'
// 断言没有被静默跳过，与 packages/fushi_p2p 同一约定）。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_srs/src/algorithm.dart';
import 'package:fushi_srs/src/ffi/ffi_fsrs_engine.dart';
import 'package:fushi_srs/src/ffi/fushi_fsrs_library.dart';
import 'package:fushi_srs/src/fsrs_engine.dart';
import 'package:test/test.dart';

/// 本仓构建脚本的默认产物路径（相对 packages/fushi_srs）。
String _defaultPrebuiltPath() {
  final String sep = Platform.pathSeparator;
  final String root = '..$sep..${sep}native${sep}fushi_fsrs${sep}prebuilt';
  if (Platform.isWindows) return '$root${sep}windows-x64${sep}fushi_fsrs.dll';
  if (Platform.isMacOS) return '$root${sep}macos${sep}libfushi_fsrs.dylib';
  return '$root${sep}linux-x64${sep}libfushi_fsrs.so';
}

String _libraryPath() {
  final String? env = Platform.environment[kFushiFsrsLibEnv];
  if (env != null && env.isNotEmpty) return env;
  return File(_defaultPrebuiltPath()).absolute.path;
}

/// 确定性的合成复习数据：每张卡一串评分，间隔随评分增长，含当天内（小数天）复习。
/// 返回值是优化器要的 items：每张卡到第 k 次评分为止的历史前缀（k ≥ 2）。
List<List<SrsFsrsReview>> _syntheticItems({required int cards, int seed = 7}) {
  final Random rng = Random(seed);
  final List<List<SrsFsrsReview>> items = <List<SrsFsrsReview>>[];
  for (int c = 0; c < cards; c++) {
    final List<SrsFsrsReview> history = <SrsFsrsReview>[];
    double interval = 1;
    final int reviews = 3 + rng.nextInt(7);
    for (int i = 0; i < reviews; i++) {
      final double delta;
      if (i == 0) {
        delta = 0;
      } else if (rng.nextDouble() < 0.15) {
        delta = 0.01 + rng.nextDouble() * 0.5; // 当天内复习
      } else {
        delta = (interval * (0.8 + rng.nextDouble() * 0.6)).roundToDouble();
      }
      final double recall = exp(-delta / (interval * 3 + 1));
      final int rating;
      if (rng.nextDouble() > recall * 0.95 + 0.05) {
        rating = 1;
        interval = max(1, interval * 0.3);
      } else {
        rating = 2 + rng.nextInt(3);
        interval = interval * (rating == 2 ? 1.3 : (rating == 3 ? 2.5 : 3.5));
      }
      history.add(SrsFsrsReview(rating: rating, deltaDays: delta));
      if (history.length >= 2) {
        items.add(List<SrsFsrsReview>.of(history));
      }
    }
  }
  return items;
}

/// 在后台 isolate 里跑一次优化（跨 isolate 共享原生取消 / 进度通道）。
Future<List<double>> _computeInIsolate({
  required String libraryPath,
  required SrsAlgorithm algorithm,
  required List<List<SrsFsrsReview>> items,
  required int cancelAddress,
  required int progressAddress,
}) {
  return Isolate.run<List<double>>(() {
    final FfiFsrsEngine engine = FfiFsrsEngine.tryCreate(
      libraryPath: libraryPath,
    )!;
    final NativeSrsOptimizerControl control =
        NativeSrsOptimizerControl.fromAddress(
          cancelAddress: cancelAddress,
          progressAddress: progressAddress,
        );
    return engine.computeParameters(
      algorithm: algorithm,
      items: items,
      control: control,
    );
  });
}

void main() {
  test('库缺失 => 不可用且不抛', () {
    final String bogus =
        '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}no_such_dir_fushi_fsrs'
        '${Platform.pathSeparator}${FushiFsrs.defaultLibraryName()}';
    expect(FushiFsrs.tryLoad(libraryPath: bogus), isNull);
    expect(FfiFsrsEngine.tryCreate(libraryPath: bogus), isNull);
    // 不测「默认规则全落空 → null」：main() 声明下面那组测试时已把真库加载进本进程，
    // Windows 上裸名 LoadLibrary 会直接命中已加载的模块，结论与库在不在磁盘无关。
    // 指向一个存在但不是动态库的文件：打开失败也只是不可用。
    final File notALib = File(
      '${Directory.systemTemp.createTempSync('fushi_fsrs_bad').path}'
      '${Platform.pathSeparator}${FushiFsrs.defaultLibraryName()}',
    )..writeAsStringSync('not a library');
    addTearDown(() => notALib.parent.deleteSync(recursive: true));
    expect(FushiFsrs.tryLoad(libraryPath: notALib.path), isNull);
  });

  test('candidate order: explicit, env, exe dir, bin/../lib, bare name', () {
    final String sep = Platform.pathSeparator;
    final String exe = '${sep}opt${sep}fushi${sep}bin${sep}fushi_server';
    final List<String> candidates = FushiFsrs.libraryCandidates(
      libraryPath: '${sep}explicit$sep${FushiFsrs.defaultLibraryName()}',
      environment: <String, String>{kFushiFsrsLibEnv: '${sep}from_env'},
      executablePath: exe,
    );
    final String name = FushiFsrs.defaultLibraryName();
    expect(candidates, hasLength(5));
    expect(candidates[0], endsWith('explicit$sep$name'));
    expect(candidates[1], '${sep}from_env');
    expect(candidates[2], endsWith('bin$sep$name'));
    expect(candidates[3], endsWith('lib$sep$name'));
    expect(candidates[4], name);
  });

  final String libraryPath = _libraryPath();
  final FfiFsrsEngine? engine = FfiFsrsEngine.tryCreate(
    libraryPath: libraryPath,
  );
  final String? skipReason = engine == null
      ? 'fushi_fsrs native library not found at $libraryPath '
            '(build native/fushi_fsrs or set $kFushiFsrsLibEnv)'
      : null;
  if (skipReason != null) {
    // ignore: avoid_print
    print('SKIP: $skipReason');
  }

  group('FfiFsrsEngine (real native library)', skip: skipReason, () {
    late FfiFsrsEngine e;
    setUpAll(() => e = engine!);

    test('fsrsRev is the pinned fsrs-rs revision', () {
      expect(e.fsrsRev, matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('defaults have 21 (FSRS-6) / 34 (FSRS-7) parameters', () {
      final List<double> six = e.defaultParams(SrsAlgorithm.fsrs6);
      final List<double> seven = e.defaultParams(SrsAlgorithm.fsrs7);
      expect(six, hasLength(SrsAlgorithm.fsrs6.paramCount));
      expect(six, hasLength(21));
      expect(seven, hasLength(SrsAlgorithm.fsrs7.paramCount));
      expect(seven, hasLength(34));
      expect(
        <double>[...six, ...seven].every((double v) => v.isFinite),
        isTrue,
      );
    });

    test('validate accepts defaults and rejects a wrong count', () {
      for (final SrsAlgorithm a in SrsAlgorithm.values) {
        expect(e.validateParams(a, e.defaultParams(a)), isNull);
      }
      expect(
        e.validateParams(SrsAlgorithm.fsrs7, <double>[1, 2]),
        contains('invalid parameter count'),
      );
      // FSRS-6 的 21 个参数不能当 FSRS-7 用，反之亦然。
      expect(
        e.validateParams(
          SrsAlgorithm.fsrs7,
          e.defaultParams(SrsAlgorithm.fsrs6),
        ),
        isNotNull,
      );
      expect(
        e.validateParams(
          SrsAlgorithm.fsrs6,
          e.defaultParams(SrsAlgorithm.fsrs7),
        ),
        isNotNull,
      );
      // NaN 进不了 JSON，也按不合法报。
      final List<double> nan = e.defaultParams(SrsAlgorithm.fsrs6)
        ..[0] = double.nan;
      expect(e.validateParams(SrsAlgorithm.fsrs6, nan), isNotNull);
    });

    test('wrong parameter count in a call throws SrsFsrsException', () {
      expect(
        () => e.nextStates(
          algorithm: SrsAlgorithm.fsrs6,
          params: <double>[1, 2, 3],
          desiredRetention: 0.9,
          memory: null,
          elapsedDays: 0,
        ),
        throwsA(isA<SrsFsrsException>()),
      );
    });

    test('next_states intervals are monotonic by rating', () {
      for (final SrsAlgorithm a in SrsAlgorithm.values) {
        for (final SrsMemory? memory in <SrsMemory?>[
          null,
          const SrsMemory(stability: 5, difficulty: 5),
        ]) {
          final SrsNextStates next = e.nextStates(
            algorithm: a,
            params: const <double>[],
            desiredRetention: 0.9,
            memory: memory,
            elapsedDays: memory == null ? 0 : 4.5,
          );
          final List<double> intervals = <double>[
            for (int r = 1; r <= 4; r++) next.forRating(r).interval,
          ];
          for (int i = 1; i < intervals.length; i++) {
            expect(
              intervals[i],
              greaterThanOrEqualTo(intervals[i - 1]),
              reason: '$a memory=$memory intervals=$intervals',
            );
          }
          expect(intervals.first, lessThan(intervals.last));
          expect(next.good.memory.stability, greaterThan(0));
        }
      }
    });

    test('fractional elapsed days change the FSRS-7 result', () {
      const SrsMemory memory = SrsMemory(stability: 1, difficulty: 5);
      double goodStability(double elapsed) => e
          .nextStates(
            algorithm: SrsAlgorithm.fsrs7,
            params: const <double>[],
            desiredRetention: 0.9,
            memory: memory,
            elapsedDays: elapsed,
          )
          .good
          .memory
          .stability;
      expect(goodStability(0.1), isNot(goodStability(0.9)));
    });

    test('memoryState rebuilds from history; empty history returns start', () {
      for (final SrsAlgorithm a in SrsAlgorithm.values) {
        final SrsMemory? m = e.memoryState(
          algorithm: a,
          params: const <double>[],
          reviews: const <SrsFsrsReview>[
            SrsFsrsReview(rating: 3, deltaDays: 0),
            SrsFsrsReview(rating: 3, deltaDays: 3),
            SrsFsrsReview(rating: 1, deltaDays: 10),
          ],
        );
        expect(m, isNotNull);
        expect(m!.stability, greaterThan(0));
        expect(m.difficulty, inInclusiveRange(1, 10));
      }
      expect(
        e.memoryState(
          algorithm: SrsAlgorithm.fsrs6,
          params: const <double>[],
          reviews: const <SrsFsrsReview>[],
        ),
        isNull,
      );
      const SrsMemory start = SrsMemory(stability: 7, difficulty: 4);
      final SrsMemory? same = e.memoryState(
        algorithm: SrsAlgorithm.fsrs6,
        params: const <double>[],
        reviews: const <SrsFsrsReview>[],
        starting: start,
      );
      expect(same!.stability, closeTo(7, 1e-6));
      expect(same.difficulty, closeTo(4, 1e-6));
    });

    test('memoryStateFromSm2 maps ease/interval to a plausible state', () {
      for (final SrsAlgorithm a in SrsAlgorithm.values) {
        final SrsMemory short = e.memoryStateFromSm2(
          algorithm: a,
          params: const <double>[],
          easeFactor: 2.5,
          intervalDays: 3,
          sm2Retention: 0.9,
        );
        final SrsMemory long = e.memoryStateFromSm2(
          algorithm: a,
          params: const <double>[],
          easeFactor: 2.5,
          intervalDays: 60,
          sm2Retention: 0.9,
        );
        expect(short.stability, greaterThan(0));
        expect(long.stability, greaterThan(short.stability));
        expect(long.difficulty, inInclusiveRange(1, 10));
      }
    });

    test('retrievability decays with elapsed time', () {
      const SrsMemory m = SrsMemory(stability: 10, difficulty: 5);
      double r(double t) => e.retrievability(
        algorithm: SrsAlgorithm.fsrs6,
        params: const <double>[],
        memory: m,
        elapsedDays: t,
      );
      expect(r(0), closeTo(1, 1e-6));
      expect(r(10), closeTo(0.9, 0.02));
      expect(r(30), lessThan(r(10)));
    });

    for (final SrsAlgorithm a in SrsAlgorithm.values) {
      test('computeParameters on synthetic data (${a.wire})', () {
        final NativeSrsOptimizerControl control = NativeSrsOptimizerControl();
        addTearDown(control.dispose);
        final List<double> params = e.computeParameters(
          algorithm: a,
          items: _syntheticItems(cards: 400),
          control: control,
        );
        expect(params, hasLength(a.paramCount));
        expect(params.every((double v) => v.isFinite), isTrue);
        expect(e.validateParams(a, params), isNull);
        final (int done, int total) = control.progress;
        expect(total, greaterThan(0));
        expect(done, lessThanOrEqualTo(total));
        expect(control.cancelled, isFalse);
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('computeParameters is cancellable from another isolate '
          '(${a.wire})', () async {
        final NativeSrsOptimizerControl control = NativeSrsOptimizerControl();
        final Future<List<double>> run = _computeInIsolate(
          libraryPath: libraryPath,
          algorithm: a,
          items: _syntheticItems(cards: 6000, seed: 11),
          cancelAddress: control.cancelAddress,
          progressAddress: control.progressAddress,
        );
        bool finished = false;
        final Future<void> watch = run.then(
          (_) => finished = true,
          onError: (Object _) => finished = true,
        );
        // 等原生侧开始报进度（总数 > 0）再取消。
        final Stopwatch sw = Stopwatch()..start();
        while (!finished && control.progress.$2 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (sw.elapsed > const Duration(minutes: 2)) break;
        }
        expect(finished, isFalse, reason: 'optimizer finished before cancel');
        expect(control.progress.$2, greaterThan(0));
        control.cancel();
        expect(control.cancelled, isTrue);
        await expectLater(
          run,
          throwsA(
            isA<SrsFsrsException>().having(
              (SrsFsrsException x) => x.isCancelled,
              'isCancelled',
              isTrue,
            ),
          ),
        );
        await watch;
        control.dispose();
      }, timeout: const Timeout(Duration(minutes: 5)));
    }

    test('an already-cancelled control throws before running', () {
      final NativeSrsOptimizerControl control = NativeSrsOptimizerControl()
        ..cancel();
      addTearDown(control.dispose);
      expect(
        () => e.computeParameters(
          algorithm: SrsAlgorithm.fsrs6,
          items: _syntheticItems(cards: 10),
          control: control,
        ),
        throwsA(isA<SrsFsrsException>()),
      );
    });

    test('computeParameters with no data reports an error', () {
      expect(
        () => e.computeParameters(
          algorithm: SrsAlgorithm.fsrs7,
          items: const <List<SrsFsrsReview>>[],
        ),
        throwsA(isA<SrsFsrsException>()),
      );
    });

    test('evaluateTimeSeries / evaluate return finite metrics', () {
      final List<List<SrsFsrsReview>> items = _syntheticItems(cards: 300);
      for (final SrsAlgorithm a in SrsAlgorithm.values) {
        final SrsEvaluation tss = e.evaluateTimeSeries(
          algorithm: a,
          items: items,
        );
        expect(tss.logLoss.isFinite, isTrue, reason: '$a');
        expect(tss.logLoss, greaterThan(0));
        expect(tss.rmseBins.isFinite, isTrue);
        final SrsEvaluation inSample = e.evaluate(
          algorithm: a,
          params: const <double>[],
          items: items,
        );
        expect(inSample.logLoss, greaterThan(0));
        expect(inSample.rmseBins.isFinite, isTrue);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('zstdDecompress decodes a frame and rejects garbage', () {
      // python: zstandard.ZstdCompressor(level=3).compress(b'Fushi SRS zstd ' * 20)
      final Uint8List frame = Uint8List.fromList(const <int>[
        0x28, 0xb5, 0x2f, 0xfd, 0x60, 0x2c, 0x00, 0xb5, 0x00, 0x00, 0x78, //
        0x46, 0x75, 0x73, 0x68, 0x69, 0x20, 0x53, 0x52, 0x53, 0x20, 0x7a,
        0x73, 0x74, 0x64, 0x20, 0x01, 0x00, 0x1a, 0xa2, 0xce, 0x3a,
      ]);
      final Uint8List? out = FfiFsrsEngine.zstdDecompress(
        frame,
        library: e.library,
      );
      expect(out, isNotNull);
      expect(String.fromCharCodes(out!), 'Fushi SRS zstd ' * 20);
      expect(
        FfiFsrsEngine.zstdDecompress(
          Uint8List.fromList(const <int>[0x28, 0xb5, 0x2f, 0xfd, 0xff]),
          library: e.library,
        ),
        isNull,
      );
      expect(
        FfiFsrsEngine.zstdDecompress(Uint8List(0), library: e.library),
        isNull,
      );
    });
  });
}
