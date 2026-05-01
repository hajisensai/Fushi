import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/word_audio_resolver.dart';

void main() {
  group('WordAudioResolver', () {
    test('returns null for a missing local-only source instead of TTS fallback',
        () async {
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __) async => null,
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
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => const <String, String>{
          'file': 'audio/right.mp3',
          'source': 'forvo',
        },
        extractLocalAudio: (_, __) async => '/tmp/local_audio.mp3',
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
      expect(requestedSources, isEmpty);
    });

    test('expands and reads the first remote audio source list result',
        () async {
      String? requestedUrl;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        extractLocalAudio: (_, __) async => null,
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
  });
}
