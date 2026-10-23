/// 系统语音原生半边的真机 / 模拟器探针（iOS AVSpeechSynthesizer、Android TextToSpeech）：
/// 列引擎 / 声音、点名声音与按语言各合成一句、点名不存在的声音报 voiceUnavailable。
/// 不经 UI，只走 `TtsChannel`——与朗读 / 制卡同一条通道。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';
import 'package:fushi/src/utils/misc/system_tts_voices.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('system tts native probe', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final TtsChannel channel = TtsChannel.instance;
      final List<SystemTtsEngine> engines = await channel
          .listSystemTtsEngines();
      // ignore: avoid_print
      print(
        'SYSTTS engines: ${engines.map((SystemTtsEngine e) => '${e.id}(${e.label}${e.isDefault ? ',default' : ''})').join(' | ')}',
      );
      final String? engine = engines.isEmpty ? null : engines.first.id;
      final List<TtsVoice> voices = await channel.listSystemTtsVoices(
        engine: engine,
      );
      // ignore: avoid_print
      print(
        'SYSTTS voices(${voices.length}): ${voices.take(40).map((TtsVoice v) => '${v.id}[${v.locale}]').join(', ')}',
      );
      expect(voices, isNotEmpty);
      final Directory dir = await getTemporaryDirectory();
      final TtsVoice pick = voices.firstWhere(
        (TtsVoice v) => v.locale.toLowerCase().startsWith('ja'),
        orElse: () => voices.first,
      );
      int i = 0;
      for (final (String? voice, String? lang) in <(String?, String?)>[
        (pick.id, null),
        (null, 'ja'),
        (null, null),
      ]) {
        final Stopwatch sw = Stopwatch()..start();
        final String out = await channel.ttsToFile(
          pick.locale.startsWith('ja') ? 'こんにちは、今日はいい天気ですね。' : 'Hello there.',
          '${dir.path}/systts_${i++}.audio',
          languageTag: lang,
          engine: engine,
          voice: voice,
        );
        sw.stop();
        final Uint8List bytes = File(out).readAsBytesSync();
        final TtsAudioFormat? format = sniffTtsAudioFormat(bytes);
        final int? ms = format == null
            ? null
            : probeTtsAudioDurationMs(bytes, format);
        // ignore: avoid_print
        print(
          'SYSTTS voice=$voice lang=$lang → $format ${bytes.length}B ${ms}ms (${sw.elapsedMilliseconds}ms wall)',
        );
        expect(format, TtsAudioFormat.wav);
        expect(ms, greaterThan(300));
      }
      Object? missing;
      try {
        await channel.ttsToFile(
          'テスト',
          '${dir.path}/systts_missing.audio',
          engine: engine,
          voice: 'no.such.voice',
        );
      } on SystemTtsFailure catch (e) {
        missing = e.reason;
      }
      // ignore: avoid_print
      print('SYSTTS missing voice → $missing');
      expect(missing, SystemTtsFailureReason.voiceUnavailable);
    });
  });
}
