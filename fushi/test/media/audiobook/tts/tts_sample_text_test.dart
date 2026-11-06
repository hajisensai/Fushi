// 反馈 jpdUVe2Qit：声音配置的试听文本固定是日文。改为跟随所选语言 / 声音。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/onboarding/onboarding_sample_text.dart';

TtsVoicePreset _preset(String providerId, Map<String, String> params) =>
    TtsVoicePreset(id: 'v', providerId: providerId, name: 'v', params: params);

void main() {
  test('试听文本按语言给示例句；日语 / 认不出 / 没有该语言的句子用日语默认', () {
    expect(ttsSampleTextFor('en-US'), kOnboardingSampleSentences['en']);
    expect(ttsSampleTextFor('zh-Hans'), kOnboardingSampleSentences['zh']);
    expect(ttsSampleTextFor('ko'), kOnboardingSampleSentences['ko']);
    expect(ttsSampleTextFor('ja-JP'), kTtsDefaultSampleText);
    expect(ttsSampleTextFor(null), kTtsDefaultSampleText);
    expect(ttsSampleTextFor('xx'), kTtsDefaultSampleText);
  });

  test('GPT-SoVITS 语言代码换算', () {
    expect(ttsLanguageCodeToTag('all_ja'), 'ja');
    expect(ttsLanguageCodeToTag('en'), 'en');
    expect(ttsLanguageCodeToTag('all_yue'), 'zh');
    expect(ttsLanguageCodeToTag('auto'), isNull);
    expect(ttsLanguageCodeToTag('auto_yue'), isNull);
  });

  test('从声音配置推断语言', () {
    expect(
      ttsPresetLanguage(
        _preset(GptSovitsTtsDescriptor.providerId, <String, String>{
          GptSovitsTtsDescriptor.textLangKey: 'en',
        }),
      ),
      'en',
    );
    // GPT-SoVITS 没设文本语言时按它的默认（日语）。
    expect(
      ttsPresetLanguage(
        _preset(GptSovitsTtsDescriptor.providerId, const <String, String>{}),
      ),
      'ja',
    );
    expect(
      ttsPresetLanguage(
        _preset(EdgeTtsDescriptor.providerId, <String, String>{
          EdgeTtsDescriptor.voiceKey: 'en-US-AriaNeural',
        }),
      ),
      'en',
    );
    expect(
      ttsPresetLanguage(
        _preset(EdgeTtsDescriptor.providerId, <String, String>{
          EdgeTtsDescriptor.voiceKey: 'Microsoft Haruka Desktop',
        }),
      ),
      isNull,
    );
    expect(
      ttsPresetLanguage(
        _preset(VoicevoxTtsDescriptor.providerId, const <String, String>{}),
      ),
      isNull,
    );
  });
}
