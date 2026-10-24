/// 系统语音（Android TextToSpeech / iOS AVSpeechSynthesizer / Windows OneCore·SAPI /
/// macOS say / Linux Open JTalk·espeak-ng）的**语言判据**与**失败类型**（BUG-3669）。
///
/// 以前这条通道写死日语：Android 引擎初始化只认 `Locale.JAPAN`、合成默认
/// `ja-JP`，没装日语语音数据的设备上整条通道静默返回 null，而且对学英语 / 韩语
/// 的用户一律按日语念。现在：
/// - 合成语言由 [resolveSystemTtsLanguageTag] 按明确的优先级决定，不假设日语；
/// - 失败一律抛 [SystemTtsFailure]（带原因与语言），由调用方记日志并提示用户，
///   不再静默。
library;

import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart'
    show contentLanguageLabelOf;

/// 系统语音失败的原因。
enum SystemTtsFailureReason {
  /// 本机没有可用的系统语音引擎（引擎初始化失败、平台没有实现、桌面没装引擎）。
  engineUnavailable,

  /// 引擎认识这个语言，但语音数据没装（Android `LANG_MISSING_DATA`）。
  languageMissingData,

  /// 引擎不支持这个语言（Android `LANG_NOT_SUPPORTED`、Windows / macOS 没有该
  /// 语言的声音、Linux 只有日语引擎而请求的是别的语言）。
  languageNotSupported,

  /// 用户在声音预设里点名的引擎声音不在了（卸载 / 换了设备 / 换了引擎）。不悄悄
  /// 换成别的声音：那就不是用户选的那个了。
  voiceUnavailable,

  /// 引擎可用、语言也支持，但这一次合成没产出音频。
  synthesisFailed,
}

/// 系统语音合成失败。是一种 [TtsFailure]（`code = unsupported`），所以走「朗读
/// 声音」体系的调用方（系统语音预设）不必另开一条错误通道；需要具体原因的地方按
/// 本类型取 [reason] / [languageTag]。
class SystemTtsFailure extends TtsFailure {
  SystemTtsFailure(this.reason, {this.languageTag})
    : super(
        TtsFailureCode.unsupported,
        'system ${reason.name}'
        '${languageTag == null ? '' : ' $languageTag'}',
      );

  /// 原生侧 `ttsToFile` 的错误码 → 原因。不认识的码按「合成失败」处理（不吞）。
  factory SystemTtsFailure.fromPlatformCode(String code, String? languageTag) =>
      SystemTtsFailure(switch (code) {
        'ENGINE_UNAVAILABLE' => SystemTtsFailureReason.engineUnavailable,
        'LANGUAGE_MISSING_DATA' => SystemTtsFailureReason.languageMissingData,
        'LANGUAGE_NOT_SUPPORTED' => SystemTtsFailureReason.languageNotSupported,
        'VOICE_UNAVAILABLE' => SystemTtsFailureReason.voiceUnavailable,
        _ => SystemTtsFailureReason.synthesisFailed,
      }, languageTag: languageTag);

  final SystemTtsFailureReason reason;

  /// 请求的语言（BCP-47）；null = 用引擎默认语言。
  final String? languageTag;

  /// 「同一个原因」的判据：原因 + 语言。批量制卡时同一判据只提示一次。
  String get dedupeKey => '${reason.name}|${languageTag ?? ''}';
}

/// 给用户看的一句原因（含「怎么办」）。
String systemTtsFailureText(SystemTtsFailure failure) {
  final String? tag = failure.languageTag;
  final String language = tag == null
      ? t.tts_system_language_default
      : contentLanguageLabelOf(tag);
  return switch (failure.reason) {
    SystemTtsFailureReason.engineUnavailable => t.tts_system_engine_unavailable,
    SystemTtsFailureReason.languageMissingData =>
      t.tts_system_language_missing_data(language: language),
    SystemTtsFailureReason.languageNotSupported =>
      t.tts_system_language_unsupported(language: language),
    SystemTtsFailureReason.voiceUnavailable => t.tts_system_voice_unavailable,
    SystemTtsFailureReason.synthesisFailed => t.tts_system_synthesis_failed,
  };
}

/// 本机已装词典声明的词头语言（[resolveSystemTtsLanguageTag] 的第 3 级判据）。
///
/// 全局装配点：AppModel 在词典仓库就位时接上（现读，不是快照）。拿不到 AppModel
/// 的调用方（「朗读声音」体系里的系统语音预设）经它取；没接上时为空，判据自然
/// 落到下一级。
Iterable<String?> Function() systemTtsDictionaryLanguages =
    _noDictionaryLanguages;

Iterable<String?> _noDictionaryLanguages() => const <String?>[];

/// 系统语音该用什么语言念 [text]（BCP-47 标签；null = 不指定，用引擎默认语言）。
///
/// 没有全局「学习语言」（AppModel.targetLanguage 已删），所以按下面的顺序取，
/// 前一级拿不到才看下一级：
/// 1. [dictionaryLanguage]：这次查词所用词典声明的词头语言
///    （`Dictionary.effectiveSourceLanguage`）——最直接的真值；
/// 2. [text] 本身的文字：含假名 = `ja`、含谚文 = `ko`。这两种文字各只属于一种
///    语言，是结构性证据；汉字（中 / 日共用）与拉丁字母（多语言共用）不算；
/// 3. [installedDictionaryLanguages]：已装词典声明的词头语言**只有一种**时用它
///    （只装了英语词典的用户查的就是英语）；有多种就分不出来，不猜；
/// 4. 都拿不到 → null：交给引擎默认语言（Android = 系统 TTS 当前语言，Windows /
///    macOS = 默认声音），**不**回落日语。
String? resolveSystemTtsLanguageTag({
  required String text,
  String? dictionaryLanguage,
  Iterable<String?> installedDictionaryLanguages = const <String?>[],
}) {
  final String? fromDictionary = _normalizedTag(dictionaryLanguage);
  if (fromDictionary != null) return fromDictionary;

  final String? fromScript = _unambiguousScriptLanguage(text);
  if (fromScript != null) return fromScript;

  final Set<String> primaries = <String>{};
  String? onlyTag;
  for (final String? raw in installedDictionaryLanguages) {
    final String? tag = _normalizedTag(raw);
    if (tag == null) continue;
    if (primaries.add(primaryLanguageSubtag(tag))) onlyTag = tag;
  }
  if (primaries.length == 1) return onlyTag;
  return null;
}

/// BCP-47 标签的主语言子标签（小写）：`zh-Hans` → `zh`、`ja-JP` → `ja`。
String primaryLanguageSubtag(String tag) =>
    tag.split(RegExp('[-_]')).first.toLowerCase();

String? _normalizedTag(String? raw) {
  final String trimmed = raw?.trim().replaceAll('_', '-') ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

String? _unambiguousScriptLanguage(String text) {
  for (final int rune in text.runes) {
    final bool kana =
        (rune >= 0x3041 && rune <= 0x309F) || // 平假名
        (rune >= 0x30A0 && rune <= 0x30FF) || // 片假名
        (rune >= 0x31F0 && rune <= 0x31FF) || // 片假名音标扩展
        (rune >= 0xFF66 && rune <= 0xFF9D); // 半角片假名
    if (kana) return 'ja';
    final bool hangul =
        (rune >= 0xAC00 && rune <= 0xD7A3) || // 谚文音节
        (rune >= 0x1100 && rune <= 0x11FF) || // 谚文字母
        (rune >= 0x3130 && rune <= 0x318F); // 谚文兼容字母
    if (hangul) return 'ko';
  }
  return null;
}
