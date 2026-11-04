import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/cover_provider_epoch.dart';

/// 预烘焙的高斯模糊图：效果等同 `ImageFiltered(blur(sigma)) + Image(fit)`，
/// 但模糊只在图片 / 尺寸变化时算**一次**，之后每帧只画一张小纹理。
///
/// 为什么不用 [ImageFiltered]：它的模糊是渲染期滤镜，每一帧都要对整块子树重新
/// 卷积。静止时 Skia 的 raster cache 能兜住，可一滚动、一悬停缩放（矩阵变了）
/// 缓存就失效；Impeller 则根本没有 raster cache。协作者 2026-10-05 的 Windows
/// 录屏里，游戏库滚动只有 15–20 fps，而同一段录屏里视频库 / 书架是满帧——差别
/// 就是「继续游戏」卡的 key art 背景（sigma 22 的 [ImageFiltered]）。视频 / 合集
/// 封面比例不符时的模糊垫底（`PortraitCoverImage` / `LandscapeCoverImage`）是
/// 同一种每卡一份的渲染期模糊，一并走这里。
///
/// 做法：把封面按 [fit] / [alignment] 画进一张**按 sigma 降采样**的小画布并在
/// 那里做模糊（模糊后已无高频信息，每 sigma 留 [_kBakedSigmaPx] 分之一的像素
/// 就足够），再拉伸铺满。sigma 语义与 [ImageFilter.blur] 包在同尺寸子树上完全
/// 一致：逻辑像素、作用在已按 [fit] 铺好的图上、边缘按引擎默认 tile 模式。
class PrebakedBlurImage extends StatefulWidget {
  const PrebakedBlurImage({
    required this.image,
    required this.sigma,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.colorFilter,
    this.tileMode,
    super.key,
  });

  /// 源图（通常是 `resizedFileImage` 降采样后的封面）。
  final ImageProvider image;

  /// 高斯模糊标准差（逻辑像素），同 `ImageFilter.blur(sigmaX: sigma, sigmaY: sigma)`。
  final double sigma;

  final BoxFit fit;
  final Alignment alignment;

  /// 模糊**之前**作用在图上的颜色滤镜，等价于 `ImageFiltered(child: ColorFiltered(
  /// colorFilter, child: Image))`（封面垫底的 `srcATop` 压暗：只压图自身 alpha）。
  final ColorFilter? colorFilter;

  /// 模糊边缘的 tile 模式，同 [ImageFilter.blur] 的 `tileMode`（null = 引擎默认）。
  final TileMode? tileMode;

  @override
  State<PrebakedBlurImage> createState() => _PrebakedBlurImageState();
}

/// 烘焙画布上 sigma 对应的像素数。模糊核在这一档已足够平滑，按 [FilterQuality.medium]
/// 双线性拉伸回原尺寸看不出网格；再大只是白占显存。
const double _kBakedSigmaPx = 6;

/// 烘焙结果的身份：图源 + 输出像素尺寸 + 模糊参数，任一变化都要重烘。
///
/// 图源按 [ImageProvider] 相等性认（不按解码出的 `ui.Image` 句柄）：同一张封面在
/// 不同卡、同一张卡卸载又重挂时都命中 [_BakedBlurCache]。
@immutable
class _BakeKey {
  const _BakeKey(
    this.provider,
    this.width,
    this.height,
    this.sigmaPx,
    this.fit,
    this.alignment,
    this.colorFilter,
    this.tileMode,
  );

  final ImageProvider provider;
  final int width;
  final int height;
  final double sigmaPx;
  final BoxFit fit;
  final Alignment alignment;
  final ColorFilter? colorFilter;
  final TileMode? tileMode;

  int get bytes => width * height * 4;

  @override
  bool operator ==(Object other) =>
      other is _BakeKey &&
      other.provider == provider &&
      other.width == width &&
      other.height == height &&
      other.sigmaPx == sigmaPx &&
      other.fit == fit &&
      other.alignment == alignment &&
      other.colorFilter == colorFilter &&
      other.tileMode == tileMode;

  @override
  int get hashCode => Object.hash(
    provider,
    width,
    height,
    sigmaPx,
    fit,
    alignment,
    colorFilter,
    tileMode,
  );
}

class _PrebakedBlurImageState extends State<PrebakedBlurImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _source;

  /// [_source] 解码到达时 [widget.image] 的 [CoverProviderEpoch]：用它烘焙出的
  /// 结果只在代际号未变时进缓存（期间被驱逐 = 换了图，旧源图不能扩散到别的卡）。
  int _sourceEpoch = 0;

  _BakeKey? _bakedKey;
  ui.Image? _baked;

  /// 正在烘焙的 key；结果回来时若已不是它就丢弃（尺寸 / 图已变）。
  _BakeKey? _pendingKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(PrebakedBlurImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  void _resolve() {
    final ImageStream next = widget.image.resolve(
      createLocalImageConfiguration(context),
    );
    if (_stream?.key == next.key) return;
    _detach();
    // 换了图源：旧解码不能再拿来按新 provider 的 key 烘焙（会把旧图写进新 key 的
    // 缓存）。已上屏的 [_baked] 留着，新图烘好再换，不闪白。
    _source?.dispose();
    _source = null;
    _pendingKey = null;
    final ImageProvider provider = widget.image;
    _stream = next;
    _listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted) {
          info.dispose();
          return;
        }
        setState(() {
          _source?.dispose();
          _source = info.image.clone();
          _sourceEpoch = CoverProviderEpoch.of(provider);
        });
        info.dispose();
      },
      // 解码失败：保持空白（与原 FadeInImage 的透明占位一致），不抛到框架。
      onError: (Object _, StackTrace? __) {},
    );
    next.addListener(_listener!);
  }

  void _detach() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    _source?.dispose();
    _baked?.dispose();
    super.dispose();
  }

  _BakeKey? _keyFor(Size size, double devicePixelRatio) {
    if (size.isEmpty || !size.isFinite) return null;
    // 每逻辑像素的烘焙像素数：模糊越大越可以降采样，但不超过屏幕本身的密度。
    final double scale = widget.sigma <= 0
        ? devicePixelRatio
        : math.min(devicePixelRatio, _kBakedSigmaPx / widget.sigma);
    return _BakeKey(
      widget.image,
      math.max(1, (size.width * scale).ceil()),
      math.max(1, (size.height * scale).ceil()),
      widget.sigma * scale,
      widget.fit,
      widget.alignment,
      widget.colorFilter,
      widget.tileMode,
    );
  }

  void _ensureBaked(_BakeKey key) {
    if (key == _bakedKey || key == _pendingKey) return;
    // 先查进程级缓存：卡片滚回视口 / 别的卡用同一张封面时直接拿现成纹理，
    // 不再 Picture.toImage 重烘（那一步占 raster 线程），也不再播一遍淡入。
    final ui.Image? cached = _BakedBlurCache.lookup(key);
    if (cached != null) {
      _baked?.dispose();
      _baked = cached;
      _bakedKey = key;
      _pendingKey = null;
      return;
    }
    final ui.Image? source = _source;
    if (source == null) return; // 解码回调里 setState 会再走一遍这里。
    _pendingKey = key;
    final int epoch = _sourceEpoch;
    unawaited(
      _bake(key, source).then((ui.Image image) {
        // 即使本卡已卸载（快速滑动时常见）结果也进缓存，下次挂载直接用；源图在
        // 期间被驱逐过（[epoch] 过期）则只给本卡用，不进缓存。
        final ui.Image own = _BakedBlurCache.store(key, image, epoch: epoch);
        if (!mounted || _pendingKey != key) {
          own.dispose();
          return;
        }
        setState(() {
          _baked?.dispose();
          _baked = own;
          _bakedKey = key;
          _pendingKey = null;
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final _BakeKey? key = _keyFor(constraints.biggest, dpr);
        if (key != null) _ensureBaked(key);
        final ui.Image? baked = _baked;
        return AnimatedOpacity(
          opacity: baked == null ? 0 : 1,
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.enter,
          child: baked == null
              ? const SizedBox.expand()
              : RawImage(
                  image: baked,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
        );
      },
    );
  }
}

/// 已烘焙模糊图的进程级 LRU 缓存（按字节计预算）。
///
/// 缓存自己持有一份 `ui.Image` 句柄，取用方拿的都是 [ui.Image.clone]，各自
/// dispose；淘汰时只释放缓存那一份，正在屏上的卡不受影响。单张超过预算一半的
/// （整页背景在小 sigma 下可能很大）不进缓存，原样交还调用方。
abstract final class _BakedBlurCache {
  static const int maxBytes = 48 << 20;

  static final LinkedHashMap<_BakeKey, ui.Image> _images =
      LinkedHashMap<_BakeKey, ui.Image>();
  static int _bytes = 0;

  /// 命中则返回一份调用方自己持有的 clone，并把条目挪到最近使用端。
  static ui.Image? lookup(_BakeKey key) {
    final ui.Image? image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image;
    return image.clone();
  }

  /// 收下 [image] 的所有权并返回一份调用方持有的句柄。[epoch] 是烘焙所用源图
  /// 解码到达时的 [CoverProviderEpoch.of]；与当前代际号不符（期间被驱逐过）的结果
  /// 不进缓存，原样交还调用方。
  static ui.Image store(_BakeKey key, ui.Image image, {required int epoch}) {
    if (key.bytes > maxBytes ~/ 2) return image;
    if (CoverProviderEpoch.of(key.provider) != epoch) return image;
    final ui.Image? previous = _images.remove(key);
    if (previous != null) {
      _bytes -= key.bytes;
      previous.dispose();
    }
    _images[key] = image;
    _bytes += key.bytes;
    while (_bytes > maxBytes && _images.isNotEmpty) {
      final _BakeKey oldest = _images.keys.first;
      _images.remove(oldest)!.dispose();
      _bytes -= oldest.bytes;
    }
    return image.clone();
  }

  static void evict(ImageProvider provider) {
    CoverProviderEpoch.bump(provider);
    final List<_BakeKey> stale = <_BakeKey>[
      for (final _BakeKey key in _images.keys)
        if (key.provider == provider) key,
    ];
    for (final _BakeKey key in stale) {
      _images.remove(key)!.dispose();
      _bytes -= key.bytes;
    }
  }

  static void clear() {
    for (final ui.Image image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }
}

/// 换图（同路径覆盖写）后丢掉 [provider] 的全部烘焙结果，并让正在飞的烘焙不再
/// 回填缓存（见 [CoverProviderEpoch]）。
void evictPrebakedBlur(ImageProvider provider) =>
    _BakedBlurCache.evict(provider);

/// 测试用：清空烘焙缓存。
@visibleForTesting
void clearPrebakedBlurCache() => _BakedBlurCache.clear();

/// 测试用：缓存里的条目数。
@visibleForTesting
int get prebakedBlurCacheLength => _BakedBlurCache._images.length;

/// 把 [source] 按 fit / alignment 铺进 `width × height` 画布并做一次模糊。
Future<ui.Image> _bake(_BakeKey key, ui.Image source) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Size out = Size(key.width.toDouble(), key.height.toDouble());
  final Size imageSize = Size(
    source.width.toDouble(),
    source.height.toDouble(),
  );
  final FittedSizes fitted = applyBoxFit(key.fit, imageSize, out);
  final Rect src = key.alignment.inscribe(
    fitted.source,
    Offset.zero & imageSize,
  );
  final Rect dst = key.alignment.inscribe(
    fitted.destination,
    Offset.zero & out,
  );
  // 与 ImageFiltered 同一种做法：先把图铺进一层，再对整层做模糊（层边界 = 卡片
  // 边界，边缘按引擎默认 tile 模式向外淡出，透出卡片衬底）。直接给 drawImageRect
  // 的 Paint 挂滤镜，边缘行为与几何都和原实现对不上。
  canvas.saveLayer(
    Offset.zero & out,
    Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: key.sigmaPx,
        sigmaY: key.sigmaPx,
        tileMode: key.tileMode,
      ),
  );
  canvas.drawImageRect(
    source,
    src,
    dst,
    Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = key.colorFilter,
  );
  canvas.restore();
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(key.width, key.height).whenComplete(picture.dispose);
}
