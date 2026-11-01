/// 逐个声音向微软 Edge 朗读接口请求一句，报告成功 / 失败与耗时（判断某个声音在
/// 免费接口上能不能用）。用法：dart run tool/bench/tts_edge_voice_probe.dart v1 v2 ...
library;

import 'dart:io';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

Future<void> main(List<String> voices) async {
  final Directory dir = await Directory.systemTemp.createTemp('edge_probe_');
  for (final String voice in voices) {
    final TtsProvider p = const EdgeTtsDescriptor().create(
      TtsVoicePreset(
        id: voice,
        providerId: EdgeTtsDescriptor.providerId,
        name: voice,
        params: <String, String>{EdgeTtsDescriptor.voiceKey: voice},
      ),
      const TtsHost(),
    );
    final Stopwatch sw = Stopwatch()..start();
    try {
      await p.synthesize(
        '君は部活やってなかったよな？',
        outputPath: '${dir.path}${Platform.pathSeparator}$voice.mp3',
        cancel: TtsCancelToken(),
      );
      stdout.writeln('$voice ok ${sw.elapsedMilliseconds}ms');
    } on TtsFailure catch (f) {
      stdout.writeln('$voice FAIL $f ${sw.elapsedMilliseconds}ms');
    }
    await p.dispose();
  }
  await dir.delete(recursive: true);
  exit(0);
}
