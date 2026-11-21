import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/video_fingerprint_store.dart';
import 'package:fushi_engine/media/video/video_fingerprint_warmer.dart';
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';
import 'package:test/test.dart';

/// 拍板台 left3657：host 后台低优先级预热视频指纹（落盘），回跳只问已算好的。
void main() {
  late Directory dir;
  late File storeFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('video_fp_warm_');
    storeFile = File('${dir.path}/video_fingerprints.json');
  });
  tearDown(() async => dir.delete(recursive: true));

  Future<File> video(String name, int fill) =>
      File('${dir.path}/$name').writeAsBytes(List<int>.filled(4096, fill));

  /// 每次调用记一笔、回固定指纹的假计算（不跑原生哈希）。
  ({VideoFingerprintCompute compute, List<String> calls}) fakeCompute([
    String digest = '',
  ]) {
    final List<String> calls = <String>[];
    return (
      compute: (String absolutePath, FileStat stat) async {
        calls.add(absolutePath);
        return digest.isEmpty
            ? (absolutePath.hashCode.toRadixString(16).padLeft(8, '0') * 8)
                  .substring(0, 64)
            : digest;
      },
      calls: calls,
    );
  }

  group('落盘缓存', () {
    test('算过的指纹落盘，换一个进程（新实例 + 同一文件）直接命中、不再算', () async {
      final File f = await video('a.mkv', 1);
      final first = fakeCompute('a' * 64);
      final VideoSourceFingerprint before = VideoSourceFingerprint(
        compute: first.compute,
      )..store = VideoFingerprintStore(storeFile);
      expect(await before.fingerprint(f.path), 'a' * 64);
      expect(first.calls, hasLength(1));
      expect(storeFile.existsSync(), isTrue);

      final second = fakeCompute('b' * 64);
      final VideoSourceFingerprint after = VideoSourceFingerprint(
        compute: second.compute,
      )..store = VideoFingerprintStore(storeFile);
      expect(await after.known(f.path), 'a' * 64);
      expect(await after.fingerprint(f.path), 'a' * 64);
      expect(second.calls, isEmpty);
    });

    test('文件变了（大小 / 修改时间）落盘条目不再命中，重新算', () async {
      final File f = await video('a.mkv', 1);
      final VideoSourceFingerprint before = VideoSourceFingerprint(
        compute: fakeCompute('a' * 64).compute,
      )..store = VideoFingerprintStore(storeFile);
      await before.fingerprint(f.path);
      await f.writeAsBytes(List<int>.filled(8192, 2));

      final second = fakeCompute('c' * 64);
      final VideoSourceFingerprint after = VideoSourceFingerprint(
        compute: second.compute,
      )..store = VideoFingerprintStore(storeFile);
      expect(await after.known(f.path), isNull);
      expect(await after.fingerprint(f.path), 'c' * 64);
      expect(second.calls, hasLength(1));
    });

    test('坏的落盘文件当空缓存，不抛；之后照常写回合法 JSON', () async {
      final File f = await video('a.mkv', 1);
      await storeFile.writeAsString('{not json');
      final VideoSourceFingerprint hashes = VideoSourceFingerprint(
        compute: fakeCompute('d' * 64).compute,
      )..store = VideoFingerprintStore(storeFile);
      expect(await hashes.known(f.path), isNull);
      expect(await hashes.fingerprint(f.path), 'd' * 64);
      final Object? decoded = jsonDecode(storeFile.readAsStringSync());
      expect(decoded, isA<Map<String, Object?>>());
      expect((decoded! as Map<String, Object?>).length, 1);
    });
  });

  group('known：只查不算', () {
    test('没算过 → null 且不触发计算；文件不在 → 抛 FileSystemException', () async {
      final File f = await video('a.mkv', 1);
      final c = fakeCompute('e' * 64);
      final VideoSourceFingerprint hashes = VideoSourceFingerprint(
        compute: c.compute,
      );
      expect(await hashes.known(f.path), isNull);
      expect(c.calls, isEmpty);
      await hashes.fingerprint(f.path);
      expect(await hashes.known(f.path), 'e' * 64);
      await expectLater(
        hashes.known('${dir.path}/missing.mkv'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('后台预热', () {
    test('逐个算没算过的文件、跳过已算过的和读不了的；结果落盘', () async {
      final File a = await video('a.mkv', 1);
      final File b = await video('b.mkv', 2);
      final c = fakeCompute();
      final VideoSourceFingerprint hashes = VideoSourceFingerprint(
        compute: c.compute,
      )..store = VideoFingerprintStore(storeFile);
      await hashes.fingerprint(a.path);
      c.calls.clear();
      final VideoFingerprintWarmer warmer = VideoFingerprintWarmer(
        listPaths: () async => <String>[
          a.path,
          '${dir.path}/missing.mkv',
          b.path,
        ],
        fingerprints: hashes,
        pause: Duration.zero,
      );
      warmer.request();
      await warmer.running;
      expect(c.calls, <String>[b.absolute.path]);
      expect(await hashes.known(b.path), isNotNull);
      final Map<String, Object?> stored =
          jsonDecode(storeFile.readAsStringSync()) as Map<String, Object?>;
      expect(
        stored.keys,
        containsAll(<String>[a.absolute.path, b.absolute.path]),
      );
    });

    test('同一时刻只算一个文件（低优先级，不并发整盘读）', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 3; i++) await video('v$i.mkv', i + 1),
      ];
      int active = 0;
      int peak = 0;
      final VideoSourceFingerprint hashes = VideoSourceFingerprint(
        compute: (String absolutePath, FileStat stat) async {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          return 'f' * 64;
        },
      );
      final VideoFingerprintWarmer warmer = VideoFingerprintWarmer(
        listPaths: () async => <String>[for (final File f in files) f.path],
        fingerprints: hashes,
        pause: Duration.zero,
      );
      warmer.request();
      await warmer.running;
      expect(peak, 1);
    });

    test('跑的期间再请求：跑完补一轮；间隔不足 minInterval 的请求推迟', () async {
      final File a = await video('a.mkv', 1);
      int lists = 0;
      final Completer<void> gate = Completer<void>();
      final DateTime now = DateTime(2026, 11, 21);
      final VideoFingerprintWarmer warmer = VideoFingerprintWarmer(
        listPaths: () async {
          lists++;
          if (lists == 1) await gate.future;
          return <String>[a.path];
        },
        fingerprints: VideoSourceFingerprint(
          compute: fakeCompute('a' * 64).compute,
        ),
        pause: Duration.zero,
        minInterval: const Duration(minutes: 10),
        now: () => now,
      );
      warmer.request();
      warmer.request();
      gate.complete();
      await warmer.running;
      expect(lists, 2, reason: '跑的期间来的请求在跑完后补一轮');

      warmer.request();
      expect(warmer.running, isNull, reason: '刚跑完，不足间隔不立刻再跑');
      warmer.dispose();
    });

    test('dispose 后不再开新文件', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 3; i++) await video('v$i.mkv', i + 1),
      ];
      late VideoFingerprintWarmer warmer;
      final List<String> computed = <String>[];
      warmer = VideoFingerprintWarmer(
        listPaths: () async => <String>[for (final File f in files) f.path],
        fingerprints: VideoSourceFingerprint(
          compute: (String absolutePath, FileStat stat) async {
            computed.add(absolutePath);
            warmer.dispose();
            return 'a' * 64;
          },
        ),
        pause: Duration.zero,
      );
      warmer.request();
      await warmer.running;
      expect(computed, hasLength(1));
    });

    test('BUG-5078 / BUG-5087：close 等在算的文件与落盘收尾才返回', () async {
      final File f = await video('a.mkv', 1);
      final Completer<void> started = Completer<void>();
      final Completer<void> release = Completer<void>();
      final VideoSourceFingerprint hashes = VideoSourceFingerprint(
        compute: (String absolutePath, FileStat stat) async {
          started.complete();
          await release.future;
          return 'a' * 64;
        },
      )..store = VideoFingerprintStore(storeFile);
      final VideoFingerprintWarmer warmer = VideoFingerprintWarmer(
        listPaths: () async => <String>[f.path],
        fingerprints: hashes,
        pause: Duration.zero,
      );
      warmer.request();
      await started.future;
      bool closed = false;
      final Future<void> close = warmer.close().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse, reason: '还开着视频文件，close 不能先返回');
      release.complete();
      await close;
      expect(storeFile.readAsStringSync(), contains('a' * 64));
    });

    test('两文件之间歇息时 close 立即结束歇息，不再开下一个文件', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 2; i++) await video('v$i.mkv', i + 1),
      ];
      final List<String> computed = <String>[];
      final Completer<void> first = Completer<void>();
      final VideoFingerprintWarmer warmer = VideoFingerprintWarmer(
        listPaths: () async => <String>[for (final File f in files) f.path],
        fingerprints: VideoSourceFingerprint(
          compute: (String absolutePath, FileStat stat) async {
            computed.add(absolutePath);
            if (!first.isCompleted) first.complete();
            return 'a' * 64;
          },
        ),
        pause: const Duration(hours: 1),
      );
      warmer.request();
      await first.future;
      await warmer.close().timeout(const Duration(seconds: 10));
      expect(computed, hasLength(1));
      expect(warmer.running, isNull);
    });
  });
}
