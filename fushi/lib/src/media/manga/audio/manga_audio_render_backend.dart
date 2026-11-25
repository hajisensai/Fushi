/// [MangaRenderBackend] 的 app 实现：TTS 缓存 + 引擎实例 + ffmpeg。
///
/// - 声音 = 声音预设 id；每份预设只解析一次。预设缺失 / 引擎不可用 / 参数不完整是
///   **这一句**的失败（`voice_missing` / `voice_unavailable` / `voice_incomplete`），
///   进未配音账本，可以换声音补回，不让整卷失败；
/// - 每个片段经 [TtsAudioCache] 合成（键 = 音色身份 + 生效的演出参数 + 片段文字），
///   在线引擎的临时失败走 [ttsWithRetry]；同一份预设同时在途的请求不超过它的并发上限；
/// - 一句的各片段用 ffmpeg 拼成一个 m4a，同时裁掉首尾静音（停顿只由时间表给，设计
///   §7），统一 44.1 kHz 单声道 AAC；有声书片段按 cue 边界剪，同样裁首尾静音，再加
///   极短的淡入淡出（cue 边界不准时不出咔嗒声）；合成句与有声书片段都归一到同一个
///   响度（[kMangaLoudnessFilter]），换音源时音量不跳；
/// - 克隆旁白（`manga_audio_narrator.dart`）：参考片段剪成 WAV 放进缓存目录，按声音包
///   同一条 Irodori 管线登记成虚拟预设（[mangaNarratorPreset]），合成走 [prepare] 的
///   批处理；
/// - 占位静音直接写 PCM WAV（精确时长，不经 ffmpeg）；
/// - 声音包（`pack:<packId>/<group>`，Irodori v4-Large 批处理 worker）：整卷开跑前
///   [prepare] 把这次要新出、缓存里没有的片段整批交给 worker（worker 按参考音频组
///   排序、模型只加载一次），种子与短句定长随请求下发（`TtsDirectedSynthesis`）；
///   批里失败的片段记下，逐句合成时抛一句级失败 → 占位 + 未配音账本。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack_provider.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_silence.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:fushi_engine/tts/tts_reject_split.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart'
    show kTtsOutputSampleRate;
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart'
    show readMp4PresentationDurationMs;
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_voices.dart'
    show TtsRenderGate;
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';

/// 首尾静音判据：低于 −50 dB 持续 50 ms 以上算静音。
const String kMangaTrimFilter =
    'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,'
    'areverse,'
    'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,'
    'areverse';

/// 响度归一：合成句与有声书片段统一到 −18 LUFS（真峰值 −1.5 dBTP），两种音源相邻时
/// 音量一致。loudnorm 内部会升采样，所以后面必须再 `aresample` 回输出采样率。
const String kMangaLoudnessFilter = 'loudnorm=I=-18:TP=-1.5:LRA=11';

/// 有声书片段首尾各 15 ms 的淡入淡出（尾部用倒放后的淡入实现，不需要知道时长）。
const String kMangaEdgeFadeFilter =
    'afade=t=in:d=0.015,areverse,afade=t=in:d=0.015,areverse';

/// 一句 / 一段片段整形的公共尾巴：裁首尾静音 →（片段）淡入淡出 → 响度归一 → 回到
/// 输出采样率。
String _mangaShapeChain({required bool fade}) => <String>[
  kMangaTrimFilter,
  if (fade) kMangaEdgeFadeFilter,
  kMangaLoudnessFilter,
  'aresample=$kTtsOutputSampleRate',
].join(',');

/// 一句 / 有声书片段的输出编码：单声道 AAC 96k 的 MP4 容器。
const List<String> _kMangaLineCodecArgs = <String>[
  '-ac',
  '1',
  '-c:a',
  'aac',
  '-b:a',
  '96k',
  '-f',
  'mp4',
];

/// 整形版本（[MangaRenderBackend.shapeVersion]）：出音频的三个 ffmpeg 参数构造器
/// （[buildMangaLineEncodeArgs] 合成句、[buildMangaClipArgs] 有声书片段、
/// [buildMangaNarratorRefArgs] 旁白参考音频）在固定取样输入下的完整输出的指纹。
/// 拼接前的统一采样 / 声道、裁静音 / 淡变 / 响度、采样率、编码任何一项变了，它都会
/// 跟着变，存量演出重生成时旧音频不再原样沿用（与新出的句子同一套处理），旁白参考
/// 音频也按新版本重剪。不用手动维护的版本号：参数就是版本。
final String kMangaShapeVersion = mangaShapeFingerprint(<List<String>>[
  buildMangaLineEncodeArgs(
    inputs: const <String>['in0', 'in1'],
    outputPath: 'out',
  ),
  buildMangaClipArgs(
    sourcePath: 'in',
    startMs: 0,
    endMs: 1000,
    outputPath: 'out',
    shapeAsLine: true,
  ),
  buildMangaNarratorRefArgs(
    sourcePath: 'in',
    startMs: 0,
    endMs: 1000,
    outputPath: 'out',
  ),
]);

/// [argLists]（各 ffmpeg 参数表）的 12 位十六进制 sha1 指纹；参数里不会出现的控制字符
/// 作分隔，参数边界不同的两组不会撞成同一串。纯函数，单测覆盖。
String mangaShapeFingerprint(List<List<String>> argLists) => sha1
    .convert(
      utf8.encode(
        argLists.map((List<String> args) => args.join('\u0001')).join('\u0002'),
      ),
    )
    .toString()
    .substring(0, 12);

/// 旁白参考音频的文件名：片段身份 + 整形版本（整形参数变了就是另一个文件，Irodori 的
/// 缓存键含参考音频路径，于是合成句也跟着重出）。
String mangaNarratorRefFileName(MangaAudiobookClip clip) =>
    '${mangaNarratorRefName(clip)}.$kMangaShapeVersion.wav';

/// [fileName] 是不是旧整形版本留下的旁白参考音频（含整形版本出现之前、文件名里没有
/// 版本的那批）；`.part` 等在写的临时文件不算。
bool isStaleMangaNarratorRef(String fileName) =>
    fileName.endsWith('.wav') && !fileName.endsWith('.$kMangaShapeVersion.wav');

/// 一句（[inputs] 是它的各片段，按顺序）编码成 m4a 的 ffmpeg 参数：每个输入先统一成
/// 44.1 kHz 单声道再拼接，拼完裁首尾静音、归一响度。纯函数，单测覆盖。
List<String> buildMangaLineEncodeArgs({
  required List<String> inputs,
  required String outputPath,
}) {
  final StringBuffer graph = StringBuffer();
  for (int i = 0; i < inputs.length; i++) {
    graph.write(
      '[$i:a]aresample=$kTtsOutputSampleRate,'
      'aformat=sample_fmts=fltp:channel_layouts=mono[a$i];',
    );
  }
  for (int i = 0; i < inputs.length; i++) {
    graph.write('[a$i]');
  }
  graph.write(
    'concat=n=${inputs.length}:v=0:a=1[c];[c]${_mangaShapeChain(fade: false)}'
    '[out]',
  );
  return <String>[
    '-y',
    for (final String input in inputs) ...<String>['-i', input],
    '-filter_complex',
    graph.toString(),
    '-map',
    '[out]',
    '-vn',
    ..._kMangaLineCodecArgs,
    outputPath,
  ];
}

/// 从有声书文件（或广播剧 / 动画音轨）剪 `[startMs, endMs)` 的 ffmpeg 参数（`-ss` 放在
/// `-i` 前：音频按解码精确定位）。[endMs] 为 null = 剪到文件末尾（音轨最后一段）。
/// 视频文件只取音轨（`-vn`）。纯函数，单测覆盖。
///
/// [shapeAsLine] = 这段要和合成句排在一起（漫画有声的有声书片段）：裁首尾静音、加
/// 淡入淡出、归一响度，与合成句同一套整形。广播剧音轨按时间铺满整条音轨，段与段
/// 首尾相接，**不能**整形（会吃掉段间的声音、各段响度各自归一会忽大忽小），保持默认。
List<String> buildMangaClipArgs({
  required String sourcePath,
  required int startMs,
  required int? endMs,
  required String outputPath,
  bool shapeAsLine = false,
}) => <String>[
  '-y',
  '-ss',
  (startMs / 1000).toStringAsFixed(3),
  if (endMs != null) ...<String>[
    '-t',
    ((endMs - startMs) / 1000).toStringAsFixed(3),
  ],
  '-i',
  sourcePath,
  '-vn',
  '-af',
  shapeAsLine
      ? _mangaShapeChain(fade: true)
      : 'aresample=$kTtsOutputSampleRate',
  ..._kMangaLineCodecArgs,
  outputPath,
];

/// 克隆旁白的一段参考音频：从有声书剪 `[startMs, endMs)`，与有声书片段同一套整形，
/// 写 16 bit PCM WAV（参考音频交给 Irodori，不经有损编码）。纯函数，单测覆盖。
List<String> buildMangaNarratorRefArgs({
  required String sourcePath,
  required int startMs,
  required int endMs,
  required String outputPath,
}) => <String>[
  '-y',
  '-ss',
  (startMs / 1000).toStringAsFixed(3),
  '-t',
  ((endMs - startMs) / 1000).toStringAsFixed(3),
  '-i',
  sourcePath,
  '-vn',
  '-af',
  _mangaShapeChain(fade: true),
  '-ac',
  '1',
  '-c:a',
  'pcm_s16le',
  '-f',
  'wav',
  outputPath,
];

/// 旁白声音的虚拟预设：走声音包同一条 Irodori 管线（引擎 id [kIrodoriPackProviderId]，
/// 不挂 LoRA，参考音频 = [refFiles]，采样参数取默认）。[refFiles] 与
/// [MangaNarratorVoice.refs] 一一对应。缓存键含参考音频路径，路径由片段决定，片段
/// 不变缓存就一直命中。
TtsVoicePreset mangaNarratorPreset(
  MangaNarratorVoice narrator,
  List<String> refFiles,
) {
  const IrodoriSampling sampling = IrodoriSampling();
  return TtsVoicePreset(
    id: narrator.id,
    providerId: kIrodoriPackProviderId,
    name: 'narrator',
    params: <String, String>{
      IrodoriPackParams.pack: 'manga-narrator',
      IrodoriPackParams.group: narrator.id,
      IrodoriPackParams.character: 'narrator',
      IrodoriPackParams.adapter: '',
      IrodoriPackParams.refs: jsonEncode(refFiles),
      IrodoriPackParams.steps: '${sampling.steps}',
      IrodoriPackParams.cfgText: '${sampling.cfgText}',
      IrodoriPackParams.cfgSpeaker: '${sampling.cfgSpeaker}',
      IrodoriPackParams.seed: '${sampling.seed}',
    },
  );
}

/// 参考音频放在 TTS 缓存根下的这个子目录（文件名 = [mangaNarratorRefFileName]）。
const String kMangaNarratorRefDirName = '.manga_narrator';

/// 一次 ffmpeg 没进度多久算卡死。
const Duration kMangaEncodeStallTimeout = Duration(seconds: 60);

class _MangaVoice {
  const _MangaVoice({
    required this.preset,
    required this.provider,
    required this.identity,
    required this.gate,
  });

  final TtsVoicePreset preset;
  final TtsProvider provider;
  final Map<String, Object?> identity;
  final TtsRenderGate gate;

  /// 声音包虚拟预设（走批处理 worker）。
  bool get isVoicePack => preset.providerId == kIrodoriPackProviderId;

  TtsDirectionSupport get support => ttsDirectionSupportOf(provider);

  /// 一个片段实际下发的演出参数（只含引擎支持的字段；不能表达情绪的引擎把情绪折成
  /// 语速 / 音高 / 音量）。[line] 是这句标注的演出（情绪 / 强度 / 语气说明 / 偏移）。
  /// 短句定长只给不挂 LoRA 的声音（handoff：挂 LoRA 的时长预测可靠）。
  TtsDirection directionFor(String segment, int seed, CastLineDirection line) {
    final TtsDirectionSupport s = support;
    return effectiveTtsDirection(
      s,
      TtsDirection.fromLine(
        line,
        seed: seed,
        durationSeconds: irodoriManualSeconds(segment, lora: s.adapter),
      ),
    );
  }

  /// 这句生效的演出指纹（与片段无关的部分；见 `mangaDirectionKey`）。
  String? directionKey(CastLineDirection line) => mangaDirectionKey(
    effectiveTtsDirection(support, TtsDirection.fromLine(line)),
  );

  /// 片段的缓存键（音色身份 + 生效的演出参数 + 文字）。
  String cacheKey(String segment, TtsDirection direction) =>
      TtsAudioCache.keyFor(<String, Object?>{
        ...identity,
        ...direction.cacheIdentity,
      }, segment);
}

class AppMangaRenderBackend implements MangaRenderBackend {
  /// 依赖都显式注入（app 侧由 [AppMangaRenderBackend.fromServices] 从 [TtsServices]
  /// 取）：[descriptorOf] = 制作侧按引擎 id 查描述符，[host] = 建引擎实例的宿主，
  /// [batchWorker] = 声音包批处理 worker。
  AppMangaRenderBackend({
    required TtsProviderDescriptor? Function(String providerId) descriptorOf,
    required TtsHost host,
    required IrodoriBatchWorker batchWorker,
    required TtsAudioCache cache,
    required FfmpegBackend ffmpeg,
    required void Function(String source, String summary) log,
    required List<TtsVoicePreset> presets,
    Map<String, List<String>> clipSources = const <String, List<String>>{},
  }) : _descriptorOf = descriptorOf,
       _host = host,
       _cache = cache,
       _ffmpeg = ffmpeg,
       _log = log,
       _presets = presets,
       _batchWorker = batchWorker,
       _clipSources = clipSources;

  /// 用 app 的 TTS 单例装配（引擎注册表 + 声音包 + 本机 Irodori 的 worker）。
  factory AppMangaRenderBackend.fromServices({
    required TtsServices tts,
    required TtsAudioCache cache,
    required FfmpegBackend ffmpeg,
    required void Function(String source, String summary) log,
    required List<TtsVoicePreset> presets,
    Map<String, List<String>> clipSources = const <String, List<String>>{},
  }) => AppMangaRenderBackend(
    descriptorOf: tts.productionDescriptor,
    host: tts.host,
    batchWorker: tts.localIrodori.batchWorker,
    cache: cache,
    ffmpeg: ffmpeg,
    log: log,
    presets: presets,
    clipSources: clipSources,
  );

  final TtsProviderDescriptor? Function(String providerId) _descriptorOf;
  final TtsHost _host;
  final TtsAudioCache _cache;
  final FfmpegBackend _ffmpeg;
  final void Function(String source, String summary) _log;

  /// 制作侧可选的全部声音（`ttsProductionPresets`：声音预设 + 声音包虚拟预设）。
  final List<TtsVoicePreset> _presets;
  final IrodoriBatchWorker _batchWorker;

  /// [prepare] 里批量合成失败的片段（缓存键 → 一句级失败）。
  final Map<String, MangaLineFailure> _batchFailures =
      <String, MangaLineFailure>{};

  /// [prepare] 批量写进缓存、在 [dispose] 前一直 pin 住的键（免得被后续发布挤掉）。
  final Set<String> _batchPinned = <String>{};
  static int _batchSeq = 0;

  /// 关联有声书 bookKey → 它的音频文件（绝对路径，按 `audioFilesInCueOrder`，即
  /// `MangaAudiobookClip.fileIndex` 的坐标）；没有条目 = 没关联或已不在书库。
  final Map<String, List<String>> _clipSources;

  final Map<String, Future<_MangaVoice>> _voices =
      <String, Future<_MangaVoice>>{};

  /// [prepareNarrator] 登记的旁白虚拟预设（声音 id → 预设）。
  final Map<String, TtsVoicePreset> _narrators = <String, TtsVoicePreset>{};

  /// 各引擎自己的并发上限在 [_MangaVoice.gate] 里管；这里只是同时在出的句数（含
  /// 编码），给 4 句足以让在线引擎跑满、又不至于同时起太多 ffmpeg。
  @override
  int get parallelism => 4;

  @override
  String get shapeVersion => kMangaShapeVersion;

  Future<_MangaVoice> _voice(String presetId) =>
      _voices[presetId] ??= _resolve(presetId);

  Future<_MangaVoice> _resolve(String presetId) async {
    TtsVoicePreset? preset = _narrators[presetId];
    if (preset == null) {
      for (final TtsVoicePreset candidate in _presets) {
        if (candidate.id == presetId) preset = candidate;
      }
    }
    if (preset == null) throw const MangaLineFailure('voice_missing');
    final TtsProviderDescriptor? descriptor = _descriptorOf(preset.providerId);
    if (descriptor == null || !descriptor.isAvailable) {
      throw const MangaLineFailure('voice_unavailable');
    }
    if (descriptor.validate(preset).isNotEmpty) {
      throw const MangaLineFailure('voice_incomplete');
    }
    return _MangaVoice(
      preset: preset,
      provider: descriptor.create(preset, _host),
      identity: descriptor.audioIdentity(preset),
      gate: TtsRenderGate(ttsEffectiveConcurrency(descriptor, preset)),
    );
  }

  bool _narratorRefsSwept = false;

  /// 删掉旧整形版本的旁白参考音频（新版本按 [mangaNarratorRefFileName] 另存，旧文件
  /// 不会再被引用；TTS 缓存的 `clear` 不进子目录，不在这里删就永远留着）。每个后端
  /// 实例只扫一次；删不掉（Windows 上被占用）记日志，下次再删。
  Future<void> _sweepStaleNarratorRefs(Directory dir) async {
    if (_narratorRefsSwept) return;
    _narratorRefsSwept = true;
    await for (final FileSystemEntity e in dir.list()) {
      if (e is! File || !isStaleMangaNarratorRef(p.basename(e.path))) continue;
      try {
        await e.delete();
      } on FileSystemException catch (err) {
        _log('MangaRender.narrator', 'stale reference kept: ${err.osError}');
      }
    }
  }

  /// 本机 Irodori 批处理环境就绪（声音包描述符可用）才能克隆旁白。
  @override
  bool get canCloneNarrator =>
      _descriptorOf(kIrodoriPackProviderId)?.isAvailable ?? false;

  @override
  Future<bool> prepareNarrator({
    required MangaNarratorVoice narrator,
    required TtsRenderCancelToken cancel,
  }) async {
    if (_narrators.containsKey(narrator.id)) return true;
    final Directory dir = Directory(
      p.join(_cache.root.path, kMangaNarratorRefDirName),
    );
    final List<String> refFiles = <String>[];
    try {
      await dir.create(recursive: true);
      await _sweepStaleNarratorRefs(dir);
      for (final MangaAudiobookClip clip in narrator.refs) {
        final File out = File(p.join(dir.path, mangaNarratorRefFileName(clip)));
        if (!await out.exists()) {
          final List<String>? sources = clip.bookKey == null
              ? null
              : _clipSources[clip.bookKey];
          if (sources == null ||
              clip.fileIndex >= sources.length ||
              !await File(sources[clip.fileIndex]).exists()) {
            throw const MangaLineFailure('clip_source_missing');
          }
          final File part = File('${out.path}.part');
          await _runFfmpeg(
            buildMangaNarratorRefArgs(
              sourcePath: sources[clip.fileIndex],
              startMs: clip.startMs,
              endMs: clip.endMs,
              outputPath: part.path,
            ),
            outputPath: part.path,
            cancel: cancel,
            source: 'MangaRender.narratorRef',
          );
          await part.rename(out.path);
        }
        refFiles.add(out.path);
      }
    } on MangaLineFailure catch (e) {
      cancel.throwIfCancelled();
      // 剪不出参考音频：本次不克隆，合成句照旧用各自的声音（不让整卷失败）。
      _log('MangaRender.narrator', 'reference unavailable: ${e.code}');
      return false;
    } on FileSystemException catch (e) {
      cancel.throwIfCancelled();
      _log('MangaRender.narrator', 'reference unavailable: ${e.osError}');
      return false;
    }
    _narrators[narrator.id] = mangaNarratorPreset(narrator, refFiles);
    return true;
  }

  /// 声音包的句子整批交给 worker（见库注释）。其余引擎逐句合成，这里不管。
  @override
  Future<void> prepare({
    required List<MangaRenderItem> items,
    required TtsRenderCancelToken cancel,
  }) async {
    final Map<String, IrodoriBatchItem> batch = <String, IrodoriBatchItem>{};
    final Directory scratch = Directory(
      p.join(_cache.root.path, '.irodori_batch', 'm${_batchSeq++}'),
    );
    for (final MangaRenderItem item in items) {
      if (item.source case MangaRenderSynth(
        :final String voice,
        :final int seed,
        :final List<String> segments,
        direction: final CastLineDirection line,
      )) {
        final _MangaVoice v;
        try {
          v = await _voice(voice);
        } on MangaLineFailure {
          continue; // 声音解析失败由逐句合成报成这一句的失败。
        }
        if (!v.isVoicePack) continue;
        for (final String segment in segments) {
          // 纯标点片段不送引擎：逐句合成时由 ttsSynthesizeSplittingOnReject 写静音。
          if (ttsTextIsSilent(segment)) continue;
          final TtsDirection direction = v.directionFor(segment, seed, line);
          final String key = v.cacheKey(segment, direction);
          if (batch.containsKey(key) || await _cache.lookup(key) != null) {
            continue;
          }
          final IrodoriBatchItem? base = irodoriBatchItemFromPreset(
            v.preset,
            id: key,
            text: segment,
            outputPath: p.join(scratch.path, '$key.wav'),
          );
          if (base == null) continue; // 参数坏了：逐句合成报 notConfigured。
          batch[key] = irodoriDirectedItem(base, direction);
        }
      }
    }
    if (batch.isEmpty) return;
    await scratch.create(recursive: true);
    final TtsCancelToken ttsCancel = TtsCancelToken();
    cancel.onCancel(ttsCancel.cancel);
    try {
      final IrodoriBatchResult result = await _batchWorker.run(
        IrodoriBatchJob(
          id: p.basename(scratch.path),
          items: batch.values.toList(),
        ),
        cancel: ttsCancel,
      );
      cancel.throwIfCancelled();
      final IrodoriBatchFailure? failure = result.failure;
      for (final String key in batch.keys) {
        final IrodoriBatchLineResult? line = result.lines[key];
        final String? out = line?.outputPath;
        if (line != null && line.ok && out != null) {
          try {
            _cache.pin(key);
            _batchPinned.add(key);
            await _cache.obtain(key, (String target) async {
              await File(out).rename(target);
              return const TtsResult(format: TtsAudioFormat.wav);
            });
          } on TtsFailure catch (e) {
            _batchFailures[key] = MangaLineFailure('tts_${e.code.name}');
          }
          continue;
        }
        // worker 起不来 / 中途退出：整批没出的片段都是这一句的失败（不悄悄漏掉）。
        _batchFailures[key] = switch (failure) {
          IrodoriBatchFailure.notInstalled => const MangaLineFailure(
            'tts_notConfigured',
            'notInstalled',
          ),
          final IrodoriBatchFailure f => MangaLineFailure(
            'tts_serverError',
            f.name,
          ),
          // 异常原文只进 worker 日志尾（可能带文本片段），账本只记错误码。
          null => MangaLineFailure(
            'tts_rejected',
            line?.error == 'worker_exited' ? 'worker_exited' : null,
          ),
        };
      }
    } finally {
      try {
        if (await scratch.exists()) await scratch.delete(recursive: true);
      } on FileSystemException catch (e) {
        _log('MangaRender.batch', 'scratch cleanup failed: ${e.osError}');
      }
    }
  }

  /// 释放引擎实例（任务结束时调用）。
  Future<void> dispose() async {
    for (final String key in _batchPinned) {
      _cache.unpin(key);
    }
    _batchPinned.clear();
    for (final Future<_MangaVoice> f in _voices.values) {
      try {
        await (await f).provider.dispose();
      } on MangaLineFailure {
        // 解析失败的声音没有实例可放。
      }
    }
    _voices.clear();
  }

  @override
  Future<String?> directionKey({
    required String voice,
    required CastLineDirection direction,
  }) async {
    try {
      return (await _voice(voice)).directionKey(direction);
    } on MangaLineFailure {
      // 声音解析不了：这句反正出不了新音频，按「没有生效的演出」比对，不为此丢掉旧音频。
      return null;
    }
  }

  @override
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required CastLineDirection direction,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    final _MangaVoice v = await _voice(voice);
    final CastLineDirection line = direction;
    final TtsCancelToken ttsCancel = TtsCancelToken();
    cancel.onCancel(ttsCancel.cancel);
    final List<String> keys = <String>[];
    final List<String> paths = <String>[];
    try {
      for (final String segment in segments) {
        final TtsDirection direction = v.directionFor(segment, seed, line);
        final String key = v.cacheKey(segment, direction);
        // 整批合成里这段失败过：这一句直接记失败（走占位 + 账本），不再逐句重跑 worker。
        final MangaLineFailure? batchFailure = _batchFailures[key];
        if (batchFailure != null) throw batchFailure;
        // 先 pin 再合成：obtain 发布新文件时会顺手淘汰，未 pin 的前一片段可能被挤掉。
        _cache.pin(key);
        keys.add(key);
        await v.gate.acquire();
        try {
          final TtsCachedAudio audio = await ttsWithRetry(
            () => _cache.obtain(
              key,
              (String out) => ttsSynthesizeSplittingOnReject(
                v.provider,
                segment,
                outputPath: out,
                cancel: ttsCancel,
                direction: direction,
              ),
            ),
            cancel: ttsCancel,
          );
          paths.add(audio.path);
        } finally {
          v.gate.release();
        }
      }
      cancel.throwIfCancelled();
      await _runFfmpeg(
        buildMangaLineEncodeArgs(inputs: paths, outputPath: outputPath),
        outputPath: outputPath,
        cancel: cancel,
        source: 'MangaRender.encode',
      );
    } on TtsFailure catch (e) {
      if (cancel.isCancelled || e.code == TtsFailureCode.cancelled) {
        cancel.throwIfCancelled();
      }
      rethrow;
    } finally {
      for (final String key in keys) {
        _cache.unpin(key);
      }
    }
    return await readMp4PresentationDurationMs(outputPath) ??
        (throw const MangaLineFailure('encode_failed', 'no duration'));
  }

  @override
  Future<int> cutClip({
    required MangaAudiobookClip clip,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    final List<String>? sources = clip.bookKey == null
        ? null
        : _clipSources[clip.bookKey];
    if (sources == null ||
        clip.fileIndex >= sources.length ||
        !await File(sources[clip.fileIndex]).exists()) {
      throw const MangaLineFailure('clip_source_missing');
    }
    await _runFfmpeg(
      buildMangaClipArgs(
        sourcePath: sources[clip.fileIndex],
        startMs: clip.startMs,
        endMs: clip.endMs,
        outputPath: outputPath,
        shapeAsLine: true,
      ),
      outputPath: outputPath,
      cancel: cancel,
      source: 'MangaRender.clip',
    );
    return await readMp4PresentationDurationMs(outputPath) ??
        (throw const MangaLineFailure('encode_failed', 'no duration'));
  }

  @override
  Future<int> shapeLocalAudio({
    required String sourcePath,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => shapeMangaLocalAudio(
    _ffmpeg,
    sourcePath: sourcePath,
    outputPath: outputPath,
    cancel: cancel,
    log: _log,
  );

  @override
  Future<int> writeSilence({
    required int ms,
    required String outputPath,
  }) async {
    final File f = File(outputPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(
      buildTtsSilenceWav(ms: ms, sampleRate: kTtsOutputSampleRate, channels: 1),
      flush: true,
    );
    return ms;
  }

  Future<void> _runFfmpeg(
    List<String> args, {
    required String outputPath,
    required TtsRenderCancelToken cancel,
    required String source,
  }) => runMangaFfmpeg(
    _ffmpeg,
    args,
    outputPath: outputPath,
    cancel: cancel,
    source: source,
    log: _log,
  );
}

/// 把用户换上的一段本地音频整形成漫画句（与有声书片段同一套参数：裁首尾静音、淡变、
/// 响度、编码，所以整形版本同样是 [kMangaShapeVersion]），返回时长。解不出 / 写不出按
/// `encode_failed` 失败。
Future<int> shapeMangaLocalAudio(
  FfmpegBackend ffmpeg, {
  required String sourcePath,
  required String outputPath,
  required TtsRenderCancelToken cancel,
  required void Function(String source, String summary) log,
}) async {
  await runMangaFfmpeg(
    ffmpeg,
    buildMangaClipArgs(
      sourcePath: sourcePath,
      startMs: 0,
      endMs: null,
      outputPath: outputPath,
      shapeAsLine: true,
    ),
    outputPath: outputPath,
    cancel: cancel,
    source: 'MangaRender.local',
    log: log,
  );
  return await readMp4PresentationDurationMs(outputPath) ??
      (throw const MangaLineFailure('encode_failed', 'no duration'));
}

/// 只会整形本地音频的后端（控制通道「按句替换本地音频」：不合成、不剪有声书，不用拉起
/// TTS 引擎）。
class MangaLocalAudioBackend implements MangaRenderBackend {
  MangaLocalAudioBackend({
    required FfmpegBackend ffmpeg,
    required void Function(String source, String summary) log,
  }) : _ffmpeg = ffmpeg,
       _log = log;

  final FfmpegBackend _ffmpeg;
  final void Function(String source, String summary) _log;

  @override
  int get parallelism => 1;

  @override
  String get shapeVersion => kMangaShapeVersion;

  @override
  Future<int> shapeLocalAudio({
    required String sourcePath,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => shapeMangaLocalAudio(
    _ffmpeg,
    sourcePath: sourcePath,
    outputPath: outputPath,
    cancel: cancel,
    log: _log,
  );

  @override
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required CastLineDirection direction,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => throw UnsupportedError('local audio only');

  @override
  Future<String?> directionKey({
    required String voice,
    required CastLineDirection direction,
  }) async => null;

  @override
  Future<int> cutClip({
    required MangaAudiobookClip clip,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => throw UnsupportedError('local audio only');

  @override
  Future<int> writeSilence({required int ms, required String outputPath}) =>
      throw UnsupportedError('local audio only');

  @override
  Future<void> prepare({
    required List<MangaRenderItem> items,
    required TtsRenderCancelToken cancel,
  }) async {}

  @override
  bool get canCloneNarrator => false;

  @override
  Future<bool> prepareNarrator({
    required MangaNarratorVoice narrator,
    required TtsRenderCancelToken cancel,
  }) async => false;
}

/// 漫画有声的一次 ffmpeg：卡死（[kMangaEncodeStallTimeout] 没进度）或取消就停；退出
/// 码非 0 / 没写出文件按 `encode_failed` 失败（摘要进 [log]）。生成端与广播剧剪段共用。
Future<void> runMangaFfmpeg(
  FfmpegBackend ffmpeg,
  List<String> args, {
  required String outputPath,
  required TtsRenderCancelToken cancel,
  required String source,
  required void Function(String source, String summary) log,
}) async {
  cancel.throwIfCancelled();
  final Completer<void> cancelled = Completer<void>();
  cancel.onCancel(() {
    if (!cancelled.isCompleted) cancelled.complete();
  });
  final FfmpegRunResult result = switch (ffmpeg) {
    final FfmpegWatchedRunner watched => await watched.runWatched(
      args,
      FfmpegWatch(
        stallTimeout: kMangaEncodeStallTimeout,
        cancel: cancelled.future,
      ),
    ),
    final FfmpegBackend plain => await plain.run(
      args,
      kMangaEncodeStallTimeout,
    ),
  };
  cancel.throwIfCancelled();
  final File out = File(outputPath);
  if (!result.isSuccess || !await out.exists() || await out.length() == 0) {
    log(source, result.failureSummary);
    throw const MangaLineFailure('encode_failed');
  }
}
