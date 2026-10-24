/// 系统自带语音（离线兜底）：Android `TextToSpeech`、iOS `AVSpeechSynthesizer`、
/// Windows OneCore / SAPI、macOS `say`、Linux Open JTalk / espeak-ng。
///
/// 复用制卡单词音频的同一条合成通道 [TtsChannel.ttsToFile]（输出 WAV）。系统引擎不支持
/// 中途取消，取消只能在一句合成结束后生效。
///
/// 两个可选参数（不填 = 以前的行为：系统默认引擎、按文字语言自动挑声音）：
/// - [SystemTtsDescriptor.engineKey]：引擎包名，只有 Android 有（第三方引擎如讯飞、
///   MultiTTS 与系统默认引擎可以不同）；
/// - [SystemTtsDescriptor.voiceKey]：声音 id（见 `system_tts_voices.dart` 的编码）。
library;

import 'dart:io';

import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/utils/misc/system_tts.dart';
import 'package:fushi/src/utils/misc/system_tts_voices.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';

/// 系统语音的参数表。[supportsEngineChoice] = 本平台能选引擎（Android）。
List<TtsParamSpec> systemTtsParamSpecs({required bool supportsEngineChoice}) =>
    <TtsParamSpec>[
      if (supportsEngineChoice)
        const TtsParamSpec(
          key: SystemTtsDescriptor.engineKey,
          kind: TtsParamKind.voice,
        ),
      const TtsParamSpec(
        key: SystemTtsDescriptor.voiceKey,
        kind: TtsParamKind.voice,
      ),
    ];

/// 系统语音进缓存键的身份：平台名 + 非空的引擎 / 声音。没选引擎 / 声音时与以前的
/// 身份完全相同（已缓存的整本书不因升级失效）；选了就换键，换声音后不会误用旧缓存。
Map<String, Object?> systemTtsAudioIdentity(
  Map<String, Object?> base, {
  required String platform,
}) => <String, Object?>{
  for (final MapEntry<String, Object?> e in base.entries)
    if (!((e.key == SystemTtsDescriptor.engineKey ||
            e.key == SystemTtsDescriptor.voiceKey) &&
        (e.value == null || e.value == '')))
      e.key: e.value,
  'platform': platform,
};

class SystemTtsDescriptor extends TtsProviderDescriptor {
  const SystemTtsDescriptor();

  static const String providerId = 'system';

  /// 引擎包名（Android）。空 = 系统默认引擎。
  static const String engineKey = 'engine';

  /// 声音 id。空 = 按文字语言自动挑。
  static const String voiceKey = 'voice';

  @override
  String get id => providerId;

  @override
  bool get isAvailable =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux;

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
  List<TtsParamSpec> get params =>
      systemTtsParamSpecs(supportsEngineChoice: Platform.isAndroid);

  /// 系统声音随设备而变：身份里带平台名，跨设备同步来的缓存不会被误用。
  @override
  Map<String, Object?> audioIdentity(TtsVoicePreset preset) =>
      systemTtsAudioIdentity(
        super.audioIdentity(preset),
        platform: Platform.operatingSystem,
      );

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) => SystemTtsProvider(
    engine: preset.param(engineKey).trim(),
    voice: preset.param(voiceKey).trim(),
  );
}

class SystemTtsProvider extends TtsProvider {
  SystemTtsProvider({this.engine = '', this.voice = ''});

  /// 引擎包名（Android）；空 = 系统默认引擎。
  final String engine;

  /// 声音 id；空 = 按文字语言自动挑。
  final String voice;

  @override
  TtsCapabilities get capabilities => const SystemTtsDescriptor().capabilities;

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) =>
      TtsChannel.instance.listSystemTtsVoices(engine: engine);

  @override
  Future<List<TtsVoice>> listParamOptions(
    String paramKey, {
    TtsCancelToken? cancel,
  }) async {
    if (paramKey != SystemTtsDescriptor.engineKey) {
      return listVoices(cancel: cancel);
    }
    return <TtsVoice>[
      for (final SystemTtsEngine e
          in await TtsChannel.instance.listSystemTtsEngines())
        TtsVoice(id: e.id, displayName: e.label, locale: ''),
    ];
  }

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    cancel.throwIfCancelled();
    // 这条通道拿不到「这句来自哪本词典 / 哪本书」，按文字本身与已装词典定语言
    // （判据见 [resolveSystemTtsLanguageTag]，BUG-3669）；点名了声音时语言只作
    // 失败文案用。失败抛 [SystemTtsFailure]——它就是 [TtsFailure]，朗读 / 制卡两边
    // 照常按失败处理。
    final String written = await TtsChannel.instance.ttsToFile(
      text,
      outputPath,
      languageTag: resolveSystemTtsLanguageTag(
        text: text,
        installedDictionaryLanguages: systemTtsDictionaryLanguages(),
      ),
      engine: engine,
      voice: voice,
    );
    cancel.throwIfCancelled();
    if (written != outputPath) {
      await File(written).rename(outputPath);
    }
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}
