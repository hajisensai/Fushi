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
}
