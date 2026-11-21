/// 漫画阅读器「低清页 AI 超分」的 Dart 接线（设计文档 `docs/specs/2026-11-20-manga-upscale-design.md` §4）。
///
/// 计算与状态全在 Rust（`native/fushi_compute/src/upscale.rs`：ORT 运行时、模型会话、按当前页排序的
/// 任务队列与往后预取、磁盘 LRU、工作线程）。这里只做三件事：
///
/// 1. [MangaUpscaleService]（进程级）：挑 onnxruntime 与推理后端、按需下载并校验模型、启动 / 配置引擎；
/// 2. [MangaUpscaleController]（每个阅读器页面一份）：决定哪页值得超分（显示宽度比原图大
///    [kMangaUpscaleMinRatio] 以上才做——原图已经够清晰的页跳过）、提交、换当前页、把完成事件转成
///    「这页可以换图了」；
/// 3. 缓存键 / URL 标签的纯函数（[mangaUpscaleTag] / [mangaUpscaleKey]）。
///
/// 页图换成超分结果靠页面脚本把 `<img data-src>` 换成带 `sr=<标签>` 的 URL（`__mangaSrReady`），整页
/// 与气泡放大层（克隆页、读 `data-src`）都从这个 URL 取图；OCR 坐标仍在原图坐标系（页 div 的
/// `data-pw` / `data-ph` 不变，图按 `object-fit: contain` 铺满），查词命中不受影响。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/manga/reader/manga_page_fit.dart'
    show mangaTextBoxSignature;
import 'package:fushi/src/onnx/onnx_inference_ort.dart' show ortRuntimeInfo;
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_asr_core/asr_core.dart'
    show DownloadableModelFile, ModelFileDownloader;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:path/path.dart' as p;

/// 用户选的超分档（偏好 `aiUpscale`）。
enum MangaUpscaleTier {
  off,
  light,
  high;

  static MangaUpscaleTier fromPreference(String value) => switch (value) {
    'light' => MangaUpscaleTier.light,
    'high' => MangaUpscaleTier.high,
    _ => MangaUpscaleTier.off,
  };

  FfcUpscaleTier? get engineTier => switch (this) {
    MangaUpscaleTier.off => null,
    MangaUpscaleTier.light => FfcUpscaleTier.light,
    MangaUpscaleTier.high => FfcUpscaleTier.high,
  };
}

/// 显示宽度至少是原图宽的这么多倍才超分（低于它说明原图像素已经够屏幕用，超分没有收益）。
const double kMangaUpscaleMinRatio = 1.1;

/// 往后预取几页（高质量档一页数秒，预取少些）。
int mangaUpscalePrefetchWindow(FfcUpscaleTier tier) =>
    tier == FfcUpscaleTier.high ? 2 : 3;

/// 磁盘缓存上限。
const int kMangaUpscaleCacheBytes = 1 << 30;

/// 模型版本：换模型文件时改它，旧缓存键自然失效。
const String kMangaUpscaleModelsVersion = 'v1';

/// URL 上的超分标签参数名。
const String kMangaUpscaleQueryParam = 'sr';

/// 一个按需下载的模型文件（sha256 钉死）。
@immutable
class MangaUpscaleModelFile implements DownloadableModelFile {
  const MangaUpscaleModelFile({
    required this.fileName,
    required this.expectedBytes,
    required this.sha256,
  });

  @override
  final String fileName;

  @override
  final int expectedBytes;

  /// 小写十六进制。
  final String sha256;

  /// 本仓 `upscale-models-v1` 预发行（swin 两个已离线改写掉 DirectML 上会全零的负 Pad，
  /// ArtCNN 与 Artoriuz/ArtCNN v1.6.2 逐字节相同；均 MIT，见发行说明）。
  @override
  String get url =>
      'https://github.com/hajisensai/Fushi/releases/download/'
      'upscale-models-$kMangaUpscaleModelsVersion/$fileName';
}

const MangaUpscaleModelFile kMangaUpscaleArtCnn = MangaUpscaleModelFile(
  fileName: 'ArtCNN_C4F32.onnx',
  expectedBytes: 193085,
  sha256: 'b1a1130469a0538d4484fc3d6ca39854ef3906a3a01df8799997b6ed0408f6ea',
);

const MangaUpscaleModelFile kMangaUpscaleSwinScale2x = MangaUpscaleModelFile(
  fileName: 'swin_unet_art_scale2x.onnx',
  expectedBytes: 16734898,
  sha256: '490be4998c29052663e3859e6cfdb3d3f80f4a244f88e9c759e22c8d23faa30a',
);

const MangaUpscaleModelFile kMangaUpscaleSwinNoise1 = MangaUpscaleModelFile(
  fileName: 'swin_unet_art_noise1_scale2x.onnx',
  expectedBytes: 16734898,
  sha256: '750be49b76e68e09444b7e2a70f2e1e069fb0550e54abf271f1aee8ded811d2c',
);

/// 一档要的模型：`(框内, 框外)`。
(MangaUpscaleModelFile?, MangaUpscaleModelFile) mangaUpscaleModelsFor(
  FfcUpscaleTier tier,
) => switch (tier) {
  FfcUpscaleTier.light => (null, kMangaUpscaleArtCnn),
  FfcUpscaleTier.high => (kMangaUpscaleSwinScale2x, kMangaUpscaleSwinNoise1),
};

/// 纯函数：超分标签（档 + 文字框签名）。文字框变了（后台 OCR 补完）标签就变，换图时取新结果。
String mangaUpscaleTag(FfcUpscaleTier tier, Float32List boxes) =>
    '${tier == FfcUpscaleTier.high ? 'h' : 'l'}${mangaTextBoxSignature(boxes)}';

/// 纯函数：磁盘缓存键（模型版本 + 页身份 + 标签）。
String mangaUpscaleKey(String pageIdentity, String tag) =>
    '$kMangaUpscaleModelsVersion|$tag|$pageIdentity';

/// 纯函数：这页值得超分吗（显示宽度比原图宽 [kMangaUpscaleMinRatio] 倍以上）。
bool mangaUpscaleWanted({required int fitWidth, required double sourceWidth}) =>
    sourceWidth > 0 && fitWidth >= sourceWidth * kMangaUpscaleMinRatio;

/// 本平台的 onnxruntime 与首选后端。
@immutable
class MangaUpscaleRuntime {
  const MangaUpscaleRuntime({required this.ortPath, required this.gpuBackend});

  /// onnxruntime 动态库路径；null = 从本进程符号找（Apple 静态链接）。
  final String? ortPath;

  /// 本平台的加速后端（引擎启动后再查它是否真可用）；null = 只有 CPU。
  final FfcUpscaleBackend? gpuBackend;
}

/// 挑 onnxruntime 与后端。Windows：flutter_onnxruntime 插件绑定的那份（下载的 DirectML core 被选中时
/// 是它，否则随包 CPU core——同一个文件，进程里只有一份 ORT）；DirectML 只在那份 core 里有。
Future<MangaUpscaleRuntime?> resolveMangaUpscaleRuntime() async {
  if (Platform.isWindows) {
    final String selected = (await ortRuntimeInfo()).selectedPath;
    if (selected.isNotEmpty) {
      return MangaUpscaleRuntime(
        ortPath: selected,
        gpuBackend: FfcUpscaleBackend.directMl,
      );
    }
    return MangaUpscaleRuntime(
      ortPath: p.join(
        File(Platform.resolvedExecutable).parent.path,
        'onnxruntime.dll',
      ),
      gpuBackend: null,
    );
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return const MangaUpscaleRuntime(
      ortPath: null,
      gpuBackend: FfcUpscaleBackend.coreMl,
    );
  }
  if (Platform.isAndroid) {
    // 安卓：XNNPACK 没有真机验证过（CoreML 的默认格式就踩过段错误），先走 CPU；高质量档引擎判不支持。
    return const MangaUpscaleRuntime(
      ortPath: 'libonnxruntime.so',
      gpuBackend: null,
    );
  }
  if (Platform.isLinux) {
    return const MangaUpscaleRuntime(
      ortPath: 'libonnxruntime.so',
      gpuBackend: null,
    );
  }
  return null;
}

/// 引擎实际启用的档位与后端。
@immutable
class MangaUpscaleActivation {
  const MangaUpscaleActivation({
    required this.tier,
    required this.backend,
    required this.downgraded,
  });

  final FfcUpscaleTier tier;
  final FfcUpscaleBackend backend;

  /// 选了高质量但这个后端跑不了（引擎 `tierSupported`：只有 DirectML 行），按轻量档做。
  final bool downgraded;
}

/// 进程级：运行时、模型、引擎配置。
class MangaUpscaleService {
  MangaUpscaleService._() : _downloadModels = downloadMangaUpscaleModels;

  /// 测试用：注入下载实现。
  @visibleForTesting
  MangaUpscaleService.forTesting({
    required Future<void> Function(Directory, List<MangaUpscaleModelFile>)
    download,
  }) : _downloadModels = download;

  final Future<void> Function(Directory, List<MangaUpscaleModelFile>)
  _downloadModels;

  static final MangaUpscaleService instance = MangaUpscaleService._();

  Future<bool>? _started;
  Future<MangaUpscaleActivation?> _tail =
      Future<MangaUpscaleActivation?>.value();
  final Map<String, Future<void>> _downloads = <String, Future<void>>{};

  Stream<FfcUpscaleEvent> get events => FushiComputeUpscale.instance.events;

  Future<bool> _start() => _started ??= () async {
    final MangaUpscaleRuntime? runtime = await resolveMangaUpscaleRuntime();
    if (runtime == null) return false;
    final Directory cache = Directory(
      p.join((await AppPaths.appCacheRootDirectory()).path, 'manga_upscale'),
    );
    final int status = FushiComputeUpscale.instance.start(
      ortPath: runtime.ortPath,
      cacheDir: cache.path,
      cacheBytes: kMangaUpscaleCacheBytes,
    );
    if (status != FfcStatus.ok) {
      ErrorLogService.instance.log(
        'MangaUpscaleService.start',
        'ffc_upscale_start status $status (ort ${runtime.ortPath}): '
            '${FushiComputeUpscale.instance.takeLastError()}',
        StackTrace.current,
      );
      return false;
    }
    _gpu = runtime.gpuBackend;
    return true;
  }();

  FfcUpscaleBackend? _gpu;

  Future<Directory> _modelsDir() async => Directory(
    p.join(
      (await AppPaths.supportRootDirectory()).path,
      'manga_upscale_models',
      kMangaUpscaleModelsVersion,
    ),
  );

  /// 启用 [requested] 档（串行：同一时刻只有一次配置在进行）。不可用返回 null。要下载模型时先调
  /// [onDownload]。
  Future<MangaUpscaleActivation?> activate(
    FfcUpscaleTier requested, {
    void Function()? onDownload,
  }) {
    final Future<MangaUpscaleActivation?> next = _tail.then(
      (_) => _activate(requested, onDownload),
      onError: (Object _) => _activate(requested, onDownload),
    );
    _tail = next;
    return next;
  }

  Future<MangaUpscaleActivation?> _activate(
    FfcUpscaleTier requested,
    void Function()? onDownload,
  ) async {
    try {
      if (!await _start()) return null;
      final FushiComputeUpscale engine = FushiComputeUpscale.instance;
      final FfcUpscaleBackend? gpu = _gpu;
      final FfcUpscaleBackend backend =
          gpu != null && engine.backendAvailable(gpu)
          ? gpu
          : FfcUpscaleBackend.cpu;
      final FfcUpscaleTier tier = engine.tierSupported(requested, backend)
          ? requested
          : FfcUpscaleTier.light;
      final (MangaUpscaleModelFile? inside, MangaUpscaleModelFile outside) =
          mangaUpscaleModelsFor(tier);
      final Directory dir = await _modelsDir();
      await _ensureModels(dir, <MangaUpscaleModelFile>[
        ?inside,
        outside,
      ], onDownload);
      final int status = engine.configure(
        tier: tier,
        backend: backend,
        insideModel: inside == null ? null : p.join(dir.path, inside.fileName),
        outsideModel: p.join(dir.path, outside.fileName),
      );
      if (status != FfcStatus.ok) {
        ErrorLogService.instance.log(
          'MangaUpscaleService.configure',
          'ffc_upscale_configure status $status ($tier / $backend)',
          StackTrace.current,
        );
        return null;
      }
      return MangaUpscaleActivation(
        tier: tier,
        backend: backend,
        downgraded: tier != requested,
      );
    } on Object catch (error, stackTrace) {
      ErrorLogService.instance.log(
        'MangaUpscaleService.activate',
        error,
        stackTrace,
      );
      return null;
    }
  }

  static bool _sized(File file, MangaUpscaleModelFile model) =>
      file.existsSync() && file.lengthSync() == model.expectedBytes;

  /// 测试入口：同 [_ensureModels]。
  @visibleForTesting
  Future<void> ensureModels(
    Directory dir,
    List<MangaUpscaleModelFile> files, {
    void Function()? onDownload,
  }) => _ensureModels(dir, files, onDownload);

  Future<void> _ensureModels(
    Directory dir,
    List<MangaUpscaleModelFile> files,
    void Function()? onDownload,
  ) async {
    final List<MangaUpscaleModelFile> missing = files
        .where(
          (MangaUpscaleModelFile f) =>
              !_sized(File(p.join(dir.path, f.fileName)), f),
        )
        .toList();
    if (missing.isEmpty) return;
    onDownload?.call();
    final String slot = missing
        .map((MangaUpscaleModelFile f) => f.fileName)
        .join('|');
    // whenComplete 的回调不能返回 `_downloads.remove(slot)`：那是被 await 的这个 Future 本身，
    // whenComplete 会等回调返回的 Future 完成——自己等自己，永远不完成（真机实测卡死在这里）。
    await (_downloads[slot] ??= _download(dir, missing).whenComplete(() {
      _downloads.remove(slot);
    }));
  }

  Future<void> _download(Directory dir, List<MangaUpscaleModelFile> files) =>
      _downloadModels(dir, files);
}

/// 下载 [files] 到 [dir] 并逐个校验字节数与 SHA-256；不符的文件删掉并抛 [StateError]（下次重下）。
/// [urlCandidates] / [createClient] 只给测试注入本地服务器。
Future<void> downloadMangaUpscaleModels(
  Directory dir,
  List<MangaUpscaleModelFile> files, {
  List<String> Function(DownloadableModelFile file)? urlCandidates,
  HttpClient Function()? createClient,
}) async {
  final ModelFileDownloader downloader = ModelFileDownloader(
    urlCandidates:
        urlCandidates ?? (DownloadableModelFile f) => <String>[f.url],
    createClient: createClient,
  );
  await downloader
      .downloadAll(
        files: files,
        targetDir: dir,
        isReady: (File f) => files.any(
          (MangaUpscaleModelFile m) =>
              p.basename(f.path) == m.fileName &&
              MangaUpscaleService._sized(f, m),
        ),
      )
      .drain<void>();
  for (final MangaUpscaleModelFile file in files) {
    final String path = p.join(dir.path, file.fileName);
    // 原生 SHA-256，1 MiB 一块异步读（UI isolate 上不长时间阻塞）。
    final String actual = await ffcSha256File(path);
    if (actual != file.sha256) {
      await File(path).delete();
      throw StateError('${file.fileName}: sha256 $actual != ${file.sha256}');
    }
  }
}

/// 每个阅读器页面一份：决定哪页超分、提交、换当前页、把完成事件转成「这页可以换图了」。
class MangaUpscaleController {
  MangaUpscaleController({
    required this.requested,
    required this.onReady,
    required this.onNotice,
    MangaUpscaleService? service,
  }) : _service = service ?? MangaUpscaleService.instance,
       _generation = ++_generations;

  /// 用户选的档。
  final FfcUpscaleTier requested;

  /// 某页的超分结果进了缓存（页面据此调 `__mangaSrReady`）。
  final void Function(int page) onReady;

  /// 给用户的一次性提示（降档 / 不可用）。
  final void Function(MangaUpscaleNotice notice) onNotice;

  final MangaUpscaleService _service;
  final int _generation;
  static int _generations = 0;

  Future<MangaUpscaleActivation?>? _activation;
  int _focusPage = 0;
  MangaUpscaleActivation? _active;
  StreamSubscription<FfcUpscaleEvent>? _events;
  bool _disposed = false;

  /// 最近一次请求的「显示宽 / 原图宽」，预取邻页时沿用。
  double lastRatio = 0;

  /// 已启用的档（还没启用 / 不可用为 null）。
  FfcUpscaleTier? get tier => _active?.tier;

  static const int _pageBits = 20;

  int _token(int page) => (_generation << _pageBits) | page;

  /// 启用（只做一次）。
  Future<MangaUpscaleActivation?> ensureActive() => _activation ??= () async {
    final MangaUpscaleActivation? active = await _service.activate(
      requested,
      onDownload: () {
        if (!_disposed) onNotice(MangaUpscaleNotice.downloading);
      },
    );
    if (_disposed) return null;
    if (active == null) {
      onNotice(MangaUpscaleNotice.unavailable);
      return null;
    }
    if (active.downgraded) onNotice(MangaUpscaleNotice.lightOnly);
    _active = active;
    _events = _service.events.listen(_onEvent);
    // 引擎的队列按当前页取舍任务：先告诉它读者在哪，再收提交。
    FushiComputeUpscale.instance.focus(
      _focusPage,
      mangaUpscalePrefetchWindow(active.tier),
    );
    return active;
  }();

  void _onEvent(FfcUpscaleEvent event) {
    if (_disposed) return;
    if (event.kind == FfcUpscaleEventKind.failed ||
        event.kind == FfcUpscaleEventKind.modelsFailed) {
      final String? reason = FushiComputeUpscale.instance.takeLastError();
      if (reason != null) {
        ErrorLogService.instance.log(
          'MangaUpscale.${event.kind.name}',
          reason,
          StackTrace.current,
        );
      }
    }
    if (event.kind == FfcUpscaleEventKind.modelsFailed) {
      _active = null;
      onNotice(MangaUpscaleNotice.unavailable);
      return;
    }
    if (event.token >> _pageBits != _generation) return;
    if (event.kind == FfcUpscaleEventKind.done) {
      onReady(event.token & ((1 << _pageBits) - 1));
    }
  }

  /// 本页当前该用的标签（未启用为 null）。
  String? tagFor(Float32List boxes) {
    final FfcUpscaleTier? t = tier;
    return t == null ? null : mangaUpscaleTag(t, boxes);
  }

  /// [tag] 对应的结果在不在缓存里（不刷新最近使用）。
  bool isCached(String pageIdentity, String tag) =>
      FushiComputeUpscale.instance.query(mangaUpscaleKey(pageIdentity, tag)) ==
      FfcUpscaleKeyState.cached;

  /// [tag] 对应的缓存结果路径。
  String? cachedPath(String pageIdentity, String tag) => FushiComputeUpscale
      .instance
      .cachedPath(mangaUpscaleKey(pageIdentity, tag));

  /// 请求一页超分：已在缓存里就立即 [onReady]；在算 / 判过不做 / 失败过就不动；引擎不认识才读原图
  /// 提交（完成后 [onReady]）。
  Future<void> request({
    required int page,
    required String pageIdentity,
    required Float32List boxes,
    required Future<Uint8List> Function() loadSource,
  }) async {
    if (_disposed || page < 0 || page >= (1 << _pageBits)) return;
    final MangaUpscaleActivation? active = await ensureActive();
    if (active == null || _disposed) return;
    final String key = mangaUpscaleKey(
      pageIdentity,
      mangaUpscaleTag(active.tier, boxes),
    );
    final FushiComputeUpscale engine = FushiComputeUpscale.instance;
    switch (engine.query(key)) {
      case FfcUpscaleKeyState.cached:
        onReady(page);
        return;
      case FfcUpscaleKeyState.unknown:
        break;
      case FfcUpscaleKeyState.notReady:
      case FfcUpscaleKeyState.pending:
      case FfcUpscaleKeyState.skipped:
      case FfcUpscaleKeyState.failed:
        return;
    }
    final Uint8List data = await loadSource();
    if (_disposed) return;
    final FfcUpscaleSubmit result = engine.submit(
      token: _token(page),
      key: key,
      page: page,
      data: data,
      boxes: boxes,
    );
    if (result == FfcUpscaleSubmit.alreadyCached) onReady(page);
  }

  /// 当前页变了：引擎按它排优先级、丢掉翻走的任务。
  void focus(int page) {
    _focusPage = page;
    final MangaUpscaleActivation? active = _active;
    if (_disposed || active == null) return;
    FushiComputeUpscale.instance.focus(
      page,
      mangaUpscalePrefetchWindow(active.tier),
    );
  }

  /// 往后预取的页数（未启用为 0）。
  int get prefetchWindow {
    final MangaUpscaleActivation? active = _active;
    return active == null ? 0 : mangaUpscalePrefetchWindow(active.tier);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events?.cancel());
    if (_active != null) FushiComputeUpscale.instance.clear();
  }
}

/// 给用户的提示。
enum MangaUpscaleNotice {
  /// 首次使用这档，正在下载模型。
  downloading,

  /// 没有 GPU 加速，高质量档按轻量档做。
  lightOnly,

  /// 本机用不了（运行时 / 模型 / 下载失败），退回画质缩放。
  unavailable,
}
