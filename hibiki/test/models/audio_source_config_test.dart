import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/audio_source_config.dart';

void main() {
  group('AudioSourceConfig', () {
    test('legacy URLs become enabled remote audio sources', () {
      final List<AudioSourceConfig> sources =
          AudioSourceConfig.fromLegacyUrls(<String>[
        'https://a.test/?term={term}',
        'https://b.test/?reading={reading}',
      ]);

      expect(sources, hasLength(2));
      expect(sources[0].kind, AudioSourceKind.remoteAudio);
      expect(sources[0].url, 'https://a.test/?term={term}');
      expect(sources[0].enabled, isTrue);
      expect(sources[1].url, 'https://b.test/?reading={reading}');
    });

    test('hibikiRemote does not hardcode an English display label', () {
      final AudioSourceConfig source = AudioSourceConfig.hibikiRemote();

      expect(source.label, isNull);
      expect(source.displayLabel, isEmpty);
      // 不再把英文名持久化进 json
      expect(source.toJson().containsKey('label'), isFalse);
    });

    test('local audio sources default to disabled', () {
      final AudioSourceConfig source = AudioSourceConfig.localAudio(
        label: 'local',
        path: '/db/local.db',
      );

      expect(source.enabled, isFalse);
    });

    test('round trips multiple local and remote sources plus Hibiki remote',
        () {
      final List<AudioSourceConfig> sources = <AudioSourceConfig>[
        AudioSourceConfig.hibikiRemote(enabled: true),
        AudioSourceConfig.localAudio(
          label: 'nhk16',
          path: '/db/nhk16.db',
          enabled: false,
        ),
        AudioSourceConfig.localAudio(
          label: 'daijisen',
          path: '/db/daijisen.db',
          enabled: true,
        ),
        AudioSourceConfig.remoteAudio(
          url: 'https://a.test/?term={term}',
          label: 'A',
        ),
        AudioSourceConfig.remoteAudio(
          url: 'https://b.test/?reading={reading}',
          label: 'B',
          enabled: false,
        ),
      ];

      final List<AudioSourceConfig> restored = sources
          .map((AudioSourceConfig source) =>
              AudioSourceConfig.fromJson(source.toJson()))
          .toList();

      expect(restored, sources);
      expect(
        restored.where((AudioSourceConfig source) => source.enabled),
        hasLength(3),
      );
    });
  });

  group('AudioSourceConfig.isLoopbackAudioUrl (TODO-1171)', () {
    test('detects loopback hosts across schemes and templates', () {
      expect(
        AudioSourceConfig.isLoopbackAudioUrl(
            'http://localhost:41440/localaudio/get/?term={term}'),
        isTrue,
      );
      expect(
        AudioSourceConfig.isLoopbackAudioUrl(
            'http://127.0.0.1:8765/get?reading={reading}'),
        isTrue,
      );
      expect(
        AudioSourceConfig.isLoopbackAudioUrl('http://[::1]:9000/x'),
        isTrue,
      );
      // Bare host:port template (no scheme) still caught via substring probe.
      expect(
        AudioSourceConfig.isLoopbackAudioUrl('localhost:19633/api/lookup'),
        isTrue,
      );
    });

    test('does not flag a real remote host or empty/null', () {
      expect(
        AudioSourceConfig.isLoopbackAudioUrl(
            'https://hoshi-reader.example.workers.dev/?term={term}'),
        isFalse,
      );
      expect(AudioSourceConfig.isLoopbackAudioUrl(''), isFalse);
      expect(AudioSourceConfig.isLoopbackAudioUrl(null), isFalse);
    });

    test('pointsAtLoopbackHost only true for loopback remoteAudio', () {
      expect(
        AudioSourceConfig.remoteAudio(url: 'http://localhost:1/x')
            .pointsAtLoopbackHost,
        isTrue,
      );
      expect(
        AudioSourceConfig.remoteAudio(url: 'https://real.test/{term}')
            .pointsAtLoopbackHost,
        isFalse,
      );
      // A localAudio source that happens to carry a loopback-looking label/path
      // is NOT a remote source, so it is never flagged.
      expect(
        AudioSourceConfig.localAudio(
                label: 'localhost', path: '/tmp/local_audio_1.db')
            .pointsAtLoopbackHost,
        isFalse,
      );
    });
  });
}
