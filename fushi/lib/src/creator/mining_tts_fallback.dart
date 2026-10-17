/// 制卡**单词音频**的 TTS 兜底：用哪个声音（偏好）与怎么合成。
///
/// 兜底链（[LocalAudioEnhancement]）：本地 Yomitan 音频库 → 配置的音频源 → 这里。
/// 声音可选：
/// - 系统语音（默认，沿用 `TtsChannel.ttsToFile` 的既有行为与平台差异：Android
///   TextToSpeech、Windows SAPI、macOS say（AIFF）、Linux Open JTalk / espeak-ng，
///   iOS 没有）；
/// - 用户在「朗读声音」里配置的任一预设（在线 / 本机服务 / 系统），经引擎注册表
///   取 provider，合成走全应用共用的 [TtsAudioCache]（同词同音色不重复合成）；
/// - 不使用 TTS 兜底。
///
/// 句子音频**不**做 TTS 兜底（BUG-172 结论），这里只服务单词音频。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart' show immutable;
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// String：制卡单词音频的 TTS 兜底声音（[MiningTtsFallbackVoice.wire]）。
/// 值可能指向本机的声音预设（`tts_voice_presets` 是设备本地清单），所以与
/// `tts_active_preset_id` 同族：设备本地，不进 Profile 快照 / 备份 / 同步。
const String kMiningTtsFallbackVoicePref = 'mining_tts_fallback_voice';

enum MiningTtsFallbackKind { system, none, preset }

/// 兜底声音的选择。
@immutable
class MiningTtsFallbackVoice {
  const MiningTtsFallbackVoice.system()
    : kind = MiningTtsFallbackKind.system,
      presetId = null;

  const MiningTtsFallbackVoice.none()
    : kind = MiningTtsFallbackKind.none,
      presetId = null;

  const MiningTtsFallbackVoice.preset(String this.presetId)
    : kind = MiningTtsFallbackKind.preset;

  static const String systemWire = 'system';
  static const String noneWire = 'none';
  static const String presetPrefix = 'preset:';

  final MiningTtsFallbackKind kind;

  /// 仅 [MiningTtsFallbackKind.preset] 非 null。
  final String? presetId;

  String get wire => switch (kind) {
    MiningTtsFallbackKind.system => systemWire,
    MiningTtsFallbackKind.none => noneWire,
    MiningTtsFallbackKind.preset => '$presetPrefix$presetId',
  };

  /// 未写过 / 不认识的值 = 系统语音（升级前的行为）。
  static MiningTtsFallbackVoice parse(Object? raw) {
    if (raw is! String) return const MiningTtsFallbackVoice.system();
    if (raw == noneWire) return const MiningTtsFallbackVoice.none();
    if (raw.startsWith(presetPrefix) && raw.length > presetPrefix.length) {
      return MiningTtsFallbackVoice.preset(raw.substring(presetPrefix.length));
    }
    return const MiningTtsFallbackVoice.system();
  }

  @override
  bool operator ==(Object other) =>
      other is MiningTtsFallbackVoice &&
      other.kind == kind &&
      other.presetId == presetId;

  @override
  int get hashCode => Object.hash(kind, presetId);

  @override
  String toString() => 'MiningTtsFallbackVoice($wire)';
}

MiningTtsFallbackVoice miningTtsFallbackVoiceOf(PrefStore prefs) =>
    MiningTtsFallbackVoice.parse(
      prefs.getPref(kMiningTtsFallbackVoicePref, defaultValue: ''),
    );

Future<void> setMiningTtsFallbackVoice(
  PrefStore prefs,
  MiningTtsFallbackVoice voice,
) => prefs.setPref(kMiningTtsFallbackVoicePref, voice.wire);

/// 本平台制卡兜底用的系统语音引擎名（专有名词，不翻译）；null = 本平台没有。
///
/// 与 `TtsChannel.ttsToFile` / `ttsToFileDesktop` 的分派同一张表：Android 走原生
/// TextToSpeech，桌面走各 OS 自带引擎，iOS 没有实现。
String? systemTtsEngineName() {
  if (Platform.isAndroid) return 'Android TextToSpeech';
  if (Platform.isWindows) return 'Windows SAPI';
  if (Platform.isMacOS) return 'macOS say';
  if (Platform.isLinux) return 'Open JTalk / espeak-ng';
  return null;
}

/// 这次单词音频确定拿不到，且有可以告诉用户的原因（选中的声音合成失败：服务没起、
/// 网络错误、凭据缺失、声音已删除……）。手动触发时把 [reason] 拼进
/// `audio_unavailable` 提示，自动触发时只记日志。
class WordAudioUnavailable implements Exception {
  const WordAudioUnavailable(this.reason, {this.cause});

  /// 已翻译的一句话原因。
  final String reason;

  /// 底层错误（[TtsFailure] 等），只进日志。
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'WordAudioUnavailable($reason)'
      : 'WordAudioUnavailable($reason; $cause)';
}

/// 手动触发时给用户看的提示：`audio_unavailable` + 原因。
String wordAudioUnavailableMessage(WordAudioUnavailable error) =>
    '${t.audio_unavailable} ${error.reason}';

/// 统一的失败上报：总是记错误日志（设置 › 诊断 › 错误日志可查）；[manual]
/// （用户主动点的）再弹带原因的提示，自动触发保持静默。
void reportWordAudioUnavailable(
  WordAudioUnavailable error,
  StackTrace stack, {
  required bool manual,
}) {
  // toString 带原因与底层错误码（TtsFailure 只含可公开诊断，不含正文 / 凭据）。
  ErrorLogService.instance.log(
    'LocalAudioEnhancement.ttsFallback',
    error,
    stack,
  );
  if (!manual) return;
  FushiToast.show(
    msg: wordAudioUnavailableMessage(error),
    toastLength: Toast.LENGTH_LONG,
    gravity: ToastGravity.BOTTOM,
    severity: ToastSeverity.error,
  );
}

/// 兜底合成要用到的 TTS 体系入口（生产 = [TtsServices]，测试可注入假实现）。
abstract interface class MiningTtsVoiceSource {
  TtsVoicePreset? presetById(String id);

  TtsProviderDescriptor? descriptorOf(String providerId);

  TtsHost get host;

  Future<TtsAudioCache> cache();
}

class _ServicesVoiceSource implements MiningTtsVoiceSource {
  const _ServicesVoiceSource(this._services);

  final TtsServices _services;

  @override
  TtsVoicePreset? presetById(String id) {
    for (final TtsVoicePreset preset in _services.store.loadPresets()) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  @override
  TtsProviderDescriptor? descriptorOf(String providerId) =>
      _services.registry[providerId];

  @override
  TtsHost get host => _services.host;

  @override
  Future<TtsAudioCache> cache() => _services.cache();
}

MiningTtsVoiceSource miningTtsVoiceSourceOf(TtsServices services) =>
    _ServicesVoiceSource(services);

/// 系统语音的固定输出文件名（沿用既有行为）。
const String kSystemTtsTermAudioFileName = 'tts_term_audio.wav';

/// 兜底链第 3 步：按 [choice] 合成 [text] 的单词音频。
///
/// - 系统语音：`systemTts(text, <outputDir>/tts_term_audio.wav)`，失败返回 null
///   （与升级前一致，不带原因）。
/// - 不使用：直接返回 null，不碰任何 TTS。
/// - 预设：经 [voices] 取引擎合成（走缓存），产物复制到 [outputDir] 下按缓存键
///   命名、扩展名随真实格式（wav / mp3）的文件——不同词互不覆盖。失败抛
///   [WordAudioUnavailable]，**不回退系统语音**。
Future<File?> synthesizeMiningTtsFallback({
  required String text,
  required MiningTtsFallbackVoice choice,
  required Directory outputDir,
  required Future<String?> Function(String text, String outputPath) systemTts,
  required MiningTtsVoiceSource Function() voices,
}) async {
  switch (choice.kind) {
    case MiningTtsFallbackKind.none:
      return null;
    case MiningTtsFallbackKind.system:
      final String? written = await systemTts(
        text,
        p.join(outputDir.path, kSystemTtsTermAudioFileName),
      );
      if (written == null) return null;
      final File file = File(written);
      return file.existsSync() ? file : null;
    case MiningTtsFallbackKind.preset:
      return _synthesizeWithPreset(
        text: text,
        presetId: choice.presetId!,
        outputDir: outputDir,
        source: voices(),
      );
  }
}

Future<File> _synthesizeWithPreset({
  required String text,
  required String presetId,
  required Directory outputDir,
  required MiningTtsVoiceSource source,
}) async {
  final TtsVoicePreset? preset = source.presetById(presetId);
  if (preset == null) {
    throw WordAudioUnavailable(t.models_tts_fallback_voice_missing);
  }
  final TtsProviderDescriptor? descriptor = source.descriptorOf(
    preset.providerId,
  );
  if (descriptor == null || !descriptor.isAvailable) {
    throw WordAudioUnavailable(t.audiobook_tts_failure_unsupported);
  }
  if (descriptor.validate(preset).isNotEmpty) {
    throw WordAudioUnavailable(
      t.audiobook_tts_failure_not_configured,
      cause: const TtsFailure(TtsFailureCode.notConfigured),
    );
  }
  // 构造也在 try 里：引擎构造期就可能抛（参数解析 / 本机运行时缺失），漏在外面就会
  // 绕过下方的 WordAudioUnavailable 归一化，调用方只拿到一个裸异常。
  TtsProvider? provider;
  try {
    final TtsProvider active = descriptor.create(preset, source.host);
    provider = active;
    final TtsAudioCache cache = await source.cache();
    final String key = TtsAudioCache.keyFor(
      descriptor.audioIdentity(preset),
      text,
    );
    final TtsCachedAudio audio = await cache.obtain(
      key,
      (String out) =>
          active.synthesize(text, outputPath: out, cancel: TtsCancelToken()),
    );
    // 缓存文件是 `<key>.audio`（无可用扩展名，且会被淘汰），Anki 按扩展名推断 MIME：
    // 复制一份带真实扩展名的出来。文件名按缓存键取，不同词 / 音色互不覆盖。
    await outputDir.create(recursive: true);
    final File cached = File(audio.path);
    final File out = File(
      p.join(
        outputDir.path,
        'tts_term_${key.substring(0, 16)}.${audio.format.extension}',
      ),
    );
    if (await out.exists() && await out.length() == await cached.length()) {
      return out;
    }
    return await cached.copy(out.path);
  } on WordAudioUnavailable {
    rethrow;
  } on TtsFailure catch (failure) {
    throw WordAudioUnavailable(
      ttsFailureText(failure, descriptor: descriptor),
      cause: failure,
    );
  } catch (error) {
    throw WordAudioUnavailable(
      t.audiobook_tts_failure_bad_response,
      cause: error,
    );
  } finally {
    await provider?.dispose();
  }
}
