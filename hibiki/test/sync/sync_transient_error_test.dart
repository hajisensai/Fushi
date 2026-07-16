import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_transient_error.dart';

void main() {
  group('isTransientSyncError (BUG-864)', () {
    test('true for concrete dart:io transient exception types', () {
      expect(isTransientSyncError(const SocketException('boom')), isTrue);
      expect(isTransientSyncError(TimeoutException('slow')), isTrue);
      expect(isTransientSyncError(const HttpException('reset')), isTrue);
    });

    test('true for the reported Windows semaphore-timeout SocketException', () {
      // The exact shape from the log: ClientException wrapping a SocketException
      // 信号灯超时 / errno 121 against www.googleapis.com.
      const String reported = 'ClientException with SocketException: 信号灯超时时间已到 '
          '(OS Error: 信号灯超时时间已到, errno = 121), '
          'address = www.googleapis.com, port = 2011';
      expect(isTransientSyncError(reported), isTrue);
    });

    test('true for the network/timeout substring taxonomy', () {
      for (final String s in <String>[
        'SocketException: Connection reset by peer',
        'Connection closed before full header was received',
        'Connection refused',
        'Failed host lookup: www.googleapis.com',
        'Operation timed out',
        'errno = 110',
        'HandshakeException: ...',
        'Network is unreachable',
      ]) {
        expect(isTransientSyncError(s), isTrue, reason: s);
      }
    });

    test('false for permanent auth / permission / not-found errors', () {
      expect(isTransientSyncError('insufficient_scope: re-consent required'),
          isFalse);
      expect(isTransientSyncError('401 unauthorized'), isFalse);
      expect(isTransientSyncError('invalid_grant'), isFalse);
      expect(isTransientSyncError('403 insufficientPermissions'), isFalse);
      expect(isTransientSyncError('File not found'), isFalse);
      expect(isTransientSyncError('Some unrelated failure'), isFalse);
    });
  });

  group('retryTransientSync (BUG-864)', () {
    test('retries a transient failure then succeeds, backing off each attempt',
        () async {
      int calls = 0;
      final List<Duration> slept = <Duration>[];
      final String result = await retryTransientSync<String>(
        () async {
          calls++;
          if (calls < 3) throw const SocketException('blip');
          return 'ok';
        },
        backoff: const Duration(milliseconds: 10),
        sleep: (Duration d) async => slept.add(d),
      );
      expect(result, 'ok');
      expect(calls, 3, reason: '两次瞬时失败 + 第三次成功');
      // 线性退避：backoff*1, backoff*2。
      expect(slept, <Duration>[
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 20),
      ]);
    });

    test('gives up after maxAttempts and rethrows the last transient error',
        () async {
      int calls = 0;
      await expectLater(
        retryTransientSync<void>(
          () async {
            calls++;
            throw const SocketException('always');
          },
          maxAttempts: 3,
          sleep: (Duration d) async {},
        ),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 3, reason: '穷尽 maxAttempts 次');
    });

    test('does NOT retry a non-transient error — rethrows on first attempt',
        () async {
      int calls = 0;
      await expectLater(
        retryTransientSync<void>(
          () async {
            calls++;
            throw StateError('permanent');
          },
          sleep: (Duration d) async {},
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1, reason: '永久错误立即抛出，不浪费重试');
    });

    test('a first-attempt success never sleeps (common path zero overhead)',
        () async {
      int calls = 0;
      bool slept = false;
      final int result = await retryTransientSync<int>(
        () async {
          calls++;
          return 42;
        },
        sleep: (Duration d) async => slept = true,
      );
      expect(result, 42);
      expect(calls, 1);
      expect(slept, isFalse);
    });
  });
}
