import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

void main() {
  late Directory root;
  late TtsAudioCache cache;
  late FakeTtsProvider provider;
  final List<TtsSynthesisScheduler> schedulers = <TtsSynthesisScheduler>[];

  List<String> texts(int n) => <String>[for (int i = 0; i < n; i++) 't$i'];

  TtsSynthesisScheduler make({
    int count = 10,
    int lookahead = 3,
    int? concurrency,
  }) {
    final TtsSynthesisScheduler s = TtsSynthesisScheduler(
      provider: provider,
      cache: cache,
      texts: texts(count),
      audioIdentity: const <String, Object?>{'provider': 'fake', 'revision': 0},
      lookahead: lookahead,
      concurrency: concurrency,
    );
    schedulers.add(s);
    return s;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tts_sched_test_');
    cache = TtsAudioCache(root: root);
    provider = FakeTtsProvider();
  });

  tearDown(() async {
    provider.gateAll = false;
    for (final Completer<void> g in provider.gates.values) {
      if (!g.isCompleted) g.complete();
    }
    for (final TtsSynthesisScheduler s in schedulers) {
      await s.dispose();
    }
    schedulers.clear();
    await settle(50);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('ensure returns published audio and pins it', () async {
    final TtsSynthesisScheduler s = make(lookahead: 0);
    final TtsCachedAudio audio = await s.ensure(0);
    expect(audio.durationMs, 100);
    expect(audio.path, s.audioPathOf(0));
    expect(File(audio.path).existsSync(), isTrue);
    expect(s.readyAudio(0), same(audio));
    expect(cache.isPinned(s.keyOf(0)), isTrue);
    expect(await s.ensure(0), same(audio));
    expect(provider.calls, <String>['t0']);
  });

  test(
    'setCursor prefetches cursor..cursor+lookahead within concurrency',
    () async {
      provider = FakeTtsProvider(maxConcurrency: 2)..gateAll = true;
      final TtsSynthesisScheduler s = make(lookahead: 3);
      final List<int> ready = <int>[];
      s.events.listen((TtsSegmentEvent e) {
        if (e is TtsSegmentReady) ready.add(e.index);
      });
      s.setCursor(2);
      await waitFor(() => provider.calls.length == 2);
      await settle();
      // 两路并发都要先异步查缓存，到达引擎的先后不确定。
      expect(provider.calls.toSet(), <String>{'t2', 't3'});
      expect(s.isInFlight(2) && s.isInFlight(3), isTrue);
      for (final String t in <String>['t2', 't3', 't4', 't5', 't6']) {
        provider.release(t);
      }
      await waitFor(() => ready.length == 4);
      await settle();
      expect(provider.calls.toSet(), <String>{'t2', 't3', 't4', 't5'});
      expect(provider.maxActive, 2);
      expect(ready.toSet(), <int>{2, 3, 4, 5});
    },
  );

  test('explicit concurrency overrides provider capability', () async {
    provider = FakeTtsProvider(maxConcurrency: 4)..gateAll = true;
    final TtsSynthesisScheduler s = make(lookahead: 5, concurrency: 1);
    s.setCursor(0);
    await waitFor(() => provider.calls.isNotEmpty);
    await settle();
    expect(provider.calls, <String>['t0']);
  });

  test('demanded index is prioritized over prefetch', () async {
    provider.gateAll = true;
    final TtsSynthesisScheduler s = make(lookahead: 3);
    s.setCursor(0);
    await waitFor(() => provider.calls.length == 1);
    final Future<TtsCachedAudio> demanded = s.ensure(3);
    provider.release('t0');
    await waitFor(() => provider.calls.length == 2);
    expect(provider.calls, <String>['t0', 't3']);
    provider.release('t3');
    expect((await demanded).key, s.keyOf(3));
    await waitFor(() => provider.calls.length == 3);
    expect(provider.calls[2], 't1');
  });

  test('failure halts, keeps ensure pending; resume completes it', () async {
    provider.failing.add('t0');
    final TtsSynthesisScheduler s = make(lookahead: 3);
    final List<TtsSegmentEvent> events = <TtsSegmentEvent>[];
    s.events.listen(events.add);
    bool completed = false;
    final Future<TtsCachedAudio> pending = s.ensure(0)
      ..then((_) => completed = true, onError: (Object _) => completed = true);
    await waitFor(() => events.isNotEmpty);
    await settle();
    expect(events.single, isA<TtsSegmentFailed>());
    final TtsSegmentFailed failed = events.single as TtsSegmentFailed;
    expect(failed.index, 0);
    expect(failed.failure.code, TtsFailureCode.serverError);
    expect(s.failure?.code, TtsFailureCode.serverError);
    expect(s.failedIndex, 0);
    expect(provider.calls, <String>['t0']);
    expect(completed, isFalse);

    // 失败状态下 setCursor / ensure 都不发起新合成。
    s.setCursor(1);
    unawaited(s.ensure(2).then((_) {}, onError: (Object _) {}));
    await settle();
    expect(provider.calls, <String>['t0']);

    provider.failing.clear();
    s.setCursor(0);
    s.resume();
    expect(s.failure, isNull);
    expect(s.failedIndex, isNull);
    final TtsCachedAudio audio = await pending;
    expect(audio.key, s.keyOf(0));
    await waitFor(
      () => events.whereType<TtsSegmentReady>().any(
        (TtsSegmentReady e) => e.index == 0,
      ),
    );
  });

  test('non-TtsFailure errors are wrapped as badResponse', () async {
    final TtsSynthesisScheduler s = TtsSynthesisScheduler(
      provider: _ThrowingProvider(),
      cache: cache,
      texts: texts(2),
      audioIdentity: const <String, Object?>{},
      lookahead: 0,
    );
    schedulers.add(s);
    final Future<TtsSegmentEvent> first = s.events.first;
    unawaited(s.ensure(0).then((_) {}, onError: (Object _) {}));
    final TtsSegmentEvent e = await first;
    expect(e, isA<TtsSegmentFailed>());
    expect((e as TtsSegmentFailed).failure.code, TtsFailureCode.badResponse);
  });

  test('jumping the cursor cancels out-of-window in-flight work', () async {
    provider = FakeTtsProvider(maxConcurrency: 2)..gateAll = true;
    final TtsSynthesisScheduler s = make(count: 20, lookahead: 1);
    s.setCursor(0);
    await waitFor(() => provider.calls.length == 2);
    expect(provider.calls.toSet(), <String>{'t0', 't1'});
    s.setCursor(10);
    await waitFor(() => provider.calls.length == 4);
    expect(provider.cancelled.toSet(), <String>{'t0', 't1'});
    expect(provider.calls.sublist(2).toSet(), <String>{'t10', 't11'});
    expect(s.failure, isNull);
    expect(s.isInFlight(0), isFalse);
  });

  test('in-flight work inside the new window is kept', () async {
    provider = FakeTtsProvider(maxConcurrency: 2)..gateAll = true;
    final TtsSynthesisScheduler s = make(count: 20, lookahead: 3);
    s.setCursor(0);
    await waitFor(() => provider.calls.length == 2);
    s.setCursor(1);
    await settle();
    expect(provider.cancelled, isEmpty);
    expect(s.isInFlight(0) && s.isInFlight(1), isTrue);
  });

  test(
    'stale demand outside the new window is cancelled and its waiter ends '
    'with cancelled (not left pending until dispose)',
    () async {
      provider.gateAll = true;
      final TtsSynthesisScheduler s = make(count: 20, lookahead: 1);
      final Future<TtsCachedAudio> demanded = s.ensure(0);
      await waitFor(() => provider.calls.length == 1);
      final Future<void> expectation = expectLater(
        demanded,
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.code,
            'code',
            TtsFailureCode.cancelled,
          ),
        ),
      );
      // ensure(0) 后立刻跳到远处：_demanded 被裁掉、在途 t0 被取消，等待者以「已取消」
      // 结束——不是挂到 dispose。
      s.setCursor(15);
      await expectation;
      await waitFor(() => provider.cancelled.contains('t0'));
      expect(s.failure, isNull);
    },
  );

  test('a waiter inside the new window keeps waiting across setCursor', () async {
    provider.gateAll = true;
    final TtsSynthesisScheduler s = make(count: 20, lookahead: 3);
    final Future<TtsCachedAudio> demanded = s.ensure(2);
    await waitFor(() => provider.calls.contains('t2'));
    s.setCursor(1);
    bool done = false;
    unawaited(demanded.then((_) => done = true, onError: (Object _) {}));
    await settle();
    expect(done, isFalse, reason: '窗口内的请求不能被误取消');
    provider.release('t2');
    final TtsCachedAudio audio = await demanded;
    expect(audio.path, s.audioPathOf(2));
  });

  test('re-requesting a cancelled sentence registers a fresh waiter', () async {
    final TtsSynthesisScheduler s = make(count: 20, lookahead: 1);
    provider.gateAll = true;
    final Future<TtsCachedAudio> stale = s.ensure(0);
    unawaited(stale.then((_) {}, onError: (Object _) {}));
    await waitFor(() => provider.calls.length == 1);
    s.setCursor(15);
    await waitFor(() => provider.cancelled.contains('t0'));
    // gateAll 只管「新登记的门」：第一次合成已经给 t0 建了门，不放行它，重新合成的
    // t0 会一直等在这扇旧门上。
    provider.gateAll = false;
    provider.release('t0');
    s.setCursor(0);
    final TtsCachedAudio audio = await s.ensure(0);
    expect(audio.path, s.audioPathOf(0));
  });

  test('dispose completes waiters with cancelled', () async {
    provider.gateAll = true;
    final TtsSynthesisScheduler s = make(lookahead: 0);
    final Future<TtsCachedAudio> pending = s.ensure(0);
    await waitFor(() => provider.calls.length == 1);
    final Future<void> expectation = expectLater(
      pending,
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.cancelled,
        ),
      ),
    );
    await s.dispose();
    await expectation;
    await expectLater(
      s.ensure(1),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.cancelled,
        ),
      ),
    );
    await waitFor(() => provider.cancelled.contains('t0'));
  });

  test(
    'dispose waits for a synthesis that cannot abort to finish writing',
    () async {
      // 系统 TTS 这类整句合成停不下来：取消后它照样写完输出。dispose 返回前必须等它
      // 收尾，否则调用方紧接着释放引擎 / 删缓存目录时它还在写盘。
      final _UnabortableProvider slow = _UnabortableProvider();
      final TtsSynthesisScheduler s = TtsSynthesisScheduler(
        provider: slow,
        cache: cache,
        texts: texts(1),
        audioIdentity: const <String, Object?>{},
        lookahead: 0,
      );
      schedulers.add(s);
      unawaited(s.ensure(0).then((_) {}, onError: (Object _) {}));
      await slow.started.future;
      bool disposed = false;
      final Future<void> disposing = s.dispose().then((_) => disposed = true);
      await settle(30);
      expect(disposed, isFalse, reason: 'synthesis still running');
      slow.finish.complete();
      await disposing;
      expect(slow.wrote, isTrue);
      // 收尾（发布或清掉 .part）已全部落定：目录里不再有半成品。
      expect(
        root.listSync().whereType<File>().where(
          (File f) => f.path.endsWith('.part'),
        ),
        isEmpty,
      );
    },
  );

  test('dispose releases pins', () async {
    final TtsSynthesisScheduler s = make(lookahead: 0);
    await s.ensure(0);
    expect(cache.isPinned(s.keyOf(0)), isTrue);
    await s.dispose();
    expect(cache.isPinned(s.keyOf(0)), isFalse);
  });

  test('cursor moving far away releases pins of distant segments', () async {
    final TtsSynthesisScheduler s = TtsSynthesisScheduler(
      provider: provider,
      cache: cache,
      texts: texts(30),
      audioIdentity: const <String, Object?>{},
      lookahead: 0,
      keepPinned: 2,
    );
    schedulers.add(s);
    await s.ensure(0);
    expect(cache.isPinned(s.keyOf(0)), isTrue);
    s.setCursor(20);
    expect(cache.isPinned(s.keyOf(0)), isFalse);
    expect(s.readyAudio(0), isNull);
  });
}

class _ThrowingProvider extends FakeTtsProvider {
  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async => throw StateError('boom');
}

/// 不理会取消的引擎：开始后一直等 [finish]，然后照常写完输出。
class _UnabortableProvider extends TtsProvider {
  final Completer<void> started = Completer<void>();
  final Completer<void> finish = Completer<void>();
  bool wrote = false;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    maxConcurrency: 1,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    started.complete();
    await finish.future;
    await File(outputPath).writeAsBytes(buildWav());
    wrote = true;
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}
