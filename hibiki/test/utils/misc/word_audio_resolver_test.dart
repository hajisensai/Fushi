import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/utils/misc/word_audio_resolver.dart';

void main() {
  group('WordAudioResolver', () {
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
  });
}
