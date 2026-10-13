import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tts_cache_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  List<String> names() =>
      root.listSync().map((FileSystemEntity e) => p.basename(e.path)).toList()
        ..sort();

  Future<TtsResult> Function(String) writer(
    List<int> bytes, {
    List<TtsBoundary> boundaries = const <TtsBoundary>[],
  }) => (String path) async {
    await File(path).writeAsBytes(bytes);
    return TtsResult(format: TtsAudioFormat.wav, boundaries: boundaries);
  };

  group('keyFor', () {
    test('stable, order-independent, sensitive to text and identity', () {
      final String a = TtsAudioCache.keyFor(<String, Object?>{
        'provider': 'edge',
        'voice': 'v1',
        'revision': 0,
      }, '今日は');
      final String b = TtsAudioCache.keyFor(<String, Object?>{
        'revision': 0,
        'voice': 'v1',
        'provider': 'edge',
      }, '今日は');
      expect(a, b);
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        TtsAudioCache.keyFor(<String, Object?>{
          'provider': 'edge',
          'voice': 'v1',
          'revision': 0,
        }, '今晩は'),
        isNot(a),
      );
      expect(
        TtsAudioCache.keyFor(<String, Object?>{
          'provider': 'edge',
          'voice': 'v2',
          'revision': 0,
        }, '今日は'),
        isNot(a),
      );
      expect(
        TtsAudioCache.keyFor(<String, Object?>{
          'provider': 'edge',
          'voice': 'v1',
          'revision': 1,
        }, '今日は'),
        isNot(a),
      );
    });
  });

  test('obtain publishes audio + meta, lookup hits afterwards', () async {
    final TtsAudioCache cache = TtsAudioCache(root: root);
    const String key = 'k1';
    expect(await cache.lookup(key), isNull);
    int synthCalls = 0;
    final TtsCachedAudio audio = await cache.obtain(key, (String path) async {
      synthCalls++;
      expect(p.basename(path), endsWith('.part'));
      return writer(
        buildWav(dataBytes: 8000),
        boundaries: const <TtsBoundary>[
          TtsBoundary(
            textOffset: 0,
            textLength: 2,
            offsetMs: 10,
            durationMs: 90,
          ),
        ],
      )(path);
    });
    expect(audio.key, key);
    expect(audio.format, TtsAudioFormat.wav);
    expect(audio.durationMs, 500);
    expect(audio.path, cache.audioPathFor(key));
    expect(names(), <String>['k1.audio', 'k1.json']);

    final TtsCachedAudio? hit = await cache.lookup(key);
    expect(hit, isNotNull);
    expect(hit!.durationMs, 500);
    expect(hit.path, cache.audioPathFor(key));
    expect(hit.boundaries, hasLength(1));
    expect(hit.boundaries.single.offsetMs, 10);

    final TtsCachedAudio again = await cache.obtain(key, (String path) async {
      synthCalls++;
      return writer(buildWav())(path);
    });
    expect(again.durationMs, 500);
    expect(synthCalls, 1);
  });

  test(
    'concurrent obtain of the same key reuses the first published file',
    () async {
      final TtsAudioCache cache = TtsAudioCache(root: root);
      const String key = 'dup';
      final Completer<void> releaseSecond = Completer<void>();
      final Future<TtsCachedAudio> first = cache.obtain(
        key,
        writer(buildWav(dataBytes: 8000)),
      );
      final Future<TtsCachedAudio> second = cache.obtain(key, (
        String path,
      ) async {
        await releaseSecond.future;
        return writer(buildWav(dataBytes: 16000))(path);
      });
      final TtsCachedAudio a = await first;
      // 第一份已发布，模拟播放器已打开它：记下它的身份。
      final File published = File(a.path);
      final DateTime publishedAt = await published.lastModified();
      final int publishedLength = await published.length();
      releaseSecond.complete();
      final TtsCachedAudio b = await second;
      expect(b.path, a.path);
      expect(b.durationMs, a.durationMs);
      expect(await published.length(), publishedLength);
      expect(await published.lastModified(), publishedAt);
      expect(names(), <String>['dup.audio', 'dup.json']);
    },
  );

  test('lookup misses when audio size mismatches or meta corrupt', () async {
    final TtsAudioCache cache = TtsAudioCache(root: root);
    await cache.obtain('k', writer(buildWav()));
    await File(cache.audioPathFor('k')).writeAsBytes(<int>[1, 2, 3]);
    expect(await cache.lookup('k'), isNull);
    await File(p.join(root.path, 'k.json')).writeAsString('{oops');
    expect(await cache.lookup('k'), isNull);
  });

  test('invalid audio throws badResponse and leaves no .part', () async {
    final TtsAudioCache cache = TtsAudioCache(root: root);
    await expectLater(
      cache.obtain('bad', writer('<html>error</html>'.codeUnits)),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.badResponse,
        ),
      ),
    );
    await expectLater(
      cache.obtain('empty', writer(buildWav(dataBytes: 0))),
      throwsA(isA<TtsFailure>()),
    );
    expect(names(), isEmpty);
    expect(await cache.lookup('bad'), isNull);
  });

  test('synth failure propagates and leaves no .part', () async {
    final TtsAudioCache cache = TtsAudioCache(root: root);
    await expectLater(
      cache.obtain('x', (String path) async {
        await File(path).writeAsBytes(<int>[1, 2, 3]);
        throw const TtsFailure(TtsFailureCode.network);
      }),
      throwsA(
        isA<TtsFailure>().having(
          (TtsFailure f) => f.code,
          'code',
          TtsFailureCode.network,
        ),
      ),
    );
    expect(names().where((String n) => n.endsWith('.part')), isEmpty);
  });

  group('eviction', () {
    // 一条缓存 ≈ 1644 字节 WAV + ~80 字节元数据。
    final List<int> wav = buildWav(dataBytes: 1600);

    Future<void> age(String key, int minutesAgo) async {
      final DateTime t = DateTime.now().subtract(Duration(minutes: minutesAgo));
      await File(p.join(root.path, '$key.json')).setLastModified(t);
      await File(p.join(root.path, '$key.audio')).setLastModified(t);
    }

    test('evicts least recently used beyond maxBytes', () async {
      final TtsAudioCache cache = TtsAudioCache(root: root, maxBytes: 4000);
      await cache.obtain('a', writer(wav));
      await age('a', 30);
      await cache.obtain('b', writer(wav));
      await age('b', 20);
      expect(names(), hasLength(4));
      await cache.obtain('c', writer(wav));
      expect(names(), <String>['b.audio', 'b.json', 'c.audio', 'c.json']);
      expect(await cache.sizeBytes(), lessThanOrEqualTo(4000));
    });

    test('skips pinned keys and always keeps the new key', () async {
      final TtsAudioCache cache = TtsAudioCache(root: root, maxBytes: 2000);
      await cache.obtain('a', writer(wav));
      await age('a', 30);
      cache.pin('a');
      cache.pin('a');
      expect(cache.isPinned('a'), isTrue);
      await cache.obtain('b', writer(wav));
      // 超额但 a 被 pin、b 是新写入 → 都保留
      expect(names(), <String>['a.audio', 'a.json', 'b.audio', 'b.json']);
      cache.unpin('a');
      expect(cache.isPinned('a'), isTrue);
      cache.unpin('a');
      expect(cache.isPinned('a'), isFalse);
      await age('b', 20);
      await cache.obtain('c', writer(wav));
      expect(names(), <String>['c.audio', 'c.json']);
    });
  });

  test('clear keeps pinned keys and in-progress .part files', () async {
    final TtsAudioCache cache = TtsAudioCache(root: root);
    await cache.obtain('a', writer(buildWav()));
    await cache.obtain('b', writer(buildWav()));
    await File(p.join(root.path, 'c.123.part')).writeAsBytes(<int>[0]);
    cache.pin('a');
    await cache.clear();
    expect(names(), <String>['a.audio', 'a.json', 'c.123.part']);
    expect(await cache.lookup('a'), isNotNull);
    expect(await cache.lookup('b'), isNull);
  });

  test('sizeBytes and clear on missing root', () async {
    final TtsAudioCache cache = TtsAudioCache(
      root: Directory(p.join(root.path, 'missing')),
    );
    expect(await cache.sizeBytes(), 0);
    await cache.clear();
  });
}
