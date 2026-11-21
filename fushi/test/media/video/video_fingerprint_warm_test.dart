import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/video_fingerprint_store.dart';
import 'package:fushi_engine/media/video/video_fingerprint_warmer.dart';
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';
import 'package:fake_async/fake_async.dart';
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

  /// 落盘日志回放出的「路径 → 指纹」（后写的同键行覆盖先写的）。
  Map<String, String> storedDigests() {
    final Map<String, String> out = <String, String>{};
    for (final String line in storeFile.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final Map<String, Object?> row = jsonDecode(line) as Map<String, Object?>;
      out[row['p']! as String] = row['h']! as String;
    }
    return out;
  }

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

    test('坏的落盘文件当空缓存，不抛；之后整份写回合法日志', () async {
      final File f = await video('a.mkv', 1);
      await storeFile.writeAsString('{not json');
      final VideoSourceFingerprint hashes = VideoSourceFingerprint(
        compute: fakeCompute('d' * 64).compute,
      )..store = VideoFingerprintStore(storeFile);
      expect(await hashes.known(f.path), isNull);
      expect(await hashes.fingerprint(f.path), 'd' * 64);
      expect(storedDigests(), <String, String>{f.absolute.path: 'd' * 64});
    });

    test('写到一半的尾行只丢那一行，前面的条目照常命中', () async {
      final File a = await video('a.mkv', 1);
      final File b = await video('b.mkv', 2);
      final VideoFingerprintStore first = VideoFingerprintStore(storeFile);
      await first.put(a.absolute.path, await a.stat(), 'a' * 64);
      await first.put(b.absolute.path, await b.stat(), 'b' * 64);
      final String text = storeFile.readAsStringSync();
      // 模拟追加 b 时掉电：最后一行只写了一半。
      await storeFile.writeAsString(text.substring(0, text.length - 20));

      final VideoFingerprintStore reopened = VideoFingerprintStore(storeFile);
      expect(await reopened.lookup(a.absolute.path, await a.stat()), 'a' * 64);
      expect(await reopened.lookup(b.absolute.path, await b.stat()), isNull);
      await reopened.put(b.absolute.path, await b.stat(), 'c' * 64);
      expect(storedDigests(), <String, String>{
        a.absolute.path: 'a' * 64,
        b.absolute.path: 'c' * 64,
      });
    });

    test('旧版整表 JSON 文件照样读得进来，下次写入压实成日志格式', () async {
      final File a = await video('a.mkv', 1);
      final File b = await video('b.mkv', 2);
      final FileStat sa = await a.stat();
      await storeFile.writeAsString(
        jsonEncode(<String, Object>{
          a.absolute.path: <String, Object>{
            's': sa.size,
            'm': sa.modified.microsecondsSinceEpoch,
            'c': sa.changed.microsecondsSinceEpoch,
            'h': 'a' * 64,
          },
        }),
      );
      final VideoFingerprintStore store = VideoFingerprintStore(storeFile);
      expect(await store.lookup(a.absolute.path, sa), 'a' * 64);
      await store.put(b.absolute.path, await b.stat(), 'b' * 64);
      expect(storedDigests(), <String, String>{
        a.absolute.path: 'a' * 64,
        b.absolute.path: 'b' * 64,
      });
    });

    test('HBK-AUDIT-009：逐条 put N 个文件，写盘字节数随 N 线性增长（不整表重写）', () async {
      final File f = await video('a.mkv', 1);
      final FileStat stat = await f.stat();
      const int n = 2000;
      final VideoFingerprintStore store = VideoFingerprintStore(storeFile);
      for (int i = 0; i < n; i++) {
        await store.put('${dir.path}/video_$i.mkv', stat, 'a' * 64);
      }
      // 一条记录一行；整表重写累计要写 N(N+1)/2 条。
      final int lineBytes = storeFile.lengthSync() ~/ n;
      expect(store.debugBytesWritten, lessThanOrEqualTo(2 * n * lineBytes));
      expect(store.debugFlushCount, lessThanOrEqualTo(n));
      expect(storeFile.readAsLinesSync(), hasLength(n));

      final VideoFingerprintStore reopened = VideoFingerprintStore(storeFile);
      expect(await reopened.lookup('${dir.path}/video_0.mkv', stat), 'a' * 64);
      expect(
        await reopened.lookup('${dir.path}/video_${n - 1}.mkv', stat),
        'a' * 64,
      );
    });

    test('同一时刻并发的多条 put 并成一次追加', () async {
      final File f = await video('a.mkv', 1);
      final FileStat stat = await f.stat();
      final VideoFingerprintStore store = VideoFingerprintStore(storeFile);
      await store.put('${dir.path}/warm.mkv', stat, 'a' * 64);
      final int before = store.debugFlushCount;
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 50; i++)
          store.put('${dir.path}/c$i.mkv', stat, 'b' * 64),
      ]);
      expect(store.debugFlushCount - before, lessThanOrEqualTo(2));
      expect(storedDigests(), hasLength(51));
    });

    test('同键反复覆盖：失效行攒多了整份压实，文件不无限变长、回放取最新值', () async {
      final File f = await video('a.mkv', 1);
      final FileStat stat = await f.stat();
      final VideoFingerprintStore store = VideoFingerprintStore(storeFile);
      for (int i = 0; i < 1000; i++) {
        await store.put(
          '${dir.path}/k${i % 4}.mkv',
          stat,
          (i % 16).toRadixString(16) * 64,
        );
      }
      expect(
        storeFile.readAsLinesSync().length,
        lessThanOrEqualTo(4 * 2 + 256),
      );
      final VideoFingerprintStore reopened = VideoFingerprintStore(storeFile);
      for (int k = 0; k < 4; k++) {
        final int last = 996 + k;
        expect(
          await reopened.lookup('${dir.path}/k$k.mkv', stat),
          (last % 16).toRadixString(16) * 64,
        );
      }
    });

    test('超出 maxEntries 淘汰最旧的；重开后回放结果与内存一致', () async {
      final File f = await video('a.mkv', 1);
      final FileStat stat = await f.stat();
      final VideoFingerprintStore store = VideoFingerprintStore(
        storeFile,
        maxEntries: 3,
      );
      for (int i = 0; i < 5; i++) {
        await store.put('${dir.path}/v$i.mkv', stat, 'a' * 64);
      }
      final VideoFingerprintStore reopened = VideoFingerprintStore(
        storeFile,
        maxEntries: 3,
      );
      for (int i = 0; i < 5; i++) {
        expect(
          await reopened.lookup('${dir.path}/v$i.mkv', stat),
          i < 2 ? isNull : 'a' * 64,
        );
      }
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
      expect(
        storedDigests().keys,
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

    test('跑的期间再请求：补的一轮也等满 minInterval；连续请求并成一轮', () async {
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
      for (int i = 0; i < 5; i++) {
        warmer.request();
      }
      gate.complete();
      await warmer.running;
      expect(lists, 1, reason: 'HBK-AUDIT-009：补的一轮不绕过间隔立刻开跑');
      expect(warmer.running, isNull);
      expect(warmer.hasDeferredRun, isTrue, reason: '跑的期间来的请求排成一轮');

      for (int i = 0; i < 5; i++) {
        warmer.request();
      }
      expect(warmer.running, isNull, reason: '刚跑完，不足间隔不立刻再跑');
      expect(lists, 1);
      warmer.dispose();
      expect(warmer.hasDeferredRun, isFalse);
    });

    test('推迟的那一轮在间隔满后只跑一次', () {
      fakeAsync((FakeAsync async) {
        int lists = 0;
        final VideoFingerprintWarmer warmer = VideoFingerprintWarmer(
          listPaths: () async {
            lists++;
            return <String>[];
          },
          fingerprints: VideoSourceFingerprint(
            compute: fakeCompute('a' * 64).compute,
          ),
          pause: Duration.zero,
          minInterval: const Duration(minutes: 10),
          now: () => DateTime(2026).add(async.elapsed),
        );
        warmer.request();
        for (int i = 0; i < 5; i++) {
          warmer.request();
        }
        async.flushMicrotasks();
        expect(lists, 1);
        async.elapse(const Duration(minutes: 9));
        expect(lists, 1);
        async.elapse(const Duration(minutes: 1, seconds: 1));
        expect(lists, 2, reason: '跑的期间来的 5 次请求并成间隔满后的一轮');
        async.elapse(const Duration(hours: 1));
        expect(lists, 2, reason: '没有新请求就不再跑');
        warmer.dispose();
      });
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
  });
}
