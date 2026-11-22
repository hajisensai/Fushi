import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('video_source_identity_');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'identical content at different names has the same full-file identity',
    () async {
      final List<int> bytes = List<int>.generate(400000, (int i) => i % 251);
      final File first = await File(
        '${directory.path}/first.mkv',
      ).writeAsBytes(bytes);
      final File second = await File(
        '${directory.path}/second.mkv',
      ).writeAsBytes(bytes);
      final VideoSourceFingerprint hashes = VideoSourceFingerprint();
      final String expected = sha256.convert(bytes).toString();
      expect(await hashes.fingerprint(first.path), expected);
      expect(await hashes.matches(second.path, expected), isTrue);
    },
  );

  test(
    'same name and size with a changed middle cannot match a cached card',
    () async {
      final List<int> bytes = List<int>.filled(400000, 1);
      final File file = await File(
        '${directory.path}/episode.mkv',
      ).writeAsBytes(bytes);
      final VideoSourceFingerprint hashes = VideoSourceFingerprint();
      final String original = await hashes.fingerprint(file.path);
      bytes[200000] = 2;
      await file.writeAsBytes(bytes);
      await file.setLastModified(
        DateTime.now().add(const Duration(seconds: 2)),
      );
      expect(await hashes.matches(file.path, original), isFalse);
      expect(
        await hashes.fingerprint(file.path),
        sha256.convert(bytes).toString(),
      );
    },
  );

  group('BUG-4783：同一文件并发请求只整文件算一遍', () {
    // 真 stat 走 IO 线程，完成时机不受事件循环控制，pumpEventQueue 等不到它（本机
    // Windows 上实测过：重算那次还卡在 stat，在途断言先跑了）。这里把 stat 换成立即
    // 可得的同一个 FileStat，各调用推进到哪一步只由微任务 / 事件队列决定，可确定地等。
    Future<void> withInstantStat(
      File file,
      Future<void> Function() body,
    ) async {
      final FileStat real = await file.stat();
      await IOOverrides.runZoned<Future<void>>(
        body,
        stat: (String _) => Future<FileStat>.value(real),
      );
    }

    test('同状态的并发调用共用一次计算，算完后命中缓存', () async {
      final File file = await File(
        '${directory.path}/big.mkv',
      ).writeAsBytes(List<int>.filled(1024, 7));
      await withInstantStat(file, () async {
        final Completer<String> gate = Completer<String>();
        final List<String> computed = <String>[];
        final VideoSourceFingerprint hashes = VideoSourceFingerprint(
          compute:
              (
                String absolutePath,
                FileStat stat,
                VideoFingerprintCancellation cancel,
              ) {
                computed.add(absolutePath);
                return gate.future;
              },
        );
        final Future<String> first = hashes.fingerprint(file.path);
        final Future<String> second = hashes.fingerprint(file.path);
        final Future<bool> third = hashes.matches(file.path, 'a' * 64);
        // 让三个调用都走完 stat、到达在途表再放行计算。
        await pumpEventQueue();
        expect(computed, hasLength(1));
        gate.complete('a' * 64);
        expect(await first, 'a' * 64);
        expect(await second, 'a' * 64);
        expect(await third, isTrue);
        expect(await hashes.fingerprint(file.path), 'a' * 64);
        expect(computed, hasLength(1));
      });
    });

    test('在途那次失败：等它的调用都收到错误，之后重新计算', () async {
      final File file = await File(
        '${directory.path}/flaky.mkv',
      ).writeAsBytes(List<int>.filled(1024, 3));
      await withInstantStat(file, () async {
        final List<Completer<String>> runs = <Completer<String>>[];
        final VideoSourceFingerprint hashes = VideoSourceFingerprint(
          compute:
              (
                String absolutePath,
                FileStat stat,
                VideoFingerprintCancellation cancel,
              ) {
                final Completer<String> run = Completer<String>();
                runs.add(run);
                return run.future;
              },
        );
        final Future<String> first = hashes.fingerprint(file.path);
        final Future<String> second = hashes.fingerprint(file.path);
        await pumpEventQueue();
        expect(runs, hasLength(1));
        final Future<void> firstFails = expectLater(
          first,
          throwsA(isA<FileSystemException>()),
        );
        final Future<void> secondFails = expectLater(
          second,
          throwsA(isA<FileSystemException>()),
        );
        runs.single.completeError(
          const FileSystemException('Video changed while calculating identity'),
        );
        await firstFails;
        await secondFails;
        final Future<String> retry = hashes.fingerprint(file.path);
        await pumpEventQueue();
        expect(runs, hasLength(2), reason: '失败不进缓存，也不留在途条目');
        runs.last.complete('b' * 64);
        expect(await retry, 'b' * 64);
      });
    });
  });

  group('拍板台 host-stop-fingerprint-cancel：可取消的等待方', () {
    Future<void> withInstantStat(
      File file,
      Future<void> Function() body,
    ) async {
      final FileStat real = await file.stat();
      await IOOverrides.runZoned<Future<void>>(
        body,
        stat: (String _) => Future<FileStat>.value(real),
      );
    }

    /// 只在被打断或被放行时结束的假计算：被打断后还要等 settle（模拟原生读完当前
    /// 这一块），再以取消告终。
    ({
      VideoFingerprintCompute compute,
      List<VideoFingerprintCancellation> runs,
      Completer<void> release,
      Completer<void> settle,
    })
    gatedCompute() {
      final List<VideoFingerprintCancellation> runs =
          <VideoFingerprintCancellation>[];
      final Completer<void> release = Completer<void>();
      final Completer<void> settle = Completer<void>();
      return (
        compute:
            (
              String absolutePath,
              FileStat stat,
              VideoFingerprintCancellation cancel,
            ) async {
              runs.add(cancel);
              await Future.any(<Future<void>>[
                release.future,
                cancel.whenCancelled,
              ]);
              if (!cancel.isCancelled) return 'a' * 64;
              await settle.future;
              throw VideoFingerprintCancelledException(absolutePath);
            },
        runs: runs,
        release: release,
        settle: settle,
      );
    }

    test('唯一等待方取消：打断计算，等它停下才结束；之后重新开算', () async {
      final File file = await File(
        '${directory.path}/only.mkv',
      ).writeAsBytes(List<int>.filled(1024, 1));
      await withInstantStat(file, () async {
        final g = gatedCompute();
        final VideoSourceFingerprint hashes = VideoSourceFingerprint(
          compute: g.compute,
        );
        final VideoFingerprintCancellation token =
            VideoFingerprintCancellation();
        bool done = false;
        final Future<void> call = expectLater(
          hashes.fingerprint(file.path, cancel: token),
          throwsA(isA<VideoFingerprintCancelledException>()),
        ).then((_) => done = true);
        await pumpEventQueue();
        expect(g.runs, hasLength(1));
        token.cancel();
        await pumpEventQueue();
        expect(g.runs.single.isCancelled, isTrue, reason: '没有别的等待方，打断计算');
        expect(done, isFalse, reason: '计算还没停下（还开着文件），不能先返回');
        g.settle.complete();
        await call;
        // 新请求不并进被打断的那次，重新开算。
        final Future<String> again = hashes.fingerprint(file.path);
        await pumpEventQueue();
        expect(g.runs, hasLength(2));
        expect(g.runs.last.isCancelled, isFalse);
        g.release.complete();
        expect(await again, 'a' * 64);
      });
    });

    test('还有不可取消的等待方（本机制卡）：取消方立即撤走，计算照常算完', () async {
      final File file = await File(
        '${directory.path}/shared.mkv',
      ).writeAsBytes(List<int>.filled(1024, 2));
      await withInstantStat(file, () async {
        final g = gatedCompute();
        final VideoSourceFingerprint hashes = VideoSourceFingerprint(
          compute: g.compute,
        );
        final VideoFingerprintCancellation token =
            VideoFingerprintCancellation();
        final Future<String> host = hashes.fingerprint(
          file.path,
          cancel: token,
        );
        final Future<String> local = hashes.fingerprint(file.path);
        await pumpEventQueue();
        expect(g.runs, hasLength(1));
        token.cancel();
        await expectLater(
          host,
          throwsA(isA<VideoFingerprintCancelledException>()),
        );
        expect(g.runs.single.isCancelled, isFalse, reason: '本机制卡还在等');
        g.release.complete();
        expect(await local, 'a' * 64);
      });
    });

    test('两个可取消的等待方：都撤走才打断', () async {
      final File file = await File(
        '${directory.path}/two.mkv',
      ).writeAsBytes(List<int>.filled(1024, 3));
      await withInstantStat(file, () async {
        final g = gatedCompute();
        final VideoSourceFingerprint hashes = VideoSourceFingerprint(
          compute: g.compute,
        );
        final VideoFingerprintCancellation first =
            VideoFingerprintCancellation();
        final VideoFingerprintCancellation second =
            VideoFingerprintCancellation();
        final Future<String> a = hashes.fingerprint(file.path, cancel: first);
        final Future<String> b = hashes.fingerprint(file.path, cancel: second);
        await pumpEventQueue();
        first.cancel();
        await expectLater(
          a,
          throwsA(isA<VideoFingerprintCancelledException>()),
        );
        expect(g.runs.single.isCancelled, isFalse);
        second.cancel();
        await pumpEventQueue();
        expect(g.runs.single.isCancelled, isTrue);
        g.settle.complete();
        await expectLater(
          b,
          throwsA(isA<VideoFingerprintCancelledException>()),
        );
      });
    });

    test('已取消的信号不开算', () async {
      final File file = await File(
        '${directory.path}/pre.mkv',
      ).writeAsBytes(List<int>.filled(1024, 4));
      final g = gatedCompute();
      final VideoSourceFingerprint hashes = VideoSourceFingerprint(
        compute: g.compute,
      );
      await expectLater(
        hashes.fingerprint(
          file.path,
          cancel: VideoFingerprintCancellation()..cancel(),
        ),
        throwsA(isA<VideoFingerprintCancelledException>()),
      );
      expect(g.runs, isEmpty);
    });

    test('默认计算经原生取消标志停下（ffc_hash_sha256_file_cancellable）', () async {
      final List<int> bytes = List<int>.generate(3 << 20, (int i) => i % 241);
      final File file = await File(
        '${directory.path}/native.mkv',
      ).writeAsBytes(bytes);
      final FileStat stat = await file.stat();
      final VideoFingerprintCancellation token = VideoFingerprintCancellation();
      final Future<String> run = VideoSourceFingerprint.hashInIsolate(
        file.absolute.path,
        stat,
        token,
      );
      // 同步取消：标志在 worker isolate 起来、原生读盘开始之前就已置位。
      token.cancel();
      await expectLater(
        run,
        throwsA(isA<VideoFingerprintCancelledException>()),
      );
      expect(
        await VideoSourceFingerprint.hashInIsolate(
          file.absolute.path,
          stat,
          VideoFingerprintCancellation(),
        ),
        sha256.convert(bytes).toString(),
      );
    });
  });

  test(
    'streams, missing files and malformed fingerprints never validate',
    () async {
      final VideoSourceFingerprint hashes = VideoSourceFingerprint();
      expect(
        hashes.fingerprint('https://host/episode.mkv'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        hashes.fingerprint('${directory.path}/missing'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await hashes.matches('${directory.path}/missing', 'partial-hash'),
        isFalse,
      );
    },
  );
}
