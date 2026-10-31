/// 制卡**单词音频**的 TTS 兜底：用哪个声音（偏好）与怎么合成。
///
/// 兜底链（[LocalAudioEnhancement]）：本地 Yomitan 音频库 → 配置的音频源 → 这里。
/// 声音可选：
/// - 系统语音（默认，`TtsChannel.ttsToFile`，按文字语言自动挑声音：Android
///   TextToSpeech、iOS AVSpeechSynthesizer、Windows OneCore / SAPI、macOS say、
///   Linux Open JTalk / espeak-ng，一律出 WAV）；想固定引擎 / 声音就选一份系统语音预设；
/// - 用户在「朗读声音」里配置的任一预设（在线 / 本机服务 / 系统），经引擎注册表
///   取 provider，合成走全应用共用的 [TtsAudioCache]（同词同音色不重复合成）；
/// - 不使用 TTS 兜底。
///
/// 句子音频**不**做 TTS 兜底（BUG-172 结论），这里只服务单词音频。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show immersionMiningAudioExtension;
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show buildFfmpegAtempoFilter, retempoAudioFileViaFfmpeg;
import 'package:material_ui/material_ui.dart' show immutable;
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';

/// String：制卡单词音频的 TTS 兜底声音（[MiningTtsFallbackVoice.wire]）。
/// 值可能指向本机的声音预设（`tts_voice_presets` 是设备本地清单），所以与
/// `tts_active_preset_id` 同族：设备本地，不进 Profile 快照 / 备份 / 同步。
const String kMiningTtsFallbackVoicePref = 'mining_tts_fallback_voice';

/// double：TTS 兜底发音（查词 ♪ / 自动发音、制卡单词音频）的倍速，默认 1.0。
/// 范围同有声书倍速（[kTtsFallbackSpeedMin]..[kTtsFallbackSpeedMax]）。
const String kTtsFallbackSpeedPref = 'tts_fallback_speed';

/// TTS 兜底倍速下限 / 上限（与有声书倍速拖动条同一范围）。
const double kTtsFallbackSpeedMin = 0.25;
const double kTtsFallbackSpeedMax = 3.0;

/// 读 TTS 兜底倍速；坏值 / 越界夹回范围，非数字回落 1.0。
double ttsFallbackSpeedOf(PrefStore prefs) {
  final Object? raw = prefs.getPref(kTtsFallbackSpeedPref, defaultValue: 1.0);
  if (raw is! num || !raw.isFinite) return 1.0;
  return raw.toDouble().clamp(kTtsFallbackSpeedMin, kTtsFallbackSpeedMax);
}

Future<void> setTtsFallbackSpeed(PrefStore prefs, double speed) =>
    prefs.setPref(
      kTtsFallbackSpeedPref,
      speed.clamp(kTtsFallbackSpeedMin, kTtsFallbackSpeedMax),
    );

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

/// 查词播放（♪ / 自动发音）在全部音频源都没命中时用的兜底声音；null = 不兜底。
///
/// 与制卡兜底共用同一个偏好，但只认用户**显式选过**的声音：从没碰过这项设置
/// （空串，制卡按系统语音兜底的升级前行为）的用户，查词仍保持「只用音频源」，
/// 不会突然冒出系统语音。选了「不使用」同样不兜底。
MiningTtsFallbackVoice? lookupTtsFallbackVoiceOf(PrefStore prefs) {
  final Object? raw = prefs.getPref(
    kMiningTtsFallbackVoicePref,
    defaultValue: '',
  );
  if (raw is! String || raw.isEmpty) return null;
  final MiningTtsFallbackVoice choice = MiningTtsFallbackVoice.parse(raw);
  return choice.kind == MiningTtsFallbackKind.none ? null : choice;
}

Future<void> setMiningTtsFallbackVoice(
  PrefStore prefs,
  MiningTtsFallbackVoice voice,
) => prefs.setPref(kMiningTtsFallbackVoicePref, voice.wire);

/// 本平台制卡兜底用的系统语音引擎名（专有名词，不翻译）；null = 本平台没有。
///
/// 与 `TtsChannel.ttsToFile` / `ttsToFileDesktop` 的分派同一张表：Android / iOS 走
/// 原生，桌面走各 OS 自带引擎。「系统语音」这一项按文字语言自动挑声音；想固定某个
/// 引擎 / 声音，就建一份系统语音的朗读声音预设、在这里选那份预设。
String? systemTtsEngineName() {
  if (Platform.isAndroid) return 'Android TextToSpeech';
  if (Platform.isIOS) return 'iOS AVSpeechSynthesizer';
  if (Platform.isWindows) return 'Windows OneCore / SAPI';
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

/// 单词音频拿不到时的上报：记日志 + 决定要不要提示用户。
///
/// - 总是记错误日志（设置 › 诊断 › 错误日志可查）；
/// - [manual]（用户主动点的）：每次都弹带原因的提示；
/// - 自动触发且原因是**系统语音**（[SystemTtsFailure]：不支持该语言、没装语音
///   数据、没有引擎……）：这是设备配置问题，不提示的话用户只会看到卡片永远没有
///   单词发音、却不知道为什么（BUG-3669）。但批量 / 连续制卡时每张卡都会撞同一个
///   原因，所以**同一判据（[SystemTtsFailure.dedupeKey] = 原因 + 语言）在本进程
///   内只提示一次**；换了原因或语言会再提示；
/// - 自动触发的其它原因（选中的在线 / 本机声音服务失败）维持只记日志——它们按句
///   变化（网络抖动等），自动路径逐张弹会刷屏，手动预览时会带原因提示。
class WordAudioFailureReporter {
  WordAudioFailureReporter({required this.log, required this.notify});

  /// 生产实例：日志进 [ErrorLogService]，提示走 [FushiToast]。
  static WordAudioFailureReporter instance = WordAudioFailureReporter(
    log: (String tag, Object error, StackTrace stack) =>
        ErrorLogService.instance.log(tag, error, stack),
    notify: (String message) => FushiToast.show(
      msg: message,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
      severity: ToastSeverity.error,
    ),
  );

  final void Function(String tag, Object error, StackTrace stack) log;
  final void Function(String message) notify;

  final Set<String> _notifiedAutoKeys = <String>{};

  void report(
    WordAudioUnavailable error,
    StackTrace stack, {
    required bool manual,
  }) {
    // toString 带原因与底层错误码（TtsFailure 只含可公开诊断，不含正文 / 凭据）。
    log('LocalAudioEnhancement.ttsFallback', error, stack);
    if (manual) {
      notify(wordAudioUnavailableMessage(error));
      return;
    }
    final Object? cause = error.cause;
    if (cause is! SystemTtsFailure) return;
    if (!_notifiedAutoKeys.add(cause.dedupeKey)) return;
    notify(wordAudioUnavailableMessage(error));
  }
}

/// 统一的失败上报（见 [WordAudioFailureReporter]）。
void reportWordAudioUnavailable(
  WordAudioUnavailable error,
  StackTrace stack, {
  required bool manual,
}) => WordAudioFailureReporter.instance.report(error, stack, manual: manual);

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

/// 系统语音合成函数的形状（生产 = `TtsChannel.ttsToFile`）：成功返回写出的路径，
/// 失败抛 [SystemTtsFailure]。
typedef SystemTtsToFile =
    Future<String> Function(
      String text,
      String outputPath,
      String? languageTag,
    );

/// 整段变速的形状（生产 = [retempoAudioFileViaFfmpeg]）：成功返回 [outputPath]，
/// 失败返回 null（失败原因已由实现记进错误日志）。
typedef TtsFallbackRetempo =
    Future<String?> Function({
      required String inputPath,
      required String outputPath,
      required double tempo,
    });

Future<String?> _ffmpegRetempo({
  required String inputPath,
  required String outputPath,
  required double tempo,
}) => retempoAudioFileViaFfmpeg(
  inputPath: inputPath,
  outputPath: outputPath,
  tempo: tempo,
);

/// 兜底链第 3 步：按 [choice] 合成 [text] 的单词音频。
///
/// - 系统语音：`systemTts(text, <outputDir>/tts_term_audio.wav, languageTag)`，
///   [languageTag] 是要念的语言（[resolveSystemTtsLanguageTag] 的结果，null =
///   引擎默认语言）。失败抛带原因的 [WordAudioUnavailable]（cause 是
///   [SystemTtsFailure]），不再静默返回 null（BUG-3669）。
/// - 不使用：直接返回 null，不碰任何 TTS。
/// - 预设：经 [voices] 取引擎合成（走缓存），产物复制到 [outputDir] 下按缓存键
///   命名、扩展名随真实格式（wav / mp3）的文件——不同词互不覆盖。失败抛
///   [WordAudioUnavailable]，**不回退系统语音**。
///
/// [tempo]：倍速（变速不变调）。null / 1.0 原样返回合成产物；否则经 [retempo]
/// （ffmpeg atempo）另写一份 `<原名>_x<倍速>.<制卡音频扩展名>` 返回——三条播放
/// 后端（弹窗 `<audio>` / Android 原生 / 桌面 just_audio）与 Anki 卡片因此拿到同一份
/// 已变速的文件，不必各自实现倍速。变速失败（ffmpeg 缺失 / 编码失败，已记日志）时
/// 退回原速产物：发音照常可用，只是没变速。
Future<File?> synthesizeMiningTtsFallback({
  required String text,
  required MiningTtsFallbackVoice choice,
  required Directory outputDir,
  required SystemTtsToFile systemTts,
  required MiningTtsVoiceSource Function() voices,
  String? languageTag,
  double? tempo,
  TtsFallbackRetempo retempo = _ffmpegRetempo,
}) async {
  final File? source = await _synthesizeAtSourceSpeed(
    text: text,
    choice: choice,
    outputDir: outputDir,
    systemTts: systemTts,
    voices: voices,
    languageTag: languageTag,
  );
  if (source == null || tempo == null) return source;
  if (buildFfmpegAtempoFilter(tempo) == null) return source;
  final String name = p.basenameWithoutExtension(source.path);
  final File out = File(
    p.join(
      p.dirname(source.path),
      '${name}_x${tempo.toStringAsFixed(2)}.'
      '${immersionMiningAudioExtension()}',
    ),
  );
  // 预设产物按缓存键命名（同名 = 同词同音色），已变速过的直接复用；系统语音沿用
  // 固定文件名、每次内容都不同，必须重做。
  if (p.basename(source.path) != kSystemTtsTermAudioFileName &&
      await out.exists() &&
      await out.length() > 0) {
    return out;
  }
  final String? written = await retempo(
    inputPath: source.path,
    outputPath: out.path,
    tempo: tempo,
  );
  return written == null ? source : File(written);
}

Future<File?> _synthesizeAtSourceSpeed({
  required String text,
  required MiningTtsFallbackVoice choice,
  required Directory outputDir,
  required SystemTtsToFile systemTts,
  required MiningTtsVoiceSource Function() voices,
  String? languageTag,
}) async {
  switch (choice.kind) {
    case MiningTtsFallbackKind.none:
      return null;
    case MiningTtsFallbackKind.system:
      final String written;
      try {
        written = await systemTts(
          text,
          p.join(outputDir.path, kSystemTtsTermAudioFileName),
          languageTag,
        );
      } on SystemTtsFailure catch (failure) {
        throw WordAudioUnavailable(
          systemTtsFailureText(failure),
          cause: failure,
        );
      }
      final File file = File(written);
      if (file.existsSync()) return file;
      final SystemTtsFailure missing = SystemTtsFailure(
        SystemTtsFailureReason.synthesisFailed,
        languageTag: languageTag,
      );
      throw WordAudioUnavailable(systemTtsFailureText(missing), cause: missing);
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
