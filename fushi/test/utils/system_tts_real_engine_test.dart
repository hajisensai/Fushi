/// 真引擎验证（桌面）：Windows 真起 PowerShell 工作进程列 OneCore / SAPI 声音并各合成
/// 一句；macOS 真跑 `say` 列声音、出 WAV。默认跳过（CI 机器装哪些声音不受控）；本机
/// 验证时 `FUSHI_REAL_SYSTEM_TTS=1 flutter test test/utils/system_tts_real_engine_test.dart`。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/desktop_tts.dart';
import 'package:fushi/src/utils/misc/system_tts_voices.dart';
import 'package:fushi/src/utils/misc/windows_speech_worker.dart';
import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_types.dart';

void main() {
  final bool real = Platform.environment['FUSHI_REAL_SYSTEM_TTS'] == '1';
  final bool enabled = Platform.isWindows && real;

  test(
    'macOS 真引擎：say -v ? 列得出日语声音；点名 / 按语言都直接出 WAV（缓存探测认得）',
    () async {
      final List<TtsVoice> voices = await listDesktopTtsVoices();
      final TtsVoice ja = voices.firstWhere(
        (TtsVoice v) => v.locale.startsWith('ja'),
      );
      // ignore: avoid_print
      print('${voices.length} voices; first ja = ${ja.id}');
      final Directory dir = Directory.systemTemp.createTempSync('fushi_mtts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      int i = 0;
      for (final (String? voice, String? lang) in <(String?, String?)>[
        (ja.id, null),
        (null, 'ja'),
      ]) {
        // `.audio` 是缓存文件的真实扩展名：say 必须按 --file-format 出 WAV 而不是看扩展名。
        final String out = await ttsToFileDesktop(
          text: 'こんにちは、今日はいい天気ですね。',
          outputPath: '${dir.path}/s${i++}.audio',
          languageTag: lang,
          voice: voice,
        );
        final Uint8List bytes = File(out).readAsBytesSync();
        expect(sniffTtsAudioFormat(bytes), TtsAudioFormat.wav);
        final int? ms = probeTtsAudioDurationMs(bytes, TtsAudioFormat.wav);
        // ignore: avoid_print
        print('voice=$voice lang=$lang → ${bytes.length} B, ${ms}ms audio');
        expect(ms, greaterThan(500));
      }
    },
    skip: Platform.isMacOS && real
        ? false
        : 'set FUSHI_REAL_SYSTEM_TTS=1 on macOS',
  );

  test(
    'Windows 真引擎：OneCore 声音列得出、点名 OneCore / SAPI 都能出 WAV、一个进程跑完',
    () async {
      int starts = 0;
      final WindowsSpeechWorker worker = WindowsSpeechWorker(
        startProcess: (String exe, List<String> args) {
          starts++;
          return Process.start(exe, args);
        },
      );
      final Stopwatch listing = Stopwatch()..start();
      final Map<String, Object?> reply = await worker.request(<String, Object?>{
        'op': 'voices',
      });
      listing.stop();
      final List<TtsVoice> voices = mergeWindowsSpeechVoices(reply['voices']);
      // ignore: avoid_print
      print(
        'voices (${listing.elapsedMilliseconds} ms incl. cold start): '
        '${voices.map((TtsVoice v) => '${v.id}[${v.locale}]').join(', ')}',
      );
      final TtsVoice oneCore = voices.firstWhere(
        (TtsVoice v) => v.id.startsWith(kWindowsOneCoreVoicePrefix),
      );
      final TtsVoice? sapi = voices
          .where((TtsVoice v) => v.id.startsWith(kWindowsSapiVoicePrefix))
          .firstOrNull;
      final Directory dir = Directory.systemTemp.createTempSync('fushi_wtts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final List<(String?, String?)> cases = <(String?, String?)>[
        (oneCore.id, null),
        if (sapi != null) (sapi.id, null),
        (null, 'ja'),
        (null, null),
      ];
      int i = 0;
      for (final (String? voice, String? lang) in cases) {
        final Stopwatch sw = Stopwatch()..start();
        final String out = await synthesizeWindowsSpeech(
          worker: worker,
          text: 'こんにちは、今日はいい天気ですね。',
          outputPath: '${dir.path}/s${i++}.audio',
          languageTag: lang,
          voice: voice,
        );
        sw.stop();
        final Uint8List bytes = File(out).readAsBytesSync();
        expect(sniffTtsAudioFormat(bytes), TtsAudioFormat.wav);
        final int? ms = probeTtsAudioDurationMs(bytes, TtsAudioFormat.wav);
        // ignore: avoid_print
        print(
          'voice=$voice lang=$lang → ${bytes.length} B, ${ms}ms audio, '
          '${sw.elapsedMilliseconds}ms wall',
        );
        expect(ms, greaterThan(500));
      }
      expect(starts, 1);
    },
    skip: enabled ? false : 'set FUSHI_REAL_SYSTEM_TTS=1 on Windows',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
