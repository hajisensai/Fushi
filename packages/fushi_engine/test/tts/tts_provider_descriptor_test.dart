import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/google_cloud_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

TtsVoicePreset _preset(
  String provider, {
  Map<String, String> params = const <String, String>{},
  Map<String, String> secrets = const <String, String>{},
  int revision = 0,
}) => TtsVoicePreset(
  id: 'p',
  providerId: provider,
  name: 'n',
  params: params,
  secrets: secrets,
  revision: revision,
);

void main() {
  group('validate', () {
    const GptSovitsTtsDescriptor sovits = GptSovitsTtsDescriptor();

    test('GPT-SoVITS: missing ref audio reported, defaults fill the rest', () {
      expect(sovits.validate(_preset(sovits.id)), <String>['ref_audio_path', 'prompt_text']);
      expect(
        sovits.validate(
          _preset(sovits.id, params: <String, String>{'ref_audio_path': '/r', 'prompt_text': 'p'}),
        ),
        isEmpty,
      );
      expect(
        sovits.validate(
          _preset(
            sovits.id,
            params: <String, String>{
              'ref_audio_path': '/r',
              'prompt_text': 'p',
              'text_lang': '  ',
            },
          ),
        ),
        <String>['text_lang'],
      );
    });

    test('invalid URL reported', () {
      for (final String bad in <String>[
        'ftp://host/tts',
        'localhost:9880',
        'http://',
        'nonsense',
      ]) {
        expect(
          sovits.validate(
            _preset(
              sovits.id,
              params: <String, String>{'endpoint': bad, 'ref_audio_path': '/r', 'prompt_text': 'p'},
            ),
          ),
          <String>['endpoint'],
          reason: bad,
        );
      }
      expect(
        sovits.validate(
          _preset(
            sovits.id,
            params: <String, String>{
              'endpoint': 'https://gpu.local:9880/tts',
              'ref_audio_path': '/r',
              'prompt_text': 'p',
            },
          ),
        ),
        isEmpty,
      );
    });

    test('Azure / Google need api key; Edge needs nothing', () {
      expect(
        const AzureTtsDescriptor().validate(_preset('azure')),
        <String>['api_key'],
      );
      expect(
        const AzureTtsDescriptor().validate(
          _preset('azure', secrets: <String, String>{'api_key': 'k'}),
        ),
        isEmpty,
      );
      expect(
        const GoogleCloudTtsDescriptor().validate(_preset('google_cloud')),
        <String>['api_key'],
      );
      expect(const EdgeTtsDescriptor().validate(_preset('edge')), isEmpty);
    });
  });

  group('audioIdentity', () {
    test('GPT-SoVITS excludes endpoint and api_key', () {
      const GptSovitsTtsDescriptor d = GptSovitsTtsDescriptor();
      final Map<String, Object?> id = d.audioIdentity(
        _preset(
          d.id,
          params: <String, String>{
            'endpoint': 'http://10.0.0.2:9880',
            'ref_audio_path': ' /srv/a.wav ',
          },
          secrets: <String, String>{'api_key': 'secret'},
          revision: 4,
        ),
      );
      expect(id['provider'], 'gpt_sovits');
      expect(id['revision'], 4);
      expect(id['ref_audio_path'], '/srv/a.wav');
      expect(id['text_lang'], 'ja');
      expect(id['prompt_lang'], 'ja');
      expect(id.containsKey('prompt_text'), isTrue);
      expect(id.containsKey('endpoint'), isFalse);
      expect(id.containsKey('api_key'), isFalse);
      expect(id.values, isNot(contains('secret')));
    });

    test('changing endpoint / key keeps cache key; voice or revision changes it', () {
      const GptSovitsTtsDescriptor d = GptSovitsTtsDescriptor();
      String key(TtsVoicePreset p) =>
          TtsAudioCache.keyFor(d.audioIdentity(p), 'text');
      final String base = key(
        _preset(d.id, params: <String, String>{'ref_audio_path': '/a.wav'}),
      );
      expect(
        key(
          _preset(
            d.id,
            params: <String, String>{
              'ref_audio_path': '/a.wav',
              'endpoint': 'http://other:1',
            },
            secrets: <String, String>{'api_key': 'x'},
          ),
        ),
        base,
      );
      expect(
        key(_preset(d.id, params: <String, String>{'ref_audio_path': '/b.wav'})),
        isNot(base),
      );
      expect(
        key(
          _preset(
            d.id,
            params: <String, String>{'ref_audio_path': '/a.wav'},
            revision: 1,
          ),
        ),
        isNot(base),
      );
    });

    test('Azure excludes region / api_key, includes voice', () {
      const AzureTtsDescriptor d = AzureTtsDescriptor();
      final Map<String, Object?> id = d.audioIdentity(
        _preset(
          d.id,
          params: <String, String>{'region': 'eastus', 'voice': 'ja-JP-X'},
          secrets: <String, String>{'api_key': 'k'},
        ),
      );
      expect(id, <String, Object?>{
        'provider': 'azure',
        'revision': 0,
        'voice': 'ja-JP-X',
      });
    });

    test('Edge / Google include voice (default when unset)', () {
      expect(
        const EdgeTtsDescriptor().audioIdentity(_preset('edge')),
        <String, Object?>{
          'provider': 'edge',
          'revision': 0,
          'voice': EdgeTtsDescriptor.defaultVoice,
        },
      );
      expect(
        const GoogleCloudTtsDescriptor().audioIdentity(
          _preset('google_cloud', secrets: <String, String>{'api_key': 'k'}),
        ),
        <String, Object?>{
          'provider': 'google_cloud',
          'revision': 0,
          'voice': GoogleCloudTtsDescriptor.defaultVoice,
        },
      );
    });
  });

  test('TtsProviderRegistry lookup and available', () {
    final TtsProviderRegistry registry = TtsProviderRegistry(
      const <TtsProviderDescriptor>[EdgeTtsDescriptor(), AzureTtsDescriptor()],
    );
    expect(registry['edge'], isA<EdgeTtsDescriptor>());
    expect(registry['nope'], isNull);
    expect(registry.available.map((TtsProviderDescriptor d) => d.id), <String>[
      'edge',
      'azure',
    ]);
  });

  test('GoogleCloudTtsProvider.languageOf', () {
    expect(GoogleCloudTtsProvider.languageOf('ja-JP-Neural2-B'), 'ja-JP');
    expect(GoogleCloudTtsProvider.languageOf('weird'), 'ja-JP');
  });
}
