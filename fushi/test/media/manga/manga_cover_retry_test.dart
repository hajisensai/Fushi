import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show HttpExceptionWithStatus;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_cover_failure.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cover_cache.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/utils/net/transient_fetch_retry.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2450：封面取图退避重试 / 排队超时 / 失败态可点重试。
void main() {
  const String png =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
  final Uint8List pngBytes = base64Decode(png);
  const MihonSourceContext sourceContext = MihonSourceContext(
    extension: MihonExtensionRef(
      packageName: 'org.example.fixture',
      apkPath: 'extensions/org.example.fixture.ext',
    ),
    source: MihonSource(
      extensionPackage: 'org.example.fixture',
      id: '42',
      name: 'Fixture',
      language: 'en',
      baseUrl: 'https://fixture.invalid',
    ),
    preferences: <MihonPreference>[],
  );

  group('retryTransient', () {
    test('按 1s/3s/8s 退避重跑，梯度耗尽后把最后一次错误抛回', () {
      fakeAsync((FakeAsync async) {
        final List<Duration> attemptsAt = <Duration>[];
        Object? failure;
        unawaited(
          retryTransient<void>(() async {
            attemptsAt.add(async.elapsed);
            throw TimeoutException('slow source');
          }).catchError((Object error) {
            failure = error;
          }),
        );
        async.flushMicrotasks();
        expect(attemptsAt, <Duration>[Duration.zero]);
        async.elapse(const Duration(milliseconds: 999));
        expect(attemptsAt, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(
            attemptsAt, <Duration>[Duration.zero, const Duration(seconds: 1)]);
        async.elapse(const Duration(seconds: 3));
        expect(attemptsAt.last, const Duration(seconds: 4));
        async.elapse(const Duration(seconds: 8));
        expect(attemptsAt, hasLength(4));
        expect(attemptsAt.last, const Duration(seconds: 12));
        expect(failure, isA<TimeoutException>());
        // 梯度已尽：再等多久都不会有第 5 次。
        async.elapse(const Duration(minutes: 1));
        expect(attemptsAt, hasLength(4));
      });
    });

    test('4xx 与结构性错误一次即抛，不浪费退避时间', () {
      fakeAsync((FakeAsync async) {
        int attempts = 0;
        Object? failure;
        unawaited(
          retryTransient<void>(() async {
            attempts++;
            throw NetworkImageLoadException(
              statusCode: 404,
              uri: Uri.parse('https://fixture.invalid/cover.jpg'),
            );
          }).catchError((Object error) {
            failure = error;
          }),
        );
        async.flushMicrotasks();
        expect(attempts, 1);
        expect(failure, isA<NetworkImageLoadException>());
        async.elapse(const Duration(seconds: 20));
        expect(attempts, 1);
      });
    });

    test('瞬时错误分型：超时 / socket / 5xx 重试，4xx 不重试', () {
      final Uri uri = Uri.parse('https://fixture.invalid/cover.jpg');
      expect(isTransientNetworkError(TimeoutException('t')), isTrue);
      expect(isTransientNetworkError(const SocketException('down')), isTrue);
      expect(
        isTransientNetworkError(HttpExceptionWithStatus(503, 'x', uri: uri)),
        isTrue,
      );
      expect(
        isTransientNetworkError(HttpExceptionWithStatus(404, 'x', uri: uri)),
        isFalse,
      );
      expect(
        isTransientNetworkError(
          NetworkImageLoadException(statusCode: 502, uri: uri),
        ),
        isTrue,
      );
      expect(isTransientNetworkError(StateError('bad')), isFalse);
    });

    test('调用方退场后不再打下一枪', () {
      fakeAsync((FakeAsync async) {
        int attempts = 0;
        bool wanted = true;
        Object? failure;
        unawaited(
          retryTransient<void>(
            () async {
              attempts++;
              wanted = false;
              throw TimeoutException('slow source');
            },
            stillWanted: () => wanted,
          ).catchError((Object error) {
            failure = error;
          }),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));
        expect(attempts, 1);
        expect(failure, isA<TimeoutException>());
      });
    });
  });

  group('MihonCoverCache 退避重试', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('fushi-cover-retry-');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('第一次超时第二次成功：只按退避表等待一次并落盘', () async {
      final List<Duration> waits = <Duration>[];
      final MihonCoverCache cache = MihonCoverCache(
        root,
        retryWait: (Duration delay) async => waits.add(delay),
      );
      int fetches = 0;
      Future<Uint8List> fetch(bool Function() stillWanted) async {
        fetches++;
        if (fetches == 1) throw TimeoutException('first attempt');
        return pngBytes;
      }

      expect(
        await cache.load(
          extensionPackage: 'org.example.fixture',
          sourceId: '42',
          url: 'https://fixture.invalid/retry.jpg',
          fetch: fetch,
        ),
        pngBytes,
      );
      expect(fetches, 2);
      expect(waits, <Duration>[kCoverFetchRetryBackoff.first]);

      // 重试成功的字节照常进磁盘：新实例不再联网。
      expect(
        await MihonCoverCache(root).load(
          extensionPackage: 'org.example.fixture',
          sourceId: '42',
          url: 'https://fixture.invalid/retry.jpg',
          fetch: fetch,
        ),
        pngBytes,
      );
      expect(fetches, 2);
    });

    test('4xx / Cloudflare / 排队超时不自动重试', () async {
      final List<Duration> waits = <Duration>[];
      final MihonCoverCache cache = MihonCoverCache(
        root,
        retryWait: (Duration delay) async => waits.add(delay),
      );
      final List<Exception> errors = <Exception>[
        const MihonRuntimeException('IMAGE_HTTP_404', 'not found'),
        MihonCloudflareChallengeException(Uri.parse('https://fixture.invalid')),
        const MihonRuntimeException(kMihonImageQueueTimeoutCode, 'queue'),
        const MihonRuntimeException('IMAGE_LOAD_CANCELLED', 'gone'),
      ];
      for (final Exception error in errors) {
        int fetches = 0;
        await expectLater(
          cache.load(
            extensionPackage: 'org.example.fixture',
            sourceId: '42',
            url: 'https://fixture.invalid/${error.hashCode}.jpg',
            fetch: (bool Function() stillWanted) async {
              fetches++;
              throw error;
            },
          ),
          throwsA(same(error)),
        );
        expect(fetches, 1, reason: '$error 不该重试');
      }
      expect(waits, isEmpty);
    });

    test('Mihon 错误分型：5xx 与桥接层包装的 socket/超时属瞬时', () {
      expect(
        isTransientMihonImageError(
          const MihonRuntimeException('IMAGE_HTTP_503', 'busy'),
        ),
        isTrue,
      );
      expect(
        isTransientMihonImageError(
          MihonRuntimeException(
            'BRIDGE_TIMEOUT',
            'timed out',
            cause: TimeoutException('t'),
          ),
        ),
        isTrue,
      );
      expect(
        isTransientMihonImageError(
          const MihonRuntimeException(
            'BRIDGE_IO',
            'failed',
            cause: SocketException('reset'),
          ),
        ),
        isTrue,
      );
      expect(
        isTransientMihonImageError(
          const MihonRuntimeException('IMAGE_HTTP_403', 'forbidden'),
        ),
        isFalse,
      );
      expect(
        isTransientMihonImageError(
          const MihonRuntimeException('IMAGE_TOO_LARGE', 'big'),
        ),
        isFalse,
      );
    });

    test('maxAge 可变即时生效：过期封面重新联网，未过期命中磁盘', () async {
      final MihonCoverCache cache = MihonCoverCache(root);
      int fetches = 0;
      Future<Uint8List> load() => cache.load(
            extensionPackage: 'org.example.fixture',
            sourceId: '42',
            url: 'https://fixture.invalid/aged.jpg',
            fetch: (bool Function() stillWanted) async {
              fetches++;
              return pngBytes;
            },
          );
      await load();
      expect(fetches, 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      cache.maxAge = const Duration(milliseconds: 1);
      await load();
      expect(fetches, 2, reason: '过期条目必须删掉重取');
      cache.maxAge = const Duration(days: 1);
      await load();
      expect(fetches, 2, reason: '未过期条目命中磁盘');
    });

    test('MihonManager 把偏好穿到封面缓存的 maxAge', () async {
      final FushiDatabase database =
          FushiDatabase.forTesting(NativeDatabase.memory());
      final MihonManager manager = MihonManager(
        database: database,
        rootDirectory: root,
        runtime: _CoverRuntime(),
        coverCacheMaxAge: const Duration(days: 7),
      );
      addTearDown(() async {
        manager.dispose();
        await database.close();
      });
      expect(manager.coverCache.maxAge, const Duration(days: 7));
      expect(
        MihonCoverCache(root).maxAge,
        const Duration(days: kMangaCoverCacheDefaultMaxAgeDays),
      );
    });
  });

  group('MihonSourceImageLoadQueue 排队超时', () {
    test('排到上限还没轮上的封面以 IMAGE_QUEUE_TIMEOUT 失败且不漏名额', () {
      fakeAsync((FakeAsync async) {
        final MihonSourceImageLoadQueue queue = MihonSourceImageLoadQueue(
          maxConcurrent: 1,
          waitTimeout: const Duration(seconds: 30),
        );
        final Completer<void> gate = Completer<void>();
        unawaited(queue.run<void>(() => gate.future));
        Object? failure;
        bool secondRan = false;
        unawaited(
          queue.run<void>(() async {
            secondRan = true;
          }).catchError((Object error) {
            failure = error;
          }),
        );
        async.flushMicrotasks();
        expect(queue.active, 1);
        expect(queue.pending, 1);

        async.elapse(const Duration(seconds: 29));
        expect(failure, isNull);
        async.elapse(const Duration(seconds: 1));
        expect(
          failure,
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            kMihonImageQueueTimeoutCode,
          ),
        );
        expect(secondRan, isFalse);
        expect(queue.pending, 0);

        // 第一个任务结束后名额必须回到池里，后来者立刻能跑。
        gate.complete();
        async.flushMicrotasks();
        expect(queue.active, 0);
        bool thirdRan = false;
        unawaited(
          queue.run<void>(() async {
            thirdRan = true;
          }),
        );
        async.flushMicrotasks();
        expect(thirdRan, isTrue);
        expect(queue.active, 0);
      });
    });

    test('超时前轮到名额的等待者照常执行，定时器不会误报', () {
      fakeAsync((FakeAsync async) {
        final MihonSourceImageLoadQueue queue = MihonSourceImageLoadQueue(
          maxConcurrent: 1,
          waitTimeout: const Duration(seconds: 30),
        );
        final Completer<void> first = Completer<void>();
        final Completer<void> second = Completer<void>();
        unawaited(queue.run<void>(() => first.future));
        Object? failure;
        unawaited(
          queue.run<void>(() => second.future).catchError((Object error) {
            failure = error;
          }),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        first.complete();
        async.flushMicrotasks();
        expect(queue.active, 1);
        expect(queue.pending, 0);
        async.elapse(const Duration(seconds: 60));
        expect(failure, isNull);
        second.complete();
        async.flushMicrotasks();
        expect(queue.active, 0);
      });
    });
  });

  group('MihonSourceImage 失败态', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('fushi-cover-widget-');
    });
    tearDown(() async {
      PaintingBinding.instance.imageCache.clear();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<void> pumpUntil(
      WidgetTester tester,
      bool Function() condition,
    ) async {
      for (int i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      expect(condition(), isTrue, reason: '等待条件在 2s 内没有满足');
    }

    Widget harness(_CoverRuntime runtime, MihonCoverCache cache) => MaterialApp(
          home: Center(
            child: SizedBox(
              width: 100,
              height: 140,
              child: MihonSourceImage(
                runtime: runtime,
                cache: cache,
                context: sourceContext,
                url: 'https://fixture.invalid/cover.jpg',
              ),
            ),
          ),
        );

    testWidgets('假 runtime 第一次超时第二次成功：封面最终渲染且只按退避表等待',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        final List<Duration> waits = <Duration>[];
        final MihonCoverCache cache = MihonCoverCache(
          root,
          retryWait: (Duration delay) async => waits.add(delay),
        );
        final _CoverRuntime runtime = _CoverRuntime()
          ..failures.add(TimeoutException('first attempt'))
          ..bytes = pngBytes;
        await tester.pumpWidget(harness(runtime, cache));
        await pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
        final Image image = tester.widget<Image>(find.byType(Image));
        expect((image.image as MemoryImage).bytes, pngBytes);
        expect(runtime.calls, 2);
        expect(waits, <Duration>[kCoverFetchRetryBackoff.first]);
        expect(find.byKey(kMangaCoverRetryKey), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('非 Cloudflare 失败态有重试按钮，点击后重新发请求', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final MihonCoverCache cache =
            MihonCoverCache(root, retryBackoff: const <Duration>[]);
        final _CoverRuntime runtime = _CoverRuntime()
          ..failures.add(const MihonRuntimeException('IMAGE_HTTP_404', 'no'))
          ..failures.add(const MihonRuntimeException('IMAGE_HTTP_404', 'no'));
        await tester.pumpWidget(harness(runtime, cache));
        await pumpUntil(
          tester,
          () => find.byKey(kMangaCoverRetryKey).evaluate().isNotEmpty,
        );
        expect(runtime.calls, 1);
        expect(find.byType(MihonCloudflareAction), findsNothing);

        await tester.tap(find.byKey(kMangaCoverRetryKey));
        await tester.pump();
        await pumpUntil(tester, () => runtime.calls == 2);
        // 第二次仍失败：失败态回来，入口还在。
        await pumpUntil(
          tester,
          () => find.byKey(kMangaCoverRetryKey).evaluate().isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('Cloudflare 挑战走验证按钮而不是裸重试', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final MihonCoverCache cache =
            MihonCoverCache(root, retryBackoff: const <Duration>[]);
        final _CoverRuntime runtime = _CoverRuntime()
          ..failures.add(
            MihonCloudflareChallengeException(
              Uri.parse('https://fixture.invalid/'),
            ),
          );
        await tester.pumpWidget(harness(runtime, cache));
        await pumpUntil(
          tester,
          () => find.byType(MihonCloudflareAction).evaluate().isNotEmpty,
        );
        expect(find.byKey(kMangaCoverRetryKey), findsNothing);
        expect(runtime.calls, 1);
        await tester.pumpWidget(const SizedBox());
      });
    });
  });
}

class _CoverRuntime extends Fake
    implements MihonRuntime, ChallengeMihonRuntime {
  final List<Exception> failures = <Exception>[];
  Uint8List bytes = Uint8List(0);
  int calls = 0;

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    calls++;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return bytes;
  }

  @override
  Future<void> solveCloudflare(Uri uri, {String? userAgent}) async {}

  @override
  Future<void> dispose() async {}
}
