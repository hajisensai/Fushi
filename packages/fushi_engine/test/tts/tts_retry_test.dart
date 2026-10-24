import 'dart:math';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

Matcher _failsWith(TtsFailureCode code) =>
    throwsA(isA<TtsFailure>().having((TtsFailure f) => f.code, 'code', code));

void main() {
  const TtsRetryPolicy fast = TtsRetryPolicy(baseDelay: Duration.zero);

  group('TtsFailure.isTransient', () {
    test('network-ish codes are transient, the rest are not', () {
      for (final TtsFailureCode code in <TtsFailureCode>[
        TtsFailureCode.network,
        TtsFailureCode.timeout,
        TtsFailureCode.rateLimited,
        TtsFailureCode.serverError,
        TtsFailureCode.busy,
      ]) {
        expect(TtsFailure(code).isTransient, isTrue, reason: code.name);
      }
      for (final TtsFailureCode code in <TtsFailureCode>[
        TtsFailureCode.unauthorized,
        TtsFailureCode.rejected,
        TtsFailureCode.unsupported,
        TtsFailureCode.notConfigured,
        TtsFailureCode.badResponse,
        TtsFailureCode.cancelled,
      ]) {
        expect(TtsFailure(code).isTransient, isFalse, reason: code.name);
      }
    });

    test('an explicit flag overrides the code (empty audio)', () {
      const TtsFailure empty = TtsFailure.withRetry(
        TtsFailureCode.badResponse,
        detail: 'empty',
        transient: true,
      );
      expect(empty.isTransient, isTrue);
    });

    test('HTTP status mapping carries Retry-After for 429 / 5xx', () {
      final TtsFailure limited = ttsFailureForStatus(
        429,
        retryAfter: const Duration(seconds: 2),
      );
      expect(limited.code, TtsFailureCode.rateLimited);
      expect(limited.retryAfter, const Duration(seconds: 2));
      expect(ttsFailureForStatus(503).isTransient, isTrue);
      expect(ttsFailureForStatus(400).isTransient, isFalse);
      expect(ttsFailureForStatus(401).isTransient, isFalse);
    });
  });

  group('ttsParseRetryAfter', () {
    test('seconds and HTTP dates', () {
      expect(ttsParseRetryAfter('5'), const Duration(seconds: 5));
      expect(ttsParseRetryAfter(' 0 '), Duration.zero);
      final DateTime now = DateTime.utc(2026, 10, 24, 12);
      expect(
        ttsParseRetryAfter('Sat, 24 Oct 2026 12:00:07 GMT', now: now),
        const Duration(seconds: 7),
      );
      expect(ttsParseRetryAfter(null), isNull);
      expect(ttsParseRetryAfter('soon'), isNull);
      expect(ttsParseRetryAfter('-3'), isNull);
    });
  });

  group('TtsRetryPolicy.delayBefore', () {
    test('exponential with equal jitter, capped', () {
      const TtsRetryPolicy policy = TtsRetryPolicy(
        baseDelay: Duration(milliseconds: 100),
        maxDelay: Duration(milliseconds: 300),
        maxRetries: 5,
      );
      final Random rng = Random(1);
      const TtsFailure f = TtsFailure(TtsFailureCode.network);
      for (int i = 0; i < 50; i++) {
        final Duration d1 = policy.delayBefore(1, f, rng)!;
        final Duration d2 = policy.delayBefore(2, f, rng)!;
        final Duration d4 = policy.delayBefore(4, f, rng)!;
        expect(d1.inMicroseconds, inInclusiveRange(50000, 100000));
        expect(d2.inMicroseconds, inInclusiveRange(100000, 200000));
        expect(d4.inMicroseconds, inInclusiveRange(150000, 300000));
      }
      expect(policy.delayBefore(6, f, rng), isNull);
    });

    test('honors Retry-After, gives up when it is too long', () {
      const TtsRetryPolicy policy = TtsRetryPolicy();
      final Random rng = Random(1);
      expect(
        policy.delayBefore(
          1,
          const TtsFailure.withRetry(
            TtsFailureCode.rateLimited,
            retryAfter: Duration(seconds: 3),
          ),
          rng,
        ),
        const Duration(seconds: 3),
      );
      expect(
        policy.delayBefore(
          1,
          const TtsFailure.withRetry(
            TtsFailureCode.rateLimited,
            retryAfter: Duration(minutes: 5),
          ),
          rng,
        ),
        isNull,
      );
    });
  });

  group('ttsWithRetry', () {
    test('retries transient failures then succeeds', () async {
      int attempts = 0;
      final List<int> retries = <int>[];
      final String result = await ttsWithRetry<String>(
        () async {
          attempts++;
          if (attempts < 3) throw const TtsFailure(TtsFailureCode.timeout);
          return 'ok';
        },
        cancel: TtsCancelToken(),
        policy: fast,
        onRetry: (int retry, TtsFailure _, Duration __) => retries.add(retry),
      );
      expect(result, 'ok');
      expect(attempts, 3);
      expect(retries, <int>[1, 2]);
    });

    test('gives up after maxRetries with the last real failure', () async {
      int attempts = 0;
      await expectLater(
        ttsWithRetry<void>(
          () async {
            attempts++;
            throw TtsFailure(TtsFailureCode.serverError, 'HTTP 50$attempts');
          },
          cancel: TtsCancelToken(),
          policy: fast,
        ),
        throwsA(
          isA<TtsFailure>().having(
            (TtsFailure f) => f.detail,
            'detail',
            'HTTP 504',
          ),
        ),
      );
      expect(attempts, 4);
    });

    test('does not retry auth / rejected / unsupported', () async {
      for (final TtsFailureCode code in <TtsFailureCode>[
        TtsFailureCode.unauthorized,
        TtsFailureCode.rejected,
        TtsFailureCode.unsupported,
      ]) {
        int attempts = 0;
        await expectLater(
          ttsWithRetry<void>(
            () async {
              attempts++;
              throw TtsFailure(code);
            },
            cancel: TtsCancelToken(),
            policy: fast,
          ),
          _failsWith(code),
        );
        expect(attempts, 1, reason: code.name);
      }
    });

    test('non-TtsFailure errors pass through untouched', () async {
      int attempts = 0;
      await expectLater(
        ttsWithRetry<void>(
          () async {
            attempts++;
            throw StateError('boom');
          },
          cancel: TtsCancelToken(),
          policy: fast,
        ),
        throwsStateError,
      );
      expect(attempts, 1);
    });

    test('cancel interrupts the backoff wait immediately', () async {
      final TtsCancelToken cancel = TtsCancelToken();
      int attempts = 0;
      final Stopwatch sw = Stopwatch()..start();
      final Future<void> run = ttsWithRetry<void>(
        () async {
          attempts++;
          throw const TtsFailure(TtsFailureCode.network);
        },
        cancel: cancel,
        policy: const TtsRetryPolicy(
          baseDelay: Duration(seconds: 30),
          maxDelay: Duration(seconds: 30),
        ),
      );
      final Future<void> expectation = expectLater(
        run,
        _failsWith(TtsFailureCode.cancelled),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.cancel();
      await expectation;
      expect(attempts, 1);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a cancelled attempt is reported as cancelled, not retried', () async {
      int attempts = 0;
      await expectLater(
        ttsWithRetry<void>(
          () async {
            attempts++;
            throw const TtsFailure(TtsFailureCode.cancelled);
          },
          cancel: TtsCancelToken(),
          policy: fast,
        ),
        _failsWith(TtsFailureCode.cancelled),
      );
      expect(attempts, 1);
    });
  });
}
