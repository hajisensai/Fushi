/// TTS 的应用级单例：引擎注册表、预设存储、磁盘缓存。
///
/// 缓存必须全应用一个实例（pin 计数不跨实例），所以统一从这里取。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_builtin_providers.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

class TtsServices {
  TtsServices._(PrefStore prefs)
      : store = TtsPresetStore(prefs),
        pronunciation = TtsPronunciationStore(prefs);

  static TtsServices? _instance;

  /// [prefs] 只在首次调用时生效（app 只有一份偏好仓储）。
  static TtsServices of(PrefStore prefs) => _instance ??= TtsServices._(prefs);

  final TtsPresetStore store;

  /// 发音词典（朗读与制作共用）。
  final TtsPronunciationStore pronunciation;

  final TtsProviderRegistry registry = TtsProviderRegistry(
    <TtsProviderDescriptor>[
      ...kBuiltinTtsProviders,
      const SystemTtsDescriptor(),
    ],
  );

  final TtsHost host = TtsHost(
    log: (String message) =>
        ErrorLogService.instance.log('Tts', message, StackTrace.current),
  );

  TtsAudioCache? _cache;

  Future<TtsAudioCache> cache() async {
    final TtsAudioCache? existing = _cache;
    if (existing != null) return existing;
    final Directory support = await enginePaths.supportRootDirectory();
    return _cache ??= TtsAudioCache(
      root: Directory(p.join(support.path, 'tts_cache')),
    );
  }

  /// 从没配过声音时内置一份「微软 Edge」（免费、免配置，开箱即可朗读）。只在清单
  /// 从未写过时生效：用户删光声音后不会再塞回来。
  Future<void> seedBuiltinVoiceIfUnset() async {
    if (store.hasStoredPresets) return;
    const TtsVoicePreset edge = TtsVoicePreset(
      id: 'builtin_edge',
      providerId: EdgeTtsDescriptor.providerId,
      name: 'Microsoft Edge · Nanami',
      params: <String, String>{
        EdgeTtsDescriptor.voiceKey: EdgeTtsDescriptor.defaultVoice,
      },
    );
    await store.savePresets(const <TtsVoicePreset>[edge]);
    await store.setActivePresetId(edge.id);
  }

  /// 当前预设及其引擎；没配 / 引擎在本平台不可用返回 null。
  ({TtsVoicePreset preset, TtsProviderDescriptor descriptor})? activeVoice() {
    final TtsVoicePreset? preset = store.activePreset();
    if (preset == null) return null;
    final TtsProviderDescriptor? descriptor = registry[preset.providerId];
    if (descriptor == null || !descriptor.isAvailable) return null;
    return (preset: preset, descriptor: descriptor);
  }
}
