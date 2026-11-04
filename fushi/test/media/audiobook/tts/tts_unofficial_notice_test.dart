import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';

/// 反馈 zK7AJLTl3q / BUG-4089：微软翻译朗读走的是翻译 App 的非官方通道，
/// 编辑页必须写明「非官方、可能失效」；官方接口与本机引擎不显示这条。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test(
    'Microsoft Translator voice says it is unofficial and may stop working',
    () {
      final String? notice = ttsUnofficialNotice(
        MicrosoftTranslatorTtsDescriptor.providerId,
      );
      expect(notice, t.audiobook_tts_ms_translator_notice);
      expect(notice, contains('Unofficial'));
      expect(notice, contains('stop working'));
      expect(
        ttsProviderHint(MicrosoftTranslatorTtsDescriptor.providerId),
        t.audiobook_tts_unofficial_free_hint,
      );
    },
  );

  test('other unofficial web voices keep the generic notice', () {
    for (final String id in <String>[
      EdgeTtsDescriptor.providerId,
      GoogleTranslateTtsDescriptor.providerId,
    ]) {
      expect(ttsUnofficialNotice(id), t.audiobook_tts_unofficial_notice);
    }
  });

  test('official and local engines show no unofficial notice', () {
    expect(ttsUnofficialNotice(AzureTtsDescriptor.providerId), isNull);
    expect(ttsUnofficialNotice(SystemTtsDescriptor.providerId), isNull);
  });
}
