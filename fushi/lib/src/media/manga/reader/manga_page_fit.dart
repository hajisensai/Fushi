/// 漫画页图按显示尺寸降采样（BUG-4704：4K 页图卷打开后内存暴涨闪退）。
///
/// 阅读器的页图在 WebView 里画。此前拦截器把盘上原图原样交出，3840×5400 的页图解码
/// 后每张约 83 MB（RGBA），WebView 在渲染进程（CPU 解码副本）与宿主进程（GPU 纹理）
/// 各留一份，±2 跨页预热再乘上去，阅读到第几页都在 1～2 GB 之间打转，低内存平板直接
/// 被系统杀掉。屏幕根本显示不了这么多像素：同一页在 926×650dp@2.63 的平板上横屏双页
/// 时只占约 1216×1709 物理像素。
///
/// 现在页面 JS 按每页**实际排版宽度 × devicePixelRatio × 缩放档**算出需要的像素宽，
/// 作为 `fit=<宽>` 挂在页图 URL 上；拦截器据此把原图降采样成同宽高比的 JPEG 再交给
/// WebView（本文件）。放大阅读时 JS 换更高的档（见 `manga_overlay_html.dart` 的
/// `_refitPage` / `_scheduleRefit`），所以放大看细节的清晰度不降；需要的宽度接近
/// 原图时直接给原图。
///
/// 转码是计算型工作，放在 Rust 内核（`ffc_image_fit_jpeg`，解码 + 面积平均 + JPEG），
/// 后台 isolate 里串行跑（同时只转一张，峰值只多一张原图的解码缓冲），结果进按字节
/// 限额的 LRU，翻回来的页不再重转。入队前先只读头判一次：不需要缩的页当场给原图、
/// 不排队；排队中屏上的当前跨页插到预热邻页之前（manga-6）。读头判据与转码段同一个
/// [mangaFitTargetFor]，跟着画质档走（画质缩放下「不需要缩」的范围窄得多，还会预放大）。
///
/// **画质缩放**（漫画阅读器「画质缩放」开关，默认开；设计见
/// `docs/specs/2026-11-20-manga-upscale-design.md`）：开着时缩放不再交给 WebView 的双线性 /
/// mipmap，也不只在「省得多」时才转——
/// - 只要显示宽度与原图差出 [kMangaEnhancedTolerance] 就由内核按显示尺寸重采样
///   （`ffc_image_fit_jpeg_hq`，缩小用按比例放宽的面积平均 [kMangaEnhancedDownFilter]）。
///   实测（设计文档「① 默认档」）WebView 的 mipmap + 双线性缩到 0.45 倍时 OCR 读字错误率
///   比面积平均高 20%～65%，网点混叠也最重；
/// - 低清源显示得比原图大时也由内核预放大（[kMangaEnhancedUpFilter]，至多
///   [kMangaEnhancedMaxUpscale] 倍、[kMangaEnhancedMaxPixels] 像素），比 WebView 的双线性锐；
/// - 「Gamma 校正」子开关（[MangaFitQuality.enhancedLinear]，默认关）在线性光里平均：网点明度
///   更准（误差降约三成），但 1 像素细笔画缩小后明显变淡（文字笔画对比度降 10%～20%），
///   与「小字可读」这个第一指标冲突，所以不默认开；
/// - 文档侧取整档从 128 px 收到 [kMangaEnhancedFitStep]，WebView 自己再缩的余量不到 3%。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

/// 降采样输出的 JPEG 质量（4:4:4）。显示分辨率下与原图肉眼无差，放大时另取高档。
const int kMangaFitJpegQuality = 90;

/// 画质缩放输出的 JPEG 质量：重采样后的细线 / 网点要尽量少吃块效应。
const int kMangaEnhancedJpegQuality = 94;

/// 画质缩放：显示宽度与原图相差不到这个比例就给原图（WebView 1:1 附近的缩放肉眼无差，
/// 转一遍 JPEG 反而多一代损失）。
const double kMangaEnhancedTolerance = 0.03;

/// 画质缩放：每边最多预放大的倍数。再大交给 WebView（放大层 / 深度缩放看局部时）。
const int kMangaEnhancedMaxUpscale = 2;

/// 画质缩放：预放大结果的像素上限（解码后约 64 MB RGBA，与 BUG-4704 的内存预算同量级）。
const int kMangaEnhancedMaxPixels = 16 << 20;

/// 画质缩放：文档侧按显示宽度取整的档距（px）。
const int kMangaEnhancedFitStep = 32;

/// 画质缩放缩小用的核：面积平均（按比例放宽）。Lanczos 笔画更黑但振铃让小字读错更多。
const FfcResampleFilter kMangaEnhancedDownFilter = FfcResampleFilter.box;

/// 画质缩放放大用的核（评测结论见设计文档「① 默认档」）。
const FfcResampleFilter kMangaEnhancedUpFilter = FfcResampleFilter.catmullRom;

/// 页图缩放的画质档（由页图 URL 上的 [kMangaFitEnhancedQueryParam] 决定，响应只看 URL）。
enum MangaFitQuality {
  /// BUG-4704 的省内存降采样：只在省得多时才转，其余交 WebView。
  standard,

  /// 画质缩放：内核按显示尺寸重采样（sRGB 编码域）。
  enhanced,

  /// 画质缩放 + Gamma 校正（线性光里平均）。
  enhancedLinear;

  /// URL 上 [kMangaFitEnhancedQueryParam] 的值；标准档不带。
  String? get urlValue => switch (this) {
    MangaFitQuality.standard => null,
    MangaFitQuality.enhanced => '1',
    MangaFitQuality.enhancedLinear => 'g',
  };

  /// 由阅读器偏好推出画质档（Gamma 校正只是画质缩放的子开关）。
  static MangaFitQuality fromPreferences({
    required bool enhanced,
    required bool gammaCorrect,
  }) => !enhanced
      ? MangaFitQuality.standard
      : gammaCorrect
      ? MangaFitQuality.enhancedLinear
      : MangaFitQuality.enhanced;
}

/// 目标像素数不到源图这个比例才转码；省得不多时转码成本不值，直接给原图。
const double kMangaFitMaxPixelRatio = 0.64;

/// 已转好的页图 LRU 的字节上限。显示尺寸的 JPEG 一张几百 KB，够存几十页。
const int kMangaFitCacheBytes = 48 << 20;

/// URL 上的降采样宽度参数名。
const String kMangaFitQueryParam = 'fit';

/// URL 上的画质档参数名（`fq=1` / `fq=g`，与 [kMangaFitQueryParam] 同时出现）。
const String kMangaFitEnhancedQueryParam = 'fq';

/// 纯函数：页图 URL 要的画质档；没有 / 不认识的值是标准档。
MangaFitQuality mangaFitQualityOf(Uri url) =>
    switch (url.queryParameters[kMangaFitEnhancedQueryParam]) {
      '1' => MangaFitQuality.enhanced,
      'g' => MangaFitQuality.enhancedLinear,
      _ => MangaFitQuality.standard,
    };

/// 纯函数：从页图 URL 读 `fit=<像素宽>`；没有 / 不合法返回 null。
int? mangaFitWidthOf(Uri url) {
  final String? raw = url.queryParameters[kMangaFitQueryParam];
  if (raw == null) return null;
  final int? width = int.tryParse(raw);
  if (width == null || width <= 0 || width > 0xffff) return null;
  return width;
}

/// 纯函数：源图 [sourceWidth]×[sourceHeight] 按需要的像素宽 [fitWidth] 降采样后的
/// 尺寸（等比、高四舍五入）；不需要缩、或省下的像素不够 [kMangaFitMaxPixelRatio]
/// 时返回 null（给原图）。
({int width, int height})? mangaFitTarget({
  required int sourceWidth,
  required int sourceHeight,
  required int fitWidth,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0 || fitWidth <= 0) return null;
  if (fitWidth >= sourceWidth) return null;
  final double scale = fitWidth / sourceWidth;
  if (scale * scale > kMangaFitMaxPixelRatio) return null;
  return (width: fitWidth, height: math.max(1, (sourceHeight * scale).round()));
}

/// 纯函数：画质缩放下源图按需要的像素宽 [fitWidth] 重采样后的尺寸（等比、高四舍五入）。
/// 与原图相差不到 [kMangaEnhancedTolerance] 给原图（null）；放大至多
/// [kMangaEnhancedMaxUpscale] 倍且不超过 [kMangaEnhancedMaxPixels]，封顶后若已贴近原图
/// 同样给原图。
({int width, int height})? mangaEnhancedFitTarget({
  required int sourceWidth,
  required int sourceHeight,
  required int fitWidth,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0 || fitWidth <= 0) return null;
  int width = math.min(fitWidth, sourceWidth * kMangaEnhancedMaxUpscale);
  final double aspect = sourceHeight / sourceWidth;
  final int byPixels = math.sqrt(kMangaEnhancedMaxPixels / aspect).floor();
  width = math.min(width, byPixels);
  if ((width - sourceWidth).abs() <= sourceWidth * kMangaEnhancedTolerance) {
    return null;
  }
  return (width: width, height: math.max(1, (width * aspect).round()));
}

/// 纯函数：[quality] 档下源图按 [fitWidth] 缩放后的尺寸；null = 给原图。画质档走
/// [mangaEnhancedFitTarget]，标准档走 [mangaFitTarget]。入队前的读头分流
/// （[mangaFitNeedsTranscode]）与后台转码（[mangaFitPageBytes]）共用这一个判据，
/// 两段对「要不要转」的结论不会分叉。
({int width, int height})? mangaFitTargetFor({
  required int sourceWidth,
  required int sourceHeight,
  required int fitWidth,
  required MangaFitQuality quality,
}) => quality == MangaFitQuality.standard
    ? mangaFitTarget(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        fitWidth: fitWidth,
      )
    : mangaEnhancedFitTarget(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        fitWidth: fitWidth,
      );

/// 后台 isolate 里跑的整段：读头 → 定尺寸（[mangaFitTargetFor]）→ 缩放编 JPEG。画质档走
/// `fitJpegHq`，标准档是 BUG-4704 的省内存降采样。不值得 / 解不开 / GIF（可能是动图）/ 带 alpha
/// 都返回 null，调用方给原图。顶层函数：给 [Isolate.run] 用。
Uint8List? mangaFitPageBytes(
  Uint8List bytes,
  int fitWidth, {
  MangaFitQuality quality = MangaFitQuality.standard,
}) {
  final FushiComputeImage kernel = FushiComputeImage.instance;
  final ({int width, int height, FfcImageFormat format})? head = kernel.probe(
    bytes,
  );
  if (head == null || head.format == FfcImageFormat.gif) return null;
  final ({int width, int height})? target = mangaFitTargetFor(
    sourceWidth: head.width,
    sourceHeight: head.height,
    fitWidth: fitWidth,
    quality: quality,
  );
  if (target == null) return null;
  if (quality != MangaFitQuality.standard) {
    return kernel.fitJpegHq(
      bytes,
      width: target.width,
      height: target.height,
      quality: kMangaEnhancedJpegQuality,
      filter: target.width < head.width
          ? kMangaEnhancedDownFilter
          : kMangaEnhancedUpFilter,
      linearLight: quality == MangaFitQuality.enhancedLinear,
    );
  }
  return kernel.fitJpeg(
    bytes,
    width: target.width,
    height: target.height,
    quality: kMangaFitJpegQuality,
  );
}

/// 读头用的前缀长度。JPEG 的 SOF 排在 EXIF / ICC 等 APPn 段之后，单个 APPn 段上限
/// 64 KB，512 KB 足够覆盖；前缀里认不出头时退回排队整张转码（由转码段自己判）。
const int kMangaFitProbePrefixBytes = 512 << 10;

/// FFI 只读头：[bytes] 这张页图在 [fitWidth] 档、[quality] 画质档下要不要转码。
/// `true` = 要转（缩小，画质档下也可能是预放大）；`false` = 给原图（按该档判据不值得转 /
/// GIF 可能是动图）；`null` = 认不出头，交给转码段判。判据与转码段同为 [mangaFitTargetFor]。
///
/// 只把前 [kMangaFitProbePrefixBytes] 字节拷进原生侧解析头，是微秒级的工作，所以
/// 放在调用方 isolate 上跑，不起后台 isolate（manga-6）。
bool? mangaFitNeedsTranscode(
  Uint8List bytes,
  int fitWidth, {
  required MangaFitQuality quality,
}) {
  final Uint8List prefix = bytes.length > kMangaFitProbePrefixBytes
      ? Uint8List.sublistView(bytes, 0, kMangaFitProbePrefixBytes)
      : bytes;
  final ({int width, int height, FfcImageFormat format})? head =
      FushiComputeImage.instance.probe(prefix);
  if (head == null) return null;
  if (head.format == FfcImageFormat.gif) return false;
  return mangaFitTargetFor(
        sourceWidth: head.width,
        sourceHeight: head.height,
        fitWidth: fitWidth,
        quality: quality,
      ) !=
      null;
}

/// 入队前的读头判定（测试缝；生产是 [mangaFitNeedsTranscode]）。
typedef MangaFitPlanner =
    bool? Function(
      Uint8List bytes,
      int fitWidth, {
      required MangaFitQuality quality,
    });

/// 把原图字节转成缩放后字节的函数（测试缝；生产是后台 isolate 里的 [mangaFitPageBytes]）。
typedef MangaFitTranscoder =
    Future<Uint8List?> Function(
      Uint8List bytes,
      int fitWidth, {
      required MangaFitQuality quality,
    });

Future<Uint8List?> _transcodeInIsolate(
  Uint8List bytes,
  int fitWidth, {
  required MangaFitQuality quality,
}) => Isolate.run(() => mangaFitPageBytes(bytes, fitWidth, quality: quality));

/// 排队等转码的一张页图。[urgent] 在**出队那一刻**才求值：入队时还是邻页、排队
/// 期间读者翻到了它，它就该插到前面。
class _MangaFitJob {
  _MangaFitJob(this.body, this.urgent);

  final Future<Uint8List?> Function() body;
  final bool Function()? urgent;
  final Completer<Uint8List?> done = Completer<Uint8List?>();

  bool get isUrgent => urgent?.call() ?? false;
}

/// 一个阅读器页面持有一份：读头分流 + 串行转码（屏上页插队）+ 同 key 去重 +
/// 按字节限额的 LRU。
class MangaPageFitter {
  MangaPageFitter({
    this.maxCacheBytes = kMangaFitCacheBytes,
    MangaFitTranscoder? transcoder,
    MangaFitPlanner? planner,
  }) : _transcoder = transcoder ?? _transcodeInIsolate,
       _planner = planner ?? mangaFitNeedsTranscode;

  final int maxCacheBytes;
  final MangaFitTranscoder _transcoder;
  final MangaFitPlanner _planner;

  /// key → 降采样结果；空字节 = 「这一档给原图」（同样缓存，免得反复探测）。
  final LinkedHashMap<String, Uint8List> _cache =
      LinkedHashMap<String, Uint8List>();
  int _cacheBytes = 0;
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};
  final List<_MangaFitJob> _queue = <_MangaFitJob>[];
  bool _transcoding = false;
  bool _disposed = false;

  /// 已缓存的字节数（测试与诊断用）。
  int get cachedBytes => _cacheBytes;

  /// [key]（页的稳定身份）在 [fitWidth] 档的缩放字节；该给原图时返回 null。
  /// [quality] 选画质档（缓存与在飞去重都按档分开，切开关不串）。
  /// [loadSource] 只在缓存未命中时才调用（命中时连原图都不读）。[urgent] 返回
  /// true 的请求（屏上的当前跨页）在转码队列里排到所有邻页预热之前。
  Future<Uint8List?> fit(
    String key,
    int fitWidth,
    Future<Uint8List> Function() loadSource, {
    MangaFitQuality quality = MangaFitQuality.standard,
    bool Function()? urgent,
  }) {
    final String entry = '$key|$fitWidth|${quality.name}';
    final Uint8List? cached = _cache.remove(entry);
    if (cached != null) {
      _cache[entry] = cached; // 刷新到最近使用。
      return Future<Uint8List?>.value(cached.isEmpty ? null : cached);
    }
    final Future<Uint8List?>? pending = _inFlight[entry];
    if (pending != null) return pending;
    final Future<Uint8List?> job = _resolve(
      entry,
      fitWidth,
      quality,
      loadSource,
      urgent,
    );
    _inFlight[entry] = job;
    return job.whenComplete(() => _inFlight.remove(entry));
  }

  /// 先读头分流（manga-6）：按 [quality] 档的判据不需要转的页（标准档：原图已够小 /
  /// 省得不多；画质档：与显示宽度差不到 [kMangaEnhancedTolerance]；以及 GIF）当场定为
  /// 「给原图」，不进转码队列、不起 isolate，也就不用排在别的页的整张转码后面。
  /// 读原图放在队列外：排队的只是编码后的字节（几 MB），峰值仍由串行转码约束。
  Future<Uint8List?> _resolve(
    String entry,
    int fitWidth,
    MangaFitQuality quality,
    Future<Uint8List> Function() loadSource,
    bool Function()? urgent,
  ) async {
    final Uint8List source = await loadSource();
    if (_plan(source, fitWidth, quality) == false) {
      _remember(entry, Uint8List(0));
      return null;
    }
    return _enqueue(() async {
      final Uint8List? fitted = await _transcoder(
        source,
        fitWidth,
        quality: quality,
      );
      _remember(entry, fitted ?? Uint8List(0));
      return fitted;
    }, urgent);
  }

  /// 读头抛错（原生库异常）不能让页白掉：当作认不出，退回转码段判；转码段的
  /// 失败照常上抛给调用方记日志并交原图。
  bool? _plan(Uint8List source, int fitWidth, MangaFitQuality quality) {
    try {
      return _planner(source, fitWidth, quality: quality);
    } on Object {
      return null;
    }
  }

  /// 同时只跑一个转码：每次转码要解一整张原图（4K 约 60～80 MB 缓冲），并发的话
  /// WebView 一次预取几页就把峰值顶回去了。出队时屏上页优先，其余按到达顺序；
  /// 不丢弃任何请求（WebView 在等它们的响应）。
  Future<Uint8List?> _enqueue(
    Future<Uint8List?> Function() body,
    bool Function()? urgent,
  ) {
    final _MangaFitJob job = _MangaFitJob(body, urgent);
    _queue.add(job);
    _pump();
    return job.done.future;
  }

  void _pump() {
    if (_transcoding || _queue.isEmpty) return;
    if (_disposed) {
      // 页面已卸载：排着的不再转码，交原图收尾（WebView 也已经不在了）。
      for (final _MangaFitJob job in _queue) {
        job.done.complete(null);
      }
      _queue.clear();
      return;
    }
    int next = _queue.indexWhere((_MangaFitJob job) => job.isUrgent);
    if (next < 0) next = 0;
    final _MangaFitJob job = _queue.removeAt(next);
    _transcoding = true;
    unawaited(_run(job));
  }

  Future<void> _run(_MangaFitJob job) async {
    try {
      job.done.complete(await job.body());
    } on Object catch (error, stackTrace) {
      job.done.completeError(error, stackTrace);
    } finally {
      _transcoding = false;
      _pump();
    }
  }

  void _remember(String entry, Uint8List bytes) {
    if (_disposed) return;
    _cache[entry] = bytes;
    _cacheBytes += bytes.length;
    while (_cacheBytes > maxCacheBytes && _cache.length > 1) {
      final String oldest = _cache.keys.first;
      _cacheBytes -= _cache.remove(oldest)!.length;
    }
  }

  /// 页面卸载：丢掉缓存与排队中的转码（在飞的那一张照常结束，结果不再入缓存）。
  void dispose() {
    _disposed = true;
    _cache.clear();
    _cacheBytes = 0;
    _pump();
  }
}
