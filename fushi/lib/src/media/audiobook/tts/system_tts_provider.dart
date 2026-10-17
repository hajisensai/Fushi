/// 系统自带语音（离线兜底）：Android `TextToSpeech`、Windows SAPI、Linux Open JTalk。
///
/// 复用制卡单词音频的同一条合成通道 [TtsChannel.ttsToFile]（输出 WAV）。macOS 的
/// `say` 只出 AIFF、iOS 当前没有合成到文件的实现，这两端不提供。系统引擎不支持中途
/// 取消，取消只能在一句合成结束后生效。
library;

import 'dart:io';

import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/utils/misc/tts_channel.dart';

class SystemTtsDescriptor extends TtsProviderDescriptor {
  const SystemTtsDescriptor();

  static const String providerId = 'system';

  @override
  String get id => providerId;

  @override
  bool get isAvailable =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    maxConcurrency: 1,
    maxInputLength: 200,
  );

  @override
  TtsProviderCategory get category => TtsProviderCategory.system;

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[];

  /// 系统声音随设备而变：身份里带平台名，跨设备同步来的缓存不会被误用。
  @override
  Map<String, Object?> audioIdentity(TtsVoicePreset preset) =>
      <String, Object?>{
        ...super.audioIdentity(preset),
        'platform': Platform.operatingSystem,
      };

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      SystemTtsProvider();
}

class SystemTtsProvider extends TtsProvider {
  @override
  TtsCapabilities get capabilities => const SystemTtsDescriptor().capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    cancel.throwIfCancelled();
    final String? written = await TtsChannel.instance.ttsToFile(
      text,
      outputPath,
    );
    cancel.throwIfCancelled();
    if (written == null) {
      throw const TtsFailure(TtsFailureCode.unsupported, 'system engine');
    }
    if (written != outputPath) {
      await File(written).rename(outputPath);
    }
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}
