import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ttsEndpointIsLoopback', () {
    test('本机地址可以在本机选参考音频', () {
      expect(ttsEndpointIsLoopback('http://127.0.0.1:9880'), isTrue);
      expect(ttsEndpointIsLoopback('http://localhost:9880/tts'), isTrue);
      expect(ttsEndpointIsLoopback('http://[::1]:9880'), isTrue);
      expect(ttsEndpointIsLoopback(' http://127.0.0.2:1 '), isTrue);
    });

    test('局域网 / 远端服务看不到本机文件', () {
      expect(ttsEndpointIsLoopback('http://192.168.1.10:9880'), isFalse);
      expect(ttsEndpointIsLoopback('https://tts.example.com'), isFalse);
      expect(ttsEndpointIsLoopback(''), isFalse);
    });
  });

  group('ttsPromptTextFromFileName', () {
    test('文件名是台词时拿来预填', () {
      expect(
        ttsPromptTextFromFileName(r'C:\voices\こんにちは、今日もいい天気.wav'),
        'こんにちは、今日もいい天気',
      );
      expect(ttsPromptTextFromFileName('/v/【開心】ありがとうございます.mp3'), 'ありがとうございます');
      expect(ttsPromptTextFromFileName('/v/001_おはよう.wav'), 'おはよう');
      expect(ttsPromptTextFromFileName('/v/[happy]大丈夫.flac'), '大丈夫');
    });

    test('无意义的文件名不预填', () {
      expect(ttsPromptTextFromFileName('/v/ref.wav'), isNull);
      expect(ttsPromptTextFromFileName('/v/001_.wav'), isNull);
      expect(ttsPromptTextFromFileName('/v/sample_02.wav'), isNull);
    });
  });

  group('ttsOrphanedReferenceAudio', () {
    final String refDir = p.join('data', kTtsReferenceAudioDirName);
    TtsVoicePreset voice(String id, String refAudio) => TtsVoicePreset(
      id: id,
      providerId: GptSovitsTtsDescriptor.providerId,
      name: id,
      params: <String, String>{GptSovitsTtsDescriptor.refAudioKey: refAudio},
    );

    test('app 复制进来的、没人再用的副本随声音删除', () {
      final String copied = p.join(refDir, '1_ref.wav');
      expect(
        ttsOrphanedReferenceAudio(
          removed: voice('a', copied),
          remaining: <TtsVoicePreset>[voice('b', p.join(refDir, '2_x.wav'))],
          referenceDir: refDir,
        ),
        copied,
      );
    });

    test('别的声音还在用、或是用户手填的外部路径：不删', () {
      final String copied = p.join(refDir, '1_ref.wav');
      expect(
        ttsOrphanedReferenceAudio(
          removed: voice('a', copied),
          remaining: <TtsVoicePreset>[voice('b', copied)],
          referenceDir: refDir,
        ),
        isNull,
      );
      expect(
        ttsOrphanedReferenceAudio(
          removed: voice('a', p.join('voices', 'mine.wav')),
          remaining: const <TtsVoicePreset>[],
          referenceDir: refDir,
        ),
        isNull,
      );
      expect(
        ttsOrphanedReferenceAudio(
          removed: voice('a', ''),
          remaining: const <TtsVoicePreset>[],
          referenceDir: refDir,
        ),
        isNull,
      );
    });
  });
}
