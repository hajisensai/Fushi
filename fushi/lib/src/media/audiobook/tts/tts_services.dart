/// TTS 的应用级单例：引擎注册表、预设存储、磁盘缓存。
///
/// 缓存必须全应用一个实例（pin 计数不跨实例），所以统一从这里取。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/voicevox_local_engine.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_builtin_providers.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';

class TtsServices {
  TtsServices._(this.prefs)
    : store = TtsPresetStore(prefs),
      pronunciation = TtsPronunciationStore(prefs),
      localGptSovits = GptSovitsLocalEngine(
        prefs: prefs,
        httpClientFactory: createAppHttpClient,
      ),
      localIrodori = IrodoriLocalEngine(
        prefs: prefs,
        httpClientFactory: createAppHttpClient,
        // uv 自己出网（PyPI / PyTorch / Python 发行包）：经本机中继走 app 代理。
        childProxyEnvironment: () async =>
            appNativeProxyEnvironment(await ensureAppNativeProxyEndpoint()),
      ),
      localVoicevox = VoicevoxLocalEngine(
        prefs: prefs,
        httpClientFactory: createAppHttpClient,
        manifest: kVoicevoxManifest,
      ),
      localAivisSpeech = VoicevoxLocalEngine(
        prefs: prefs,
        httpClientFactory: createAppHttpClient,
        manifest: kAivisSpeechManifest,
        // AivisSpeech 首次启动会从 AivisHub 下默认模型：经本机中继走 app 代理。
        childProxyEnvironment: () async =>
            appNativeProxyEnvironment(await ensureAppNativeProxyEndpoint()),
      ) {
    registry = TtsProviderRegistry(<TtsProviderDescriptor>[
      for (final TtsProviderDescriptor d in kBuiltinTtsProviders)
        // GPT-SoVITS 换成会自动拉起本机托管服务的版本（id / 参数 / 缓存键不变）。
        if (d is GptSovitsTtsDescriptor)
          AutoStartGptSovitsTtsDescriptor(localGptSovits)
        // 官方 Irodori-TTS-Server 同理（本机部署的服务朗读时自动拉起）。
        else if (d is IrodoriServerTtsDescriptor)
          AutoStartIrodoriServerTtsDescriptor(localIrodori)
        // 本机一键部署的 VOICEVOX / AivisSpeech 同理。
        else if (d is VoicevoxTtsDescriptor)
          AutoStartVoicevoxTtsDescriptor(localVoicevox)
        else if (d is AivisSpeechTtsDescriptor)
          AutoStartAivisSpeechTtsDescriptor(localAivisSpeech)
        else
          d,
      const SystemTtsDescriptor(),
    ]);
  }

  static TtsServices? _instance;

  /// [prefs] 只在首次调用时生效（app 只有一份偏好仓储）。
  static TtsServices of(PrefStore prefs) => _instance ??= TtsServices._(prefs);

  /// 已创建的单例（退出清理用：没用过 TTS 就不必为了停服务而创建它）。
  static TtsServices? get existing => _instance;

  /// 建单例时的偏好仓（只读已建好的单例的地方——如设置搜索求值副标题——经它
  /// 读 TTS 相关偏好，不必碰 AppModel）。
  final PrefStore prefs;

  final TtsPresetStore store;

  /// 发音词典（朗读与制作共用）。
  final TtsPronunciationStore pronunciation;

  /// 本机一键部署的 GPT-SoVITS（仅 Windows 可用；服务进程随 app 退出终止）。
  final GptSovitsLocalEngine localGptSovits;

  /// 本机一键部署的官方 Irodori-TTS-Server（桌面三端；服务进程随 app 退出终止）。
  final IrodoriLocalEngine localIrodori;

  /// 本机一键部署的 VOICEVOX ENGINE（桌面三端；服务进程随 app 退出终止）。
  final VoicevoxLocalEngine localVoicevox;

  /// 本机一键部署的 AivisSpeech Engine（同上）。
  final VoicevoxLocalEngine localAivisSpeech;

  /// [providerId] 对应的本机一键部署引擎（VOICEVOX / AivisSpeech）；其它引擎 null。
  VoicevoxLocalEngine? voicevoxLocalFor(String providerId) =>
      switch (providerId) {
        VoicevoxTtsDescriptor.providerId => localVoicevox,
        AivisSpeechTtsDescriptor.providerId => localAivisSpeech,
        _ => null,
      };

  late final TtsProviderRegistry registry;

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
