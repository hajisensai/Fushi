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
/// `_refitPages`），所以放大看细节的清晰度不降；需要的宽度接近原图时直接给原图。
///
/// 转码是计算型工作，放在 Rust 内核（`ffc_image_fit_jpeg`，解码 + 面积平均 + JPEG），
/// 后台 isolate 里串行跑（同时只转一张，峰值只多一张原图的解码缓冲），结果进按字节
/// 限额的 LRU，翻回来的页不再重转。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

/// 降采样输出的 JPEG 质量（4:4:4）。显示分辨率下与原图肉眼无差，放大时另取高档。
const int kMangaFitJpegQuality = 90;

/// 目标像素数不到源图这个比例才转码；省得不多时转码成本不值，直接给原图。
const double kMangaFitMaxPixelRatio = 0.64;

/// 已转好的页图 LRU 的字节上限。显示尺寸的 JPEG 一张几百 KB，够存几十页。
const int kMangaFitCacheBytes = 48 << 20;

/// URL 上的降采样宽度参数名。
const String kMangaFitQueryParam = 'fit';

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

/// 后台 isolate 里跑的整段：读头 → 定尺寸 → 降采样编 JPEG。不值得 / 解不开 / GIF
/// （可能是动图）/ 带 alpha 都返回 null，调用方给原图。顶层函数：给 [Isolate.run] 用。
Uint8List? mangaFitPageBytes(Uint8List bytes, int fitWidth) {
  final FushiComputeImage kernel = FushiComputeImage.instance;
  final ({int width, int height, FfcImageFormat format})? head = kernel.probe(
    bytes,
  );
  if (head == null || head.format == FfcImageFormat.gif) return null;
  final ({int width, int height})? target = mangaFitTarget(
    sourceWidth: head.width,
    sourceHeight: head.height,
    fitWidth: fitWidth,
  );
  if (target == null) return null;
  return kernel.fitJpeg(
    bytes,
    width: target.width,
    height: target.height,
    quality: kMangaFitJpegQuality,
  );
}

/// 把原图字节转成降采样字节的函数（测试缝；生产是后台 isolate 里的 [mangaFitPageBytes]）。
typedef MangaFitTranscoder =
    Future<Uint8List?> Function(Uint8List bytes, int fitWidth);

Future<Uint8List?> _transcodeInIsolate(Uint8List bytes, int fitWidth) =>
    Isolate.run(() => mangaFitPageBytes(bytes, fitWidth));

/// 一个阅读器页面持有一份：串行转码 + 同 key 去重 + 按字节限额的 LRU。
class MangaPageFitter {
  MangaPageFitter({
    this.maxCacheBytes = kMangaFitCacheBytes,
    MangaFitTranscoder? transcoder,
  }) : _transcoder = transcoder ?? _transcodeInIsolate;

  final int maxCacheBytes;
  final MangaFitTranscoder _transcoder;

  /// key → 降采样结果；空字节 = 「这一档给原图」（同样缓存，免得反复探测）。
  final LinkedHashMap<String, Uint8List> _cache =
      LinkedHashMap<String, Uint8List>();
  int _cacheBytes = 0;
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;

  /// 已缓存的字节数（测试与诊断用）。
  int get cachedBytes => _cacheBytes;

  /// [key]（页的稳定身份）在 [fitWidth] 档的降采样字节；该给原图时返回 null。
  /// [loadSource] 只在缓存未命中时才调用（命中时连原图都不读）。
  Future<Uint8List?> fit(
    String key,
    int fitWidth,
    Future<Uint8List> Function() loadSource,
  ) {
    final String entry = '$key|$fitWidth';
    final Uint8List? cached = _cache.remove(entry);
    if (cached != null) {
      _cache[entry] = cached; // 刷新到最近使用。
      return Future<Uint8List?>.value(cached.isEmpty ? null : cached);
    }
    final Future<Uint8List?>? pending = _inFlight[entry];
    if (pending != null) return pending;
    final Future<Uint8List?> job = _enqueue(() async {
      final Uint8List source = await loadSource();
      final Uint8List? fitted = await _transcoder(source, fitWidth);
      _remember(entry, fitted ?? Uint8List(0));
      return fitted;
    });
    _inFlight[entry] = job;
    return job.whenComplete(() => _inFlight.remove(entry));
  }

  /// 同时只跑一个转码：每次转码要解一整张原图（4K 约 60～80 MB 缓冲），并发的话
  /// WebView 一次预取几页就把峰值顶回去了。
  Future<Uint8List?> _enqueue(Future<Uint8List?> Function() body) {
    final Completer<Uint8List?> done = Completer<Uint8List?>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await body());
      } on Object catch (error, stackTrace) {
        done.completeError(error, stackTrace);
      }
    });
    return done.future;
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

  /// 页面卸载：丢掉缓存（在飞的转码照常结束，结果不再入缓存）。
  void dispose() {
    _disposed = true;
    _cache.clear();
    _cacheBytes = 0;
  }
}
