/// 整首离线音频分析的编排（全屏歌词动画的音频信号；设计见 docs/specs/2026-11-22-music-lyric-visualizer.md
/// 「补齐」轨道 A2）。
///
/// 分工（「Rust 胖核心、Flutter 薄 UI」）：
/// - **解码**走统一 FFmpeg 后端（[resolveFfmpegBackend]），把音轨解成 44.1 kHz 立体声 s16le 临时 raw 文件；
/// - **分析**在 native/fushi_compute 的 `ffc_mana_*` 引擎（Rust 工作线程）：DSP 总跑，Beat This! / htdemucs
///   模型下载了才跑，每一步写一次完整的 `.fma` 结果并发事件；
/// - **这里**只排队（正在播的那首插队、队列预取在后）、管缓存文件名、把事件折成每首一个
///   [ValueListenable]（[MusicAudioAnalysisSnapshot]），结果整份读成 [MusicAudioAnalysis]（TypedData 视图）。
///
/// 一次只有一首在引擎里（解码出的临时 PCM 不堆积）；加急请求会把正在跑的预取任务取消、排回队尾
/// （引擎已写出的阶段性结果留着，下次只补缺的那一步）。
///
/// 不接宿主 / 页面：调用方（歌词动画宿主）拿 [analyze] 的 listenable，把 `snapshot.audio` 交给
/// `LyricVisualizerContext.audio`。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/manga/reader/manga_upscale_controller.dart'
    show resolveMangaUpscaleRuntime;
import 'package:fushi/src/media/music/analysis/music_audio_analysis.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis_models.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:path/path.dart' as p;

/// 要分析的一首。
@immutable
class MusicAudioAnalysisTarget {
  const MusicAudioAnalysisTarget({
    required this.trackUid,
    required this.path,
    this.cueStartMs,
    this.durationMs,
  });

  /// 曲目 uid（曲库内容派生）。
  final String trackUid;

  /// 本地音频文件路径（网络来源的曲目不分析：调用方别交过来，交了判 unsupported）。
  final String path;

  /// CUE 虚拟曲目在整轨里的起点。
  final int? cueStartMs;

  /// CUE 虚拟曲目的长度。
  final int? durationMs;

  /// 同一首的身份（不含文件指纹：指纹要读盘，异步算进缓存文件名）。
  String get identity =>
      '$trackUid|$path|${cueStartMs ?? ''}|${durationMs ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is MusicAudioAnalysisTarget && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;
}

/// 一首的分析状态。
enum MusicAudioAnalysisPhase {
  /// 没请求过 / 被取消了。
  idle,

  /// 排队中。
  queued,

  /// 解码或分析中（[MusicAudioAnalysisSnapshot.audio] 可能已经有前几步的结果）。
  running,

  /// 本机能做的都做完了。
  ready,

  /// 失败（解码失败、文件不在、引擎出错）；[MusicAudioAnalysisSnapshot.audio] 保留已有的结果。
  failed,

  /// 不分析（不是本地文件 / 原生库不可用）。
  unsupported,
}

/// 一首的分析快照。
@immutable
class MusicAudioAnalysisSnapshot {
  const MusicAudioAnalysisSnapshot({
    required this.phase,
    this.audio,
    this.stage,
    this.progress = 0,
    this.error,
  });

  static const MusicAudioAnalysisSnapshot idle = MusicAudioAnalysisSnapshot(
    phase: MusicAudioAnalysisPhase.idle,
  );

  final MusicAudioAnalysisPhase phase;

  /// 目前为止的结果（DSP 那一步做完就有；之后每一步换一个更好的）。
  final MusicAudioAnalysis? audio;

  /// 正在跑的步骤。
  final FfcManaStage? stage;

  /// 这一步的进度（0–1）。
  final double progress;

  final String? error;

  MusicAudioAnalysisSnapshot copyWith({
    MusicAudioAnalysisPhase? phase,
    MusicAudioAnalysis? audio,
    FfcManaStage? stage,
    bool clearStage = false,
    double? progress,
    String? error,
  }) => MusicAudioAnalysisSnapshot(
    phase: phase ?? this.phase,
    audio: audio ?? this.audio,
    stage: clearStage ? null : (stage ?? this.stage),
    progress: progress ?? this.progress,
    error: error,
  );

  @override
  String toString() =>
      'MusicAudioAnalysisSnapshot($phase, stage: $stage, '
      'progress: ${progress.toStringAsFixed(2)}, audio: $audio, error: $error)';
}

/// 模型下载状态。
@immutable
class MusicAnalysisModelState {
  const MusicAnalysisModelState({
    required this.installed,
    required this.downloading,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  /// 本平台要的模型都在。
  final bool installed;
  final bool downloading;
  final int receivedBytes;
  final int totalBytes;
  final String? error;
}

/// 引擎接口（native 绑定 [FushiComputeMusicAnalysis] 的那几个调用；测试注入假引擎）。
abstract interface class MusicAudioAnalysisEngine {
  Stream<FfcManaEvent> get events;
  int get pipelineVersion;
  int start();
  int configure({
    required String? ortPath,
    required String? beatThisModel,
    required String? htdemucsModel,
    required int threads,
    int backend,
  });
  int submit({
    required int token,
    required String pcmPath,
    required String outPath,
    int flags,
  });
  int cancel(int token);
  String? takeLastError();
}

class _NativeEngine implements MusicAudioAnalysisEngine {
  _NativeEngine(this._b);

  final FushiComputeMusicAnalysis _b;

  @override
  Stream<FfcManaEvent> get events => _b.events;
  @override
  int get pipelineVersion => _b.pipelineVersion;
  @override
  int start() => _b.start();
  @override
  int configure({
    required String? ortPath,
    required String? beatThisModel,
    required String? htdemucsModel,
    required int threads,
    int backend = 0,
  }) => _b.configure(
    ortPath: ortPath,
    beatThisModel: beatThisModel,
    htdemucsModel: htdemucsModel,
    threads: threads,
    backend: backend,
  );
  @override
  int submit({
    required int token,
    required String pcmPath,
    required String outPath,
    int flags = 0,
  }) =>
      _b.submit(token: token, pcmPath: pcmPath, outPath: outPath, flags: flags);
  @override
  int cancel(int token) => _b.cancel(token);
  @override
  String? takeLastError() => _b.takeLastError();
}

/// 把一首解成 44.1 kHz 立体声 s16le raw 文件。失败抛 [MusicAnalysisDecodeException]。
abstract interface class MusicAnalysisPcmDecoder {
  Future<void> decode({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  });
}

/// 解码失败。
final class MusicAnalysisDecodeException implements Exception {
  const MusicAnalysisDecodeException(this.input, this.detail);

  final String input;
  final String detail;

  @override
  String toString() => 'MusicAnalysisDecodeException($input): $detail';
}

/// 分析最长这么多（与 native `pcm::MAX_SECONDS` 一致；更长的只解前面这段）。
const Duration kMusicAnalysisMaxLength = Duration(minutes: 20);

/// 统一 FFmpeg 后端实现。
class FfmpegMusicAnalysisPcmDecoder implements MusicAnalysisPcmDecoder {
  const FfmpegMusicAnalysisPcmDecoder({
    this.timeout = const Duration(minutes: 5),
  });

  final Duration timeout;

  /// 解码参数（纯函数，测试钉死）。
  static List<String> argsFor({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  }) {
    final int maxMs = kMusicAnalysisMaxLength.inMilliseconds;
    final int lengthMs = durationMs != null && durationMs > 0
        ? math.min(durationMs, maxMs)
        : maxMs;
    return <String>[
      '-y',
      '-v',
      'error',
      if (startMs != null && startMs > 0) ...<String>[
        '-ss',
        (startMs / 1000).toStringAsFixed(3),
      ],
      '-i',
      input,
      '-t',
      (lengthMs / 1000).toStringAsFixed(3),
      '-map',
      '0:a:0',
      '-vn',
      '-sn',
      '-dn',
      '-ac',
      '2',
      '-ar',
      '44100',
      '-f',
      's16le',
      output,
    ];
  }

  @override
  Future<void> decode({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  }) async {
    final FfmpegRunResult r = await resolveFfmpegBackend().run(
      argsFor(
        input: input,
        output: output,
        startMs: startMs,
        durationMs: durationMs,
      ),
      timeout,
    );
    if (r.returnCode != 0) {
      throw MusicAnalysisDecodeException(input, r.output.trim());
    }
    if (!File(output).existsSync() || File(output).lengthSync() == 0) {
      throw MusicAnalysisDecodeException(input, 'no audio decoded');
    }
  }
}

/// 缓存里最多留这么多首的结果（一首约 120–150 KB）；超出按修改时间删最旧的。
const int kMusicAnalysisCacheMaxFiles = 600;

/// 纯函数：缓存文件名（目标身份 + 文件指纹 → sha1）。文件改了（大小 / 修改时间变）就是新键。
///
/// 不含算法版本：升了版本的旧结果照样找得到、先拿来用（引擎读得懂旧布局），再由
/// [musicAudioAnalysisComplete] 判不完整、补算——旧缓存不会白扔、也不会堆出多份。
String musicAudioAnalysisCacheName({
  required MusicAudioAnalysisTarget target,
  required int fileSize,
  required int fileModifiedMs,
}) {
  final String key = '${target.identity}|$fileSize|$fileModifiedMs';
  return '${crypto.sha1.convert(utf8.encode(key))}.fma';
}

/// 纯函数：本机做完了没有：[wanted] 是本机可用模型对应的 flags，分离不是半截，且由当前算法版本
/// [pipelineVersion] 写出（旧版本写的照样能用，只是要补算）。
bool musicAudioAnalysisComplete(
  MusicAudioAnalysis a,
  int wanted, {
  required int pipelineVersion,
}) =>
    a.flags & wanted == wanted &&
    !a.stemsPartial &&
    a.pipelineVersion == pipelineVersion;

class _Request {
  _Request(this.target, this.notifier, {required this.urgent});

  final MusicAudioAnalysisTarget target;
  final ValueNotifier<MusicAudioAnalysisSnapshot> notifier;
  bool urgent;
  int? token;
  String? outPath;
  String? pcmPath;
  bool cancelRequested = false;
  bool requeueOnCancel = false;
}

/// 整首离线音频分析服务（进程级单例 [instance]；测试用构造函数注入）。
class MusicAudioAnalysisService {
  MusicAudioAnalysisService({
    required Future<Directory> Function() cacheDir,
    required Future<Directory> Function() modelsDir,
    required Future<Directory> Function() tempDir,
    required MusicAudioAnalysisEngine Function() engine,
    MusicAnalysisPcmDecoder decoder = const FfmpegMusicAnalysisPcmDecoder(),
    Future<String?> Function()? ortPath,
    Future<int> Function()? backend,
    bool? desktop,
    int? threads,
    Future<void> Function(
      Directory dir,
      List<MusicAnalysisModelFile> files,
      void Function(ModelDownloadEvent event) onProgress,
    )?
    download,
  }) : _cacheDir = cacheDir,
       _modelsDir = modelsDir,
       _tempDir = tempDir,
       _engineFactory = engine,
       _decoder = decoder,
       _ortPath = ortPath ?? _defaultOrtPath,
       // 注入了 ORT 路径（测试 / 无头）而没给后端：不猜 GPU，用 CPU。
       _backend = backend ?? (ortPath == null ? _defaultBackend : _cpuBackend),
       _desktop = desktop ?? musicAnalysisIsDesktop,
       _threads = threads ?? math.max(1, Platform.numberOfProcessors ~/ 2),
       _download =
           download ??
           ((Directory dir, List<MusicAnalysisModelFile> files, onProgress) =>
               downloadMusicAnalysisModels(dir, files, onProgress: onProgress));

  static MusicAudioAnalysisService? _instance;

  /// 应用里的单例：缓存在 app 缓存根 `music_analysis/`，模型在支持根 `music_analysis_models/<版本>/`。
  static MusicAudioAnalysisService get instance =>
      _instance ??= MusicAudioAnalysisService(
        cacheDir: () async => Directory(
          p.join(
            (await AppPaths.appCacheRootDirectory()).path,
            'music_analysis',
          ),
        ),
        modelsDir: () async => Directory(
          p.join(
            (await AppPaths.supportRootDirectory()).path,
            'music_analysis_models',
            kMusicAnalysisModelsVersion,
          ),
        ),
        tempDir: () async => Directory(
          p.join(Directory.systemTemp.path, 'fushi_music_analysis'),
        ),
        engine: () => _NativeEngine(FushiComputeMusicAnalysis.instance),
      );

  static Future<String?> _defaultOrtPath() async =>
      (await resolveMangaUpscaleRuntime())?.ortPath;

  static Future<int> _cpuBackend() async => 0;

  /// 与漫画超分同一套后端选择（Windows 选了 DirectML core 时 DirectML、Apple CoreML，其余 CPU）。
  static Future<int> _defaultBackend() async =>
      (await resolveMangaUpscaleRuntime())?.gpuBackend?.code ?? 0;

  final Future<Directory> Function() _cacheDir;
  final Future<Directory> Function() _modelsDir;
  final Future<Directory> Function() _tempDir;
  final MusicAudioAnalysisEngine Function() _engineFactory;
  final MusicAnalysisPcmDecoder _decoder;
  final Future<String?> Function() _ortPath;
  final Future<int> Function() _backend;
  final bool _desktop;
  final int _threads;
  final Future<void> Function(
    Directory,
    List<MusicAnalysisModelFile>,
    void Function(ModelDownloadEvent),
  )
  _download;

  MusicAudioAnalysisEngine? _engine;
  Future<bool>? _started;
  StreamSubscription<FfcManaEvent>? _sub;

  /// 本机可用模型对应的结果 flags（配置成功后才非 0）。
  int _wantedFlags = 0;

  /// 这份结果在本机算完了吗（引擎没起来时只看 flags）。
  bool _complete(MusicAudioAnalysis a) => musicAudioAnalysisComplete(
    a,
    _wantedFlags,
    pipelineVersion: _engine?.pipelineVersion ?? a.pipelineVersion,
  );

  final Map<String, ValueNotifier<MusicAudioAnalysisSnapshot>> _notifiers =
      <String, ValueNotifier<MusicAudioAnalysisSnapshot>>{};
  final ListQueue<_Request> _pending = ListQueue<_Request>();
  _Request? _active;
  int _nextToken = 1;
  bool _cacheTrimmed = false;

  final ValueNotifier<MusicAnalysisModelState> _models =
      ValueNotifier<MusicAnalysisModelState>(
        const MusicAnalysisModelState(installed: false, downloading: false),
      );

  /// 模型下载状态（设置页用）。调一次 [refreshModels] 后才准。
  ValueListenable<MusicAnalysisModelState> get models => _models;

  /// 本平台要的模型清单。
  List<MusicAnalysisModelFile> get requiredModels =>
      musicAnalysisModelsFor(desktop: _desktop);

  /// 要的模型一共多大（字节；下载确认框用）。
  int get requiredModelBytes => requiredModels.fold<int>(
    0,
    (int sum, MusicAnalysisModelFile f) => sum + f.expectedBytes,
  );

  // ---------------------------------------------------------------------------
  // 分析
  // ---------------------------------------------------------------------------

  /// 要这首的分析：已有完整结果直接 ready；否则排队（[urgent] 插队，正在跑的预取让路）。
  /// 返回这首的快照 listenable（同一首多次调用返回同一个）。
  ValueListenable<MusicAudioAnalysisSnapshot> analyze(
    MusicAudioAnalysisTarget target, {
    bool urgent = true,
  }) {
    final ValueNotifier<MusicAudioAnalysisSnapshot> n = _notifierFor(target);
    unawaited(_request(target, n, urgent: urgent));
    return n;
  }

  /// 预取（队列里接下来的几首）：不插队。
  void prefetch(Iterable<MusicAudioAnalysisTarget> targets) {
    for (final MusicAudioAnalysisTarget t in targets) {
      analyze(t, urgent: false);
    }
  }

  /// 不再需要的排队任务取消（[keep] 之外的；正在跑的那首若不在 [keep] 里也取消）。
  void cancelExcept(Set<MusicAudioAnalysisTarget> keep) {
    final Set<String> ids = keep.map((t) => t.identity).toSet();
    _pending.removeWhere((_Request r) {
      if (ids.contains(r.target.identity)) return false;
      _setIdleUnlessDone(r);
      return true;
    });
    final _Request? a = _active;
    if (a != null && !ids.contains(a.target.identity)) {
      a.requeueOnCancel = false;
      _cancelActive(a);
    }
  }

  /// 当前快照（没请求过为 idle）。
  MusicAudioAnalysisSnapshot snapshotOf(MusicAudioAnalysisTarget target) =>
      _notifiers[target.identity]?.value ?? MusicAudioAnalysisSnapshot.idle;

  ValueNotifier<MusicAudioAnalysisSnapshot> _notifierFor(
    MusicAudioAnalysisTarget target,
  ) {
    final ValueNotifier<MusicAudioAnalysisSnapshot>? existing = _notifiers
        .remove(target.identity);
    // 重新插入：Map 的插入序当 LRU 用。
    final ValueNotifier<MusicAudioAnalysisSnapshot> n =
        existing ??
        ValueNotifier<MusicAudioAnalysisSnapshot>(
          MusicAudioAnalysisSnapshot.idle,
        );
    _notifiers[target.identity] = n;
    while (_notifiers.length > 64) {
      final String oldest = _notifiers.keys.first;
      if (_active?.target.identity == oldest ||
          _pending.any((r) => r.target.identity == oldest)) {
        break;
      }
      _notifiers.remove(oldest);
    }
    return n;
  }

  void _setIdleUnlessDone(_Request r) {
    final MusicAudioAnalysisSnapshot s = r.notifier.value;
    if (s.phase == MusicAudioAnalysisPhase.queued ||
        s.phase == MusicAudioAnalysisPhase.running) {
      r.notifier.value = s.copyWith(
        phase: MusicAudioAnalysisPhase.idle,
        clearStage: true,
        progress: 0,
      );
    }
  }

  Future<void> _request(
    MusicAudioAnalysisTarget target,
    ValueNotifier<MusicAudioAnalysisSnapshot> n, {
    required bool urgent,
  }) async {
    // 已在排队 / 在跑：只升级优先级。
    final _Request? active = _active;
    if (active != null && active.target == target) {
      active.urgent = active.urgent || urgent;
      return;
    }
    for (final _Request r in _pending) {
      if (r.target == target) {
        if (urgent && !r.urgent) {
          r.urgent = true;
          _pending
            ..remove(r)
            ..addFirst(r);
          _preemptForUrgent();
        }
        return;
      }
    }
    if (n.value.phase == MusicAudioAnalysisPhase.unsupported) return;
    if (!await _ensureStarted()) {
      n.value = n.value.copyWith(phase: MusicAudioAnalysisPhase.unsupported);
      return;
    }
    final MusicAudioAnalysis? have = n.value.audio;
    if (n.value.phase == MusicAudioAnalysisPhase.ready &&
        have != null &&
        _complete(have)) {
      return;
    }
    final String? out = await _outPathFor(target);
    if (out == null) {
      n.value = n.value.copyWith(phase: MusicAudioAnalysisPhase.unsupported);
      return;
    }
    final MusicAudioAnalysis? cached = await _readResult(out);
    if (cached != null) {
      final bool complete = _complete(cached);
      n.value = n.value.copyWith(
        phase: complete ? MusicAudioAnalysisPhase.ready : n.value.phase,
        audio: cached,
      );
      if (complete) return;
    }
    // 读盘期间可能已被别的调用排上。
    if (_active?.target == target || _pending.any((r) => r.target == target)) {
      return;
    }
    final _Request req = _Request(target, n, urgent: urgent)..outPath = out;
    n.value = n.value.copyWith(phase: MusicAudioAnalysisPhase.queued);
    if (urgent) {
      _pending.addFirst(req);
      _preemptForUrgent();
    } else {
      _pending.addLast(req);
    }
    unawaited(_pump());
  }

  /// 有加急的在排队、而正在跑的不是加急：让正在跑的停下，排回队尾。
  void _preemptForUrgent() {
    final _Request? a = _active;
    if (a == null || a.urgent || _pending.isEmpty || !_pending.first.urgent) {
      return;
    }
    a.requeueOnCancel = true;
    _cancelActive(a);
  }

  void _cancelActive(_Request a) {
    a.cancelRequested = true;
    final int? token = a.token;
    if (token != null) _engine?.cancel(token);
    // 还在解码（没 token）：解码完看到 cancelRequested 自己收尾。
  }

  Future<String?> _outPathFor(MusicAudioAnalysisTarget target) async {
    final File f = File(target.path);
    final FileStat st;
    try {
      st = await f.stat();
    } on FileSystemException {
      return null;
    }
    if (st.type != FileSystemEntityType.file) return null;
    final Directory dir = await _cacheDir();
    final String name = musicAudioAnalysisCacheName(
      target: target,
      fileSize: st.size,
      fileModifiedMs: st.modified.millisecondsSinceEpoch,
    );
    return p.join(dir.path, name);
  }

  Future<MusicAudioAnalysis?> _readResult(String path) async {
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      return MusicAudioAnalysis.tryParse(bytes);
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> _ensureStarted() => _started ??= () async {
    try {
      final MusicAudioAnalysisEngine engine = _engineFactory();
      final int status = engine.start();
      if (status != FfcStatus.ok) {
        _log('start', 'ffc_mana_start status $status');
        return false;
      }
      _engine = engine;
      _sub = engine.events.listen(_onEvent);
      await _configureModels();
      final Directory cache = await _cacheDir();
      if (!cache.existsSync()) await cache.create(recursive: true);
      return true;
    } on FushiComputeUnavailableError catch (e, st) {
      _log('start', e, st);
      return false;
    }
  }();

  /// 把本机已有的模型交给引擎（下载完 / 删掉后再调一次）。
  Future<void> _configureModels() async {
    final MusicAudioAnalysisEngine? engine = _engine;
    if (engine == null) return;
    final Directory dir = await _modelsDir();
    final bool beat = musicAnalysisModelReady(dir, kMusicBeatThisModel);
    final bool stems =
        _desktop && musicAnalysisModelReady(dir, kMusicHtdemucsModel);
    _models.value = MusicAnalysisModelState(
      installed: requiredModels.every(
        (MusicAnalysisModelFile f) => musicAnalysisModelReady(dir, f),
      ),
      downloading: _models.value.downloading,
      receivedBytes: _models.value.receivedBytes,
      totalBytes: _models.value.totalBytes,
      error: _models.value.error,
    );
    if (!beat && !stems) {
      engine.configure(
        ortPath: null,
        beatThisModel: null,
        htdemucsModel: null,
        threads: _threads,
      );
      _wantedFlags = 0;
      return;
    }
    final String? ort = await _ortPath();
    final int backend = await _backend();
    final int status = engine.configure(
      ortPath: ort,
      beatThisModel: beat
          ? p.join(dir.path, kMusicBeatThisModel.fileName)
          : null,
      htdemucsModel: stems
          ? p.join(dir.path, kMusicHtdemucsModel.fileName)
          : null,
      threads: _threads,
      backend: backend,
    );
    if (status != FfcStatus.ok) {
      _log(
        'configure',
        'ffc_mana_configure status $status (ort $ort): ${engine.takeLastError()}',
      );
      _wantedFlags = 0;
      return;
    }
    _wantedFlags =
        (beat ? MusicAudioAnalysisFlags.beatsModel : 0) |
        (stems
            ? MusicAudioAnalysisFlags.drumsModel |
                  MusicAudioAnalysisFlags.vocalModel
            : 0);
  }

  Future<void> _pump() async {
    if (_active != null || _pending.isEmpty) return;
    final _Request req = _pending.removeFirst();
    _active = req;
    req.notifier.value = req.notifier.value.copyWith(
      phase: MusicAudioAnalysisPhase.running,
      clearStage: true,
      progress: 0,
    );
    try {
      await _trimCacheOnce();
      final Directory tmp = await _tempDir();
      if (!tmp.existsSync()) await tmp.create(recursive: true);
      final int token = _nextToken++;
      final String pcm = p.join(tmp.path, 'mana_$token.s16le');
      req.pcmPath = pcm;
      await _decoder.decode(
        input: req.target.path,
        output: pcm,
        startMs: req.target.cueStartMs,
        durationMs: req.target.durationMs,
      );
      if (req.cancelRequested) {
        _deleteQuietly(pcm);
        _finishActive(req, cancelled: true);
        return;
      }
      req.token = token;
      final int status = _engine!.submit(
        token: token,
        pcmPath: pcm,
        outPath: req.outPath!,
        flags:
            FfcManaSubmitFlags.deleteInput |
            (req.urgent ? FfcManaSubmitFlags.urgent : 0),
      );
      if (status != FfcStatus.ok) {
        _deleteQuietly(pcm);
        _fail(req, 'ffc_mana_submit status $status');
      }
      // 之后由事件推进（_onEvent）。
    } on MusicAnalysisDecodeException catch (e) {
      _deleteQuietly(req.pcmPath);
      _fail(req, e.detail);
    } on Object catch (e, st) {
      _deleteQuietly(req.pcmPath);
      _log('pump', e, st);
      _fail(req, e.toString());
    }
  }

  void _fail(_Request req, String error) {
    req.notifier.value = req.notifier.value.copyWith(
      phase: MusicAudioAnalysisPhase.failed,
      clearStage: true,
      error: error,
    );
    _finishActive(req, cancelled: false);
  }

  void _finishActive(_Request req, {required bool cancelled}) {
    if (_active == req) _active = null;
    if (cancelled) {
      if (req.requeueOnCancel) {
        req
          ..token = null
          ..cancelRequested = false
          ..requeueOnCancel = false
          ..urgent = false;
        req.notifier.value = req.notifier.value.copyWith(
          phase: MusicAudioAnalysisPhase.queued,
          clearStage: true,
          progress: 0,
        );
        _pending.addLast(req);
      } else {
        _setIdleUnlessDone(req);
      }
    }
    unawaited(_pump());
  }

  void _onEvent(FfcManaEvent e) {
    final _Request? req = _active;
    if (req == null || req.token != e.token) return;
    switch (e.kind) {
      case FfcManaEventKind.started:
        break;
      case FfcManaEventKind.progress:
        req.notifier.value = req.notifier.value.copyWith(
          stage: e.stage,
          progress: e.permille / 1000,
        );
      case FfcManaEventKind.updated:
        unawaited(_reload(req));
      case FfcManaEventKind.modelFailed:
        final String? err = _engine?.takeLastError();
        _log('model', 'ffc_mana model step failed: $err');
      case FfcManaEventKind.backendFallback:
        // 引擎每进程每模型每执行器只发一次，这里照记不去重。
        final String? err = _engine?.takeLastError();
        _log('backend', 'ffc_mana backend ${e.value} -> CPU: $err');
      case FfcManaEventKind.done:
        unawaited(() async {
          await _reload(req);
          req.notifier.value = req.notifier.value.copyWith(
            phase: MusicAudioAnalysisPhase.ready,
            clearStage: true,
            progress: 1,
          );
          _finishActive(req, cancelled: false);
        }());
      case FfcManaEventKind.failed:
        _fail(req, _engine?.takeLastError() ?? 'failed');
      case FfcManaEventKind.cancelled:
        _finishActive(req, cancelled: true);
    }
  }

  Future<void> _reload(_Request req) async {
    final String? out = req.outPath;
    if (out == null) return;
    final MusicAudioAnalysis? a = await _readResult(out);
    if (a != null) {
      req.notifier.value = req.notifier.value.copyWith(audio: a);
    }
  }

  Future<void> _trimCacheOnce() async {
    if (_cacheTrimmed) return;
    _cacheTrimmed = true;
    try {
      final Directory dir = await _cacheDir();
      if (!dir.existsSync()) return;
      final List<File> files = dir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.fma'))
          .toList();
      if (files.length <= kMusicAnalysisCacheMaxFiles) return;
      final List<(File, DateTime)> dated = <(File, DateTime)>[
        for (final File f in files) (f, f.statSync().modified),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (File f, DateTime _) in dated.take(
        files.length - kMusicAnalysisCacheMaxFiles,
      )) {
        _deleteQuietly(f.path);
      }
    } on FileSystemException catch (e, st) {
      _log('trim', e, st);
    }
  }

  // ---------------------------------------------------------------------------
  // 模型
  // ---------------------------------------------------------------------------

  /// 重新看一遍模型目录（设置页打开时调）。
  Future<void> refreshModels() async {
    if (_engine != null) {
      await _configureModels();
      return;
    }
    final Directory dir = await _modelsDir();
    _models.value = MusicAnalysisModelState(
      installed: requiredModels.every(
        (MusicAnalysisModelFile f) => musicAnalysisModelReady(dir, f),
      ),
      downloading: _models.value.downloading,
    );
  }

  Future<void>? _downloading;

  /// 下载本平台要的模型（opt-in：只在用户点了才调）。完成后交给引擎；之后再请求的歌会补模型那几步。
  Future<void> downloadModels() => _downloading ??= () async {
    final Directory dir = await _modelsDir();
    _models.value = MusicAnalysisModelState(
      installed: false,
      downloading: true,
      totalBytes: requiredModelBytes,
    );
    int done = 0;
    String? current;
    try {
      await _download(dir, requiredModels, (ModelDownloadEvent e) {
        if (e.done) return;
        if (current != e.fileName) {
          if (current != null) {
            done += requiredModels
                .firstWhere((f) => f.fileName == current)
                .expectedBytes;
          }
          current = e.fileName;
        }
        _models.value = MusicAnalysisModelState(
          installed: false,
          downloading: true,
          receivedBytes: done + e.receivedBytes,
          totalBytes: requiredModelBytes,
        );
      });
      _models.value = const MusicAnalysisModelState(
        installed: true,
        downloading: false,
      );
    } on Object catch (e, st) {
      _log('download', e, st);
      _models.value = MusicAnalysisModelState(
        installed: false,
        downloading: false,
        error: e.toString(),
      );
    } finally {
      _downloading = null;
    }
    await refreshModels();
  }();

  /// 删掉模型（引擎退回只跑 DSP；已有结果里模型算的部分留着）。
  Future<void> deleteModels() async {
    final Directory dir = await _modelsDir();
    for (final MusicAnalysisModelFile f in <MusicAnalysisModelFile>[
      kMusicBeatThisModel,
      kMusicHtdemucsModel,
    ]) {
      _deleteQuietly(p.join(dir.path, f.fileName));
    }
    await refreshModels();
  }

  // ---------------------------------------------------------------------------

  static void _deleteQuietly(String? path) {
    if (path == null) return;
    try {
      final File f = File(path);
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // 被占用留给系统临时目录清理。
    }
  }

  static void _log(String where, Object error, [StackTrace? st]) {
    ErrorLogService.instance.log(
      'MusicAudioAnalysisService.$where',
      error,
      st ?? StackTrace.current,
    );
  }

  /// 测试用：释放事件订阅。
  @visibleForTesting
  Future<void> dispose() async {
    await _sub?.cancel();
  }
}
