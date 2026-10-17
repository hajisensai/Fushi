import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

void main() {
  test('parses translator page session parameters', () {
    const String html = '<div id="rich_tta" data-iid="translator.5023"></div>'
        '<script>_G={IG:"ABC123DEF",Region:"CN"};'
        'var params_AbusePreventionHelper = [1791710131935,"tok-en_9",3600000];'
        '</script>';
    final parsed = MicrosoftTranslatorTtsProvider.parseTranslatorPage(html);
    expect(parsed, isNotNull);
    expect(parsed!.ig, 'ABC123DEF');
    expect(parsed.iid, 'translator.5023');
    expect(parsed.key, '1791710131935');
    expect(parsed.token, 'tok-en_9');
    expect(parsed.ttlMs, 3600000);
  });

  test('a changed translator page yields null instead of guessing', () {
    expect(
      MicrosoftTranslatorTtsProvider.parseTranslatorPage('<html></html>'),
      isNull,
    );
  });

  test('both translate voices are online, keyless and voice-selectable', () {
    for (final TtsProviderDescriptor d in const <TtsProviderDescriptor>[
      MicrosoftTranslatorTtsDescriptor(),
      GoogleTranslateTtsDescriptor(),
    ]) {
      expect(d.category, TtsProviderCategory.online);
      expect(d.capabilities.needsCredential, isFalse);
      expect(
        d.params.single.kind,
        TtsParamKind.voice,
        reason: d.id,
      );
      expect(
        d.validate(TtsVoicePreset(id: 'p', providerId: d.id, name: 'n')),
        isEmpty,
        reason: 'defaults make it usable out of the box',
      );
    }
  });

  test('google translate lists one voice per language, ja first', () async {
    final TtsProvider p = const GoogleTranslateTtsDescriptor().create(
      const TtsVoicePreset(id: 'p', providerId: 'google_translate', name: 'n'),
      const TtsHost(),
    );
    final List<TtsVoice> voices = await p.listVoices();
    expect(voices.first.id, 'ja');
    expect(voices.map((TtsVoice v) => v.id).toSet().length, voices.length);
    await p.dispose();
  });
}
