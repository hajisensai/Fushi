/// 复习卡面朗读键（`[sound:fushi-tts:…]`，引擎侧 srs_card_tts.dart）的合成与**落盘缓存**：
/// 一段文字用一个声音合成过一次，之后复习直接播缓存，不再重新合成（拍板台 YmWT1x57XV：
/// 「这个朗读应该能做成保持下来下次背还能用上」）。
///
/// ## 缓存键与存放位置
///
/// - 键 = sha256(版本 + 要念的文字 + 声音身份 + 语言 + 倍速) 的前 40 位（[srsTtsCacheKey]）。
///   声音身份：朗读声音预设取引擎给的 `audioIdentity`（音色参数，不含凭据），系统语音取
///   「系统语音 + 本机平台」。换了声音 / 倍速 / 语言就是另一段音频；文字一样、声音一样就命中。
/// - 文件放进本 profile 的复习媒体库（`srs_media/<profile>/`），名字是
///   `_fushi_tts_<键>.<真实扩展名>`（[kSrsTtsCachePrefix]）。不进 LRU 的 TTS 合成缓存
///   （`TtsAudioCache`，有声书共用、512 MB 淘汰），所以背过的卡下次照样在。
///
/// ## 跨同步与备份
///
/// - **备份**：「复习」类别原样打包整个 `srs_media` 目录，缓存随备份走、恢复后直接可播。
/// - **同步 / 媒体位置**：只传笔记引用的媒体（`srsReferencedMedia`）。朗读键不写回笔记，
///   缓存文件没有笔记引用，所以**不同步**：别的设备第一次播时自己合成一次、之后同样命中自己的
///   缓存。这是有意的——系统语音的声音因设备而异（声音身份里带平台），同一个键在别的设备上
///   本来就对不上；也不为它改写笔记、制造编辑冲突。
/// - **媒体回收**：回收只删「被删笔记引用、且没有存活引用」的文件，没有笔记引用的缓存文件
///   不会进候选，不被回收；清理它们只能删掉媒体目录里 `_fushi_tts_` 开头的文件。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/srs_card_tts.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:meta/meta.dart' show immutable, visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/utils/misc/system_tts.dart'
    show resolveSystemTtsLanguageTag;
import 'package:fushi/src/utils/misc/tts_channel.dart';

/// 缓存文件名前缀（下划线开头：Anki 把这类文件当静态文件，「检查媒体」不删）。
const String kSrsTtsCachePrefix = '_fushi_tts_';

/// 合成产物可能的扩展名（系统语音出 wav；在线 / 本机服务出 mp3 等；变速后是制卡音频扩展名）。
const List<String> kSrsTtsCacheExtensions = <String>[
  'mp3',
  'wav',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'flac',
];

/// 一颗朗读键这次怎么念：用哪个声音、什么语言、几倍速。
@immutable
class SrsTtsPlan {
  const SrsTtsPlan({
    required this.text,
    required this.choice,
    required this.voiceIdentity,
    required this.languageTag,
    required this.tempo,
  });

  final String text;
  final MiningTtsFallbackVoice choice;

  /// 声音身份（进缓存键）。
  final Map<String, Object?> voiceIdentity;

  /// BCP-47（`ja-JP`）；null = 引擎默认语言。
  final String? languageTag;
  final double tempo;

  /// 缓存键（[srsTtsCacheKey]）。
  String get key => srsTtsCacheKey(
    text: text,
    voiceIdentity: voiceIdentity,
    languageTag: languageTag,
    tempo: tempo,
  );
}

/// 缓存键：sha256 的前 40 位十六进制。参数顺序无关（身份按键名排序后序列化）。
String srsTtsCacheKey({
  required String text,
  required Map<String, Object?> voiceIdentity,
  required String? languageTag,
  required double tempo,
}) {
  Object? canonical(Object? v) {
    if (v is Map) {
      final List<String> keys = <String>[for (final Object? k in v.keys) '$k']
        ..sort();
      return <String, Object?>{for (final String k in keys) k: canonical(v[k])};
    }
    if (v is List) return <Object?>[for (final Object? e in v) canonical(e)];
    return v;
  }

  final String json = jsonEncode(<String, Object?>{
    'v': 1,
    'text': text,
    'voice': canonical(voiceIdentity),
    'lang': languageTag,
    'tempo': tempo.toStringAsFixed(2),
  });
  return sha256.convert(utf8.encode(json)).toString().substring(0, 40);
}

/// Anki 语言代码（`ja_JP`）→ BCP-47（`ja-JP`）；空 / 不像语言代码的返回 null。
String? srsTtsLanguageTagOf(String? ankiLang) {
  final String s = (ankiLang ?? '').trim().replaceAll('_', '-');
  if (!RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(s)) return null;
  return s;
}

String _voiceKey(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), ' ');

/// 按 `voices=` 点名找朗读声音预设：预设 id 或名字（不分大小写，空格 / 下划线 / 连字符等同）。
/// 没点名或都对不上返回 null（用默认声音）。
TtsVoicePreset? srsTtsPresetNamed(
  List<String> voices,
  List<TtsVoicePreset> presets,
) {
  for (final String v in voices) {
    final String want = _voiceKey(v);
    for (final TtsVoicePreset preset in presets) {
      if (preset.id == v || _voiceKey(preset.name) == want) return preset;
    }
  }
  return null;
}

/// 决定一颗朗读键怎么念（纯函数，测试直接调）。
///
/// - 声音：`voices=` 点名的朗读声音预设优先；否则 [configured]（「TTS 兜底声音」），那项设成
///   「不使用」时按系统语音念——那项管的是查词 / 制卡的**自动**兜底，这里是卡面上明摆着的
///   朗读键（与编辑器「用 TTS 生成」同一口径）。
/// - 语言：标签的 `lang=` 优先，否则 [detectLanguage]（按文字与已装词典判）。
/// - 倍速：标签的 `speed=` 优先，否则 [defaultTempo]（TTS 兜底倍速），夹到合法范围。
SrsTtsPlan srsTtsPlanOf(
  SrsTtsSound sound, {
  required MiningTtsFallbackVoice configured,
  required List<TtsVoicePreset> presets,
  required Map<String, Object?> Function(TtsVoicePreset preset) identityOf,
  required double defaultTempo,
  required String? Function(String text) detectLanguage,
  String platform = '',
}) {
  final TtsVoicePreset? named = srsTtsPresetNamed(sound.voices, presets);
  final MiningTtsFallbackVoice choice = named != null
      ? MiningTtsFallbackVoice.preset(named.id)
      : configured.kind == MiningTtsFallbackKind.none
      ? const MiningTtsFallbackVoice.system()
      : configured;
  final TtsVoicePreset? preset = choice.kind == MiningTtsFallbackKind.preset
      ? presets.where((TtsVoicePreset x) => x.id == choice.presetId).firstOrNull
      : null;
  final Map<String, Object?> identity =
      choice.kind == MiningTtsFallbackKind.preset
      ? <String, Object?>{
          'preset': preset == null
              ? <String, Object?>{'id': choice.presetId}
              : identityOf(preset),
        }
      : <String, Object?>{'system': platform};
  return SrsTtsPlan(
    text: sound.text,
    choice: choice,
    voiceIdentity: identity,
    languageTag: srsTtsLanguageTagOf(sound.lang) ?? detectLanguage(sound.text),
    tempo: (sound.speed ?? defaultTempo).clamp(
      kTtsFallbackSpeedMin,
      kTtsFallbackSpeedMax,
    ),
  );
}

/// 媒体库里这个键已有的缓存文件；没有返回 null。
Future<File?> srsTtsCachedFile(SrsMediaStore store, String key) async {
  for (final String ext in kSrsTtsCacheExtensions) {
    final File f = File(
      p.join(store.root.path, '$kSrsTtsCachePrefix$key.$ext'),
    );
    if (await f.exists() && await f.length() > 0) return f;
  }
  return null;
}

/// 把合成产物 [source] 落进媒体库（先写临时文件再改名，进程中途被杀不留半截文件）。
Future<File> srsTtsStoreCached(
  SrsMediaStore store,
  String key,
  File source,
) async {
  String ext = p.extension(source.path).replaceFirst('.', '').toLowerCase();
  if (!kSrsTtsCacheExtensions.contains(ext)) ext = 'wav';
  await store.root.create(recursive: true);
  final File target = File(
    p.join(store.root.path, '$kSrsTtsCachePrefix$key.$ext'),
  );
  final File tmp = File(
    '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  await source.copy(tmp.path);
  try {
    await tmp.rename(target.path);
  } on FileSystemException {
    // 另一路合成同时落了同一个键（Windows 上目标已存在时改名失败）：留现有的。
    if (await tmp.exists()) await tmp.delete();
    if (!await target.exists()) rethrow;
  }
  return target;
}

/// 合成函数的形状（生产 = [synthesizeMiningTtsFallback] 接系统语音与朗读声音预设）。
typedef SrsTtsSynthesize =
    Future<File?> Function(SrsTtsPlan plan, Directory outputDir);

/// 朗读键 → 本地音频文件：命中缓存直接给，否则合成、落盘、再给。
class SrsCardTtsAudio {
  SrsCardTtsAudio({
    required SrsTtsPlan Function(SrsTtsSound sound) plan,
    required SrsTtsSynthesize synthesize,
    required Future<Directory> Function() scratch,
  }) : _plan = plan,
       _synthesize = synthesize,
       _scratch = scratch;

  /// 生产实例：声音 / 倍速读 [prefs]，系统语音按文字与 [dictionaryLanguages]（已装词典的词头
  /// 语言）判语言，合成走系统语音或朗读声音预设。参数注入而不是拿 AppModel：本文件不进 AppModel
  /// 的 import 环（test/build/import_cycle_guard_test.dart）。
  factory SrsCardTtsAudio.of({
    required PrefStore prefs,
    required List<String?> Function() dictionaryLanguages,
  }) {
    TtsServices services() => TtsServices.of(prefs);
    return SrsCardTtsAudio(
      plan: (SrsTtsSound sound) => srsTtsPlanOf(
        sound,
        configured: miningTtsFallbackVoiceOf(prefs),
        presets: services().store.loadPresets(),
        identityOf: (TtsVoicePreset preset) {
          final TtsProviderDescriptor? d =
              services().registry[preset.providerId];
          return d == null
              ? <String, Object?>{
                  'id': preset.id,
                  'provider': preset.providerId,
                  'revision': preset.revision,
                }
              : d.audioIdentity(preset);
        },
        defaultTempo: ttsFallbackSpeedOf(prefs),
        detectLanguage: (String text) => resolveSystemTtsLanguageTag(
          text: text,
          installedDictionaryLanguages: dictionaryLanguages(),
        ),
        platform: Platform.operatingSystem,
      ),
      synthesize: (SrsTtsPlan plan, Directory outputDir) =>
          synthesizeMiningTtsFallback(
            text: plan.text,
            choice: plan.choice,
            outputDir: outputDir,
            languageTag: plan.languageTag,
            systemTts: (String text, String outputPath, String? languageTag) =>
                TtsChannel.instance.ttsToFile(
                  text,
                  outputPath,
                  languageTag: languageTag,
                ),
            voices: () => miningTtsVoiceSourceOf(services()),
            tempo: plan.tempo,
          ),
      scratch: () async =>
          Directory(p.join(Directory.systemTemp.path, 'fushi_srs_tts')),
    );
  }

  final SrsTtsPlan Function(SrsTtsSound sound) _plan;
  final SrsTtsSynthesize _synthesize;
  final Future<Directory> Function() _scratch;

  /// 进行中的合成（按「媒体库目录 + 键」）：自动播放与用户点按同时要同一段时只合成一次。
  final Map<String, Future<File?>> _inFlight = <String, Future<File?>>{};

  @visibleForTesting
  int get inFlightCount => _inFlight.length;

  /// [sound] 的本地音频文件。合成失败抛 [WordAudioUnavailable]（带给用户看的原因）；
  /// 声音设成不出声（返回 null）时返回 null。
  Future<File?> fileFor(SrsTtsSound sound, SrsMediaStore store) async {
    final SrsTtsPlan plan = _plan(sound);
    final String key = plan.key;
    final File? hit = await srsTtsCachedFile(store, key);
    if (hit != null) return hit;
    final String slot = '${store.root.path}|$key';
    return _inFlight[slot] ??= _create(plan, key, store).whenComplete(() {
      // 不能写成 `=> _inFlight.remove(slot)`：remove 交回的正是这个 Future，whenComplete 会等它
      // 自己完成，永远等不到。
      _inFlight.remove(slot);
    });
  }

  Future<File?> _create(
    SrsTtsPlan plan,
    String key,
    SrsMediaStore store,
  ) async {
    // 每个键一个临时目录：系统语音的输出文件名是固定的，并发合成不能写同一个文件。
    final Directory out = Directory(p.join((await _scratch()).path, key));
    try {
      final File? made = await _synthesize(plan, out);
      if (made == null || !await made.exists() || await made.length() == 0) {
        return null;
      }
      return await srsTtsStoreCached(store, key, made);
    } finally {
      if (await out.exists()) {
        try {
          await out.delete(recursive: true);
        } on FileSystemException {
          // 临时目录删不掉（Windows 上仍被占用）：留给系统临时目录清理。
        }
      }
    }
  }
}

/// 卡面发音名 [name] 若是朗读键（`fushi-tts:`）：合成 / 取缓存后返回本地文件。
///
/// - 不是朗读键：返回 null，调用方照常按媒体库文件名找；
/// - 合成失败：上报（[manual] = 用户点的，带原因提示；自动播放按 [reportWordAudioUnavailable]
///   的口径只记日志 / 系统语音同一原因提示一次），返回 [SrsTtsResolution.failed]。
Future<SrsTtsResolution> srsResolveTtsSound(
  SrsCardTtsAudio audio,
  SrsMediaStore? store,
  String name, {
  required bool manual,
}) async {
  final SrsTtsSound? sound = SrsTtsSound.parse(name);
  if (sound == null) return const SrsTtsResolution.notTts();
  if (store == null) return const SrsTtsResolution.failed();
  try {
    final File? file = await audio.fileFor(sound, store);
    return file == null
        ? const SrsTtsResolution.failed()
        : SrsTtsResolution.file(file);
  } on WordAudioUnavailable catch (e, stack) {
    reportWordAudioUnavailable(e, stack, manual: manual);
    return const SrsTtsResolution.failed();
  }
}

/// [srsResolveTtsSound] 的结果。
@immutable
class SrsTtsResolution {
  const SrsTtsResolution.notTts() : isTts = false, file = null;
  const SrsTtsResolution.failed() : isTts = true, file = null;
  const SrsTtsResolution.file(File this.file) : isTts = true;

  /// 名字是朗读键。
  final bool isTts;

  /// 合成 / 缓存好的文件；朗读键但拿不到时为 null。
  final File? file;
}
