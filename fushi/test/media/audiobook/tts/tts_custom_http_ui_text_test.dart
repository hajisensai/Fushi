import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi_engine/tts/providers/custom_http_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_builtin_providers.dart';
import 'package:fushi_engine/tts/tts_provider.dart';

/// GitHub #2320：自定义 HTTP TTS 的设置文案。占位符是字面文字（本仓 slang 插值是
/// `${x}`），这里断言用户最终看到的是字面的 `{text}` 等。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  const CustomHttpTtsDescriptor descriptor = CustomHttpTtsDescriptor();

  test('every builtin provider and parameter has a readable label', () {
    for (final TtsProviderDescriptor d in kBuiltinTtsProviders) {
      expect(ttsProviderLabel(d.id), isNot(d.id), reason: d.id);
      for (final TtsParamSpec spec in d.params) {
        expect(
          ttsParamLabel(spec.key),
          isNot(spec.key),
          reason: '${d.id}.${spec.key}',
        );
      }
    }
  });

  test('custom HTTP hints show the literal placeholders', () {
    expect(
      ttsProviderHint(CustomHttpTtsDescriptor.providerId),
      contains('{text} {lang} {speed} {api_key}'),
    );
    expect(
      ttsParamHint(descriptor.id, CustomHttpTtsDescriptor.bodyKey),
      allOf(contains('"text": "{text}"'), contains('"{speed}"')),
    );
    expect(
      ttsParamHint(descriptor.id, CustomHttpTtsDescriptor.headersKey),
      contains('Authorization: Bearer {api_key}'),
    );
    expect(
      ttsParamHint(descriptor.id, CustomHttpTtsDescriptor.queryKey),
      contains('text={text}&text_lang={lang}'),
    );
    for (final String key in <String>[
      CustomHttpTtsDescriptor.apiKeyKey,
      CustomHttpTtsDescriptor.langKey,
      CustomHttpTtsDescriptor.speedKey,
      CustomHttpTtsDescriptor.responsePathKey,
    ]) {
      expect(ttsParamHint(descriptor.id, key), isNotNull, reason: key);
    }
    // 同名参数（api_key）不把自定义 HTTP 的说明带到别的引擎上。
    expect(
      ttsParamHint(
        GptSovitsTtsDescriptor.providerId,
        GptSovitsTtsDescriptor.apiKeyKey,
      ),
      t.audiobook_tts_param_bearer_hint,
    );
  });

  test('choice labels: response formats translated, methods verbatim', () {
    expect(
      ttsChoiceLabel(
        descriptor.id,
        CustomHttpTtsDescriptor.responseKey,
        CustomHttpTtsResponse.jsonUrl.id,
      ),
      t.audiobook_tts_response_json_url,
    );
    expect(
      ttsChoiceLabel(descriptor.id, CustomHttpTtsDescriptor.methodKey, 'GET'),
      'GET',
    );
    // 其它引擎的选择项仍按语言代码翻译。
    expect(
      ttsChoiceLabel(
        GptSovitsTtsDescriptor.providerId,
        GptSovitsTtsDescriptor.textLangKey,
        'all_ja',
      ),
      t.audiobook_tts_lang_all_ja,
    );
  });
}
