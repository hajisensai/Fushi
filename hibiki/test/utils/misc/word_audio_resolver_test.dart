import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/utils/misc/word_audio_resolver.dart';

void main() {
  group('WordAudioResolver', () {
    tearDown(() {
      // 冷却表与时钟是静态状态：每个用例后复位，避免用例间串味（TODO-1057）。
      WordAudioResolver.debugResetRemoteFailureCooldown();
      WordAudioResolver.debugSetNowProvider(null);
    });
    test('returns null for a missing local-only source instead of TTS fallback',
        () async {
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (_) async => const <String>[],
      );

      final result = await resolver.resolve(
        expression: '食べる',
        reading: 'たべる',
        sources: const <String>[WordAudioResolver.localAudioUrl],
      );

      expect(result, isNull);
    });

    test('uses local audio source before later remote sources', () async {
      final List<String> requestedSources = <String>[];
      bool remoteQueried = false;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => const <String, dynamic>{
          'file': 'audio/right.mp3',
          'source': 'forvo',
        },
        extractLocalAudio: (_, __, {dbIndex = 0}) async =>
            '/tmp/local_audio.mp3',
        queryRemoteAudio: (_, __) async {
          remoteQueried = true;
          return 'https://hibiki.test/remote.mp3';
        },
        fetchAudioSourceList: (url) async {
          requestedSources.add(url);
          return const <String>['https://example.test/fallback.mp3'];
        },
      );

      final result = await resolver.resolve(
        expression: '食べる',
        reading: 'たべる',
        sources: const <String>[
          WordAudioResolver.localAudioUrl,
          'https://example.test/audio/list?term={term}&reading={reading}',
        ],
      );

      expect(result, '/tmp/local_audio.mp3');
      expect(remoteQueried, isFalse);
      expect(requestedSources, isEmpty);
    });

    test('uses remote Hibiki audio after local miss and before network sources',
        () async {
      final List<String> requestedSources = <String>[];
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        queryRemoteAudio: (_, __) async =>
            'https://hibiki.test/audio/file?id=1',
        fetchAudioSourceList: (url) async {
          requestedSources.add(url);
          return const <String>['https://example.test/fallback.mp3'];
        },
      );

      final result = await resolver.resolve(
        expression: '食べる',
        reading: 'たべる',
        sources: const <String>[
          WordAudioResolver.localAudioUrl,
          'https://example.test/audio/list?term={term}&reading={reading}',
        ],
      );

      expect(result, 'https://hibiki.test/audio/file?id=1');
      expect(requestedSources, isEmpty);
    });

    test('expands and reads the first remote audio source list result',
        () async {
      String? requestedUrl;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (url) async {
          requestedUrl = url;
          return const <String>['https://cdn.test/audio.mp3'];
        },
      );

      final result = await resolver.resolve(
        expression: '食べる',
        reading: 'たべる',
        sources: const <String>[
          'https://example.test/audio/list?term={term}&reading={reading}',
        ],
      );

      expect(
        requestedUrl,
        'https://example.test/audio/list?term=%E9%A3%9F%E3%81%B9%E3%82%8B&reading=%E3%81%9F%E3%81%B9%E3%82%8B',
      );
      expect(result, 'https://cdn.test/audio.mp3');
    });

    test('resolves typed sources in user order', () async {
      final List<String> calls = <String>[];
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        queryLocalAudioByDbIndex: (expression, reading, dbIndex) async {
          calls.add('local:$dbIndex');
          if (dbIndex == 1) {
            return <String, dynamic>{
              'file': 'audio/right.mp3',
              'source': 'nhk16',
              'dbIndex': dbIndex,
            };
          }
          return null;
        },
        extractLocalAudio: (_, __, {dbIndex = 0}) async {
          calls.add('extract:$dbIndex');
          return '/tmp/local_$dbIndex.mp3';
        },
        queryRemoteAudio: (_, __) async {
          calls.add('hibiki');
          return null;
        },
        fetchAudioSourceList: (url) async {
          calls.add(url);
          return const <String>['https://cdn.test/fallback.mp3'];
        },
      );

      final String? result = await resolver.resolveConfigured(
        expression: '食べる',
        reading: 'たべる',
        sources: <AudioSourceConfig>[
          AudioSourceConfig.hibikiRemote(enabled: true),
          AudioSourceConfig.localAudio(
            label: 'first',
            path: '/db/first.db',
            enabled: true,
          ),
          AudioSourceConfig.localAudio(
            label: 'second',
            path: '/db/second.db',
            enabled: true,
          ),
          AudioSourceConfig.remoteAudio(
            url: 'https://remote.test/?term={term}',
          ),
        ],
      );

      expect(result, '/tmp/local_1.mp3');
      expect(calls, <String>[
        'hibiki',
        'local:0',
        'local:1',
        'extract:1',
      ]);
    });

    test(
        'a failing remote source is skipped and does not block later sources '
        '(TODO-1057)', () async {
      final List<String> requested = <String>[];
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (url) async {
          requested.add(url);
          if (url.contains('dead.test')) {
            // 模拟死源：连接超时（同 localhost:41440 死源的失败面）。
            throw DioError.connectionTimeout(
              timeout: const Duration(seconds: 8),
              requestOptions: RequestOptions(path: url),
            );
          }
          return const <String>['https://cdn.test/good.mp3'];
        },
      );

      final String? result = await resolver.resolveConfigured(
        expression: 'テスト',
        reading: 'てすと',
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(
            url: 'https://dead.test/audio?term={term}',
          ),
          AudioSourceConfig.remoteAudio(
            url: 'https://good.test/audio?term={term}',
          ),
        ],
      );

      // 死源失败不阻塞后续可用源：仍拿到第二个源的结果。
      expect(result, 'https://cdn.test/good.mp3');
      // 两个源都被尝试了一次（第一次遇到死源才知道要冷却）。
      expect(requested.length, 2);
      expect(requested[0], contains('dead.test'));
      expect(requested[1], contains('good.test'));
    });

    test('a socket failure also skips to the next source (TODO-1057)',
        () async {
      bool nextTried = false;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (url) async {
          if (url.contains('dead.test')) {
            throw DioError(
              requestOptions: RequestOptions(path: url),
              error: const SocketException('Connection refused'),
            );
          }
          nextTried = true;
          return const <String>['https://cdn.test/ok.mp3'];
        },
      );

      final String? result = await resolver.resolveConfigured(
        expression: 'テスト',
        reading: 'てすと',
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(
            url: 'https://dead.test/a?term={term}',
          ),
          AudioSourceConfig.remoteAudio(
            url: 'https://alive.test/b?term={term}',
          ),
        ],
      );

      expect(nextTried, isTrue);
      expect(result, 'https://cdn.test/ok.mp3');
    });

    test(
        'a failed host is short-circuited within the cooldown window on the '
        'next resolve, then retried after it expires (TODO-1057)', () async {
      // 用可控时钟隔离，无需真实 sleep。
      DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
      WordAudioResolver.debugSetNowProvider(() => now);

      int deadCalls = 0;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (url) async {
          if (url.contains('dead.test')) {
            deadCalls++;
            throw DioError.connectionTimeout(
              timeout: const Duration(seconds: 8),
              requestOptions: RequestOptions(path: url),
            );
          }
          return const <String>[];
        },
      );

      final List<AudioSourceConfig> sources = <AudioSourceConfig>[
        AudioSourceConfig.remoteAudio(
          url: 'https://dead.test/a?term={term}',
        ),
      ];

      // 第 1 次：真正打到死源，失败并记录冷却。
      await resolver.resolveConfigured(
        expression: 'a',
        reading: 'a',
        sources: sources,
      );
      expect(deadCalls, 1);

      // 冷却窗内（+10s < 45s）：同一 host 第 2 次 resolve 短路，fetcher 不被调用。
      now = now.add(const Duration(seconds: 10));
      await resolver.resolveConfigured(
        expression: 'a',
        reading: 'a',
        sources: sources,
      );
      expect(deadCalls, 1, reason: '冷却窗内不应再调用 fetcher');

      // 冷却窗过后（+50s > 45s）：放行，再次尝试 fetcher。
      now = now.add(const Duration(seconds: 50));
      await resolver.resolveConfigured(
        expression: 'a',
        reading: 'a',
        sources: sources,
      );
      expect(deadCalls, 2, reason: '冷却过期后应再次尝试');
    });

    test('a subsequent success clears the cooldown for that host (TODO-1057)',
        () async {
      DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
      WordAudioResolver.debugSetNowProvider(() => now);

      bool shouldFail = true;
      int calls = 0;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (url) async {
          calls++;
          if (shouldFail) {
            throw DioError.connectionTimeout(
              timeout: const Duration(seconds: 8),
              requestOptions: RequestOptions(path: url),
            );
          }
          return const <String>['https://cdn.test/win.mp3'];
        },
      );

      final List<AudioSourceConfig> sources = <AudioSourceConfig>[
        AudioSourceConfig.remoteAudio(
          url: 'https://flaky.test/a?term={term}',
        ),
      ];

      // 失败 -> 记冷却。
      await resolver.resolveConfigured(
        expression: 'a',
        reading: 'a',
        sources: sources,
      );
      expect(calls, 1);

      // 冷却过期后恢复，且这次成功。
      now = now.add(const Duration(seconds: 50));
      shouldFail = false;
      final String? ok = await resolver.resolveConfigured(
        expression: 'a',
        reading: 'a',
        sources: sources,
      );
      expect(calls, 2);
      expect(ok, 'https://cdn.test/win.mp3');

      // 成功已清冷却：立刻再查（时钟不推进）仍应打到 fetcher，不被短路。
      final String? again = await resolver.resolveConfigured(
        expression: 'a',
        reading: 'a',
        sources: sources,
      );
      expect(calls, 3, reason: '成功后冷却应被清除，不再短路');
      expect(again, 'https://cdn.test/win.mp3');
    });

    test('cooldown key normalizes by host across differing paths (TODO-1057)',
        () {
      expect(
        WordAudioResolver.remoteFailureCooldownKey(
          'https://host.test/a?term=x',
        ),
        WordAudioResolver.remoteFailureCooldownKey(
          'https://host.test/b?reading=y',
        ),
      );
    });
  });
}
