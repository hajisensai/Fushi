import 'dart:collection';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/cover_ui/cover_backdrop_color.dart';
import 'package:fushi/src/utils/cover_provider_epoch.dart';

/// 一张封面的探测结论：固有宽高比 + 垫底主色（[seedAspect] 非空 = 已按该宽高比
/// 采过色，[seed] 为 null 表示「采过、不需要底色」）。
class _CoverProbeEntry {
  _CoverProbeEntry(this.aspect);

  double aspect;
  double? seedAspect;
  Color? seed;
}

/// 进程级的封面探测记忆（按 [ImageProvider] 相等性索引，LRU）。
///
/// 为什么需要：网格是懒建的，卡片滚出视口就卸载、滚回来重新挂载。没有记忆时每次
/// 重挂都要 ① 先按「尺寸未知 = 合槽 cover」画一帧，解码回调到了再切 contain +
/// 垫底——滚动途中一排卡整体跳一次布局；② 对不合槽的图重新 `toByteData` 把整张
/// RGBA 从 GPU 读回来算主色——Impeller 上这是一次同步 GPU 回读，正好落在滚动帧
/// 里。宽高比与主色是图本身的属性，算一次就够。
///
/// 失效：换封面（同路径覆盖写）由 [evictLocalCoverCache] 连同 ImageCache 一起清；
/// 驱逐时正在飞的采色按 [CoverProviderEpoch] 作废，不会在驱逐后把旧图主色写回。
/// 万一漏清，只有**宽高比变了**的新图会在解码回调里就地纠正并重新采色；同宽高比
/// 换图（2:3 海报换 2:3 海报）漏清就会一直用旧底色，所以换图路径必须走驱逐。
abstract final class CoverProbeMemo {
  /// 条目上限：每条只有两个数，几百张封面的库也就几十 KB。
  static const int capacity = 2048;

  static final LinkedHashMap<ImageProvider, _CoverProbeEntry> _entries =
      LinkedHashMap<ImageProvider, _CoverProbeEntry>();

  static _CoverProbeEntry? _touch(ImageProvider provider) {
    final _CoverProbeEntry? entry = _entries.remove(provider);
    if (entry != null) _entries[provider] = entry;
    return entry;
  }

  static _CoverProbeEntry _entryFor(ImageProvider provider, double aspect) {
    final _CoverProbeEntry entry =
        _touch(provider) ?? (_entries[provider] = _CoverProbeEntry(aspect));
    if (entry.aspect != aspect) {
      // 同一 provider 解出了别的尺寸（文件被覆盖）：旧主色作废。
      entry
        ..aspect = aspect
        ..seedAspect = null
        ..seed = null;
    }
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    return entry;
  }

  /// 记住的宽高比；没见过为 null。
  static double? aspectOf(ImageProvider provider) => _touch(provider)?.aspect;

  /// 记住的主色：`known` 为假 = 没按 [aspect] 采过。
  static ({bool known, Color? seed}) seedOf(
    ImageProvider provider,
    double aspect,
  ) {
    final _CoverProbeEntry? entry = _touch(provider);
    if (entry == null || entry.seedAspect != aspect) {
      return (known: false, seed: null);
    }
    return (known: true, seed: entry.seed);
  }

  static void rememberAspect(ImageProvider provider, double aspect) =>
      _entryFor(provider, aspect);

  /// 记下按 [aspect] 采到的主色。[epoch] 是开始采样（拿到源图）时的
  /// [CoverProviderEpoch.of]：期间被驱逐过（换了图）就丢弃，不回填旧图的结果。
  static void rememberSeed(
    ImageProvider provider,
    double aspect,
    Color? seed, {
    required int epoch,
  }) {
    if (CoverProviderEpoch.of(provider) != epoch) return;
    _entryFor(provider, aspect)
      ..seedAspect = aspect
      ..seed = seed;
  }

  /// 换图后丢掉该 provider 的记忆，并让正在飞的采色作废（见 [CoverProviderEpoch]）。
  static void evict(ImageProvider provider) {
    CoverProviderEpoch.bump(provider);
    _entries.remove(provider);
  }

  @visibleForTesting
  static void clear() => _entries.clear();

  @visibleForTesting
  static int get length => _entries.length;
}

/// 槽向自适应封面组件的**共享内核**（TODO-2426）。
///
/// `PortraitCoverImage`（竖槽，兼横槽变体）与 `LandscapeCoverImage`（宽幅 hero 槽）
/// 是同一手法的两侧镜像：先拿图片固有宽高比，再决定「直接铺满」还是「模糊垫底 +
/// contain 前景」。两者**渲染分支不同**（overlays 层序 / 前景 alignment+padding /
/// 模糊强度），那是各自槽位的真实产品差异，不该硬合成一个组件；但**取宽高比这段
/// 状态机逐字相同**（ImageStream 生命周期 + 首帧前按合槽渲染 + 解码失败兜底），
/// 那才是真重复。这里抽的就是后者：零渲染行为变化，两侧 build 各自保留。
///
/// 用法：State 类 `with CoverAspectProbe<自己的 Widget>`，实现 [probedImageOf]，
/// 在 build 里读 [coverAspect] / [coverFailed]。生命周期钩子由本 mixin 提供，
/// 子类不要再自己写 `didChangeDependencies` / `didUpdateWidget` / `dispose`。
mixin CoverAspectProbe<T extends StatefulWidget> on State<T> {
  /// 从 widget 取出要探测的图片源。前景 [Image] 必须用同一个 provider——两者共享
  /// 同一 [ImageStream]，宽高比探测因此是零额外解码成本。
  ImageProvider probedImageOf(T widget);

  /// 宽高比为 [aspect] 的图会走「模糊垫底」吗？
  ///
  /// **只有走垫底的图才需要主色底**，所以这也是采样的开关：取主色要 `toByteData`
  /// 把整图 RGBA 拉出来（一张 400×600 就是近 1MB），视频库墙格几十上百张卡全采
  /// 一遍纯属白烧。合槽直接 `cover` 铺满的图压根看不到底色。
  ///
  /// 判据就是子类 build 里那条 mismatch 分支，两处必须同源——各写一份迟早漂移。
  bool needsBackdropSeed(double aspect);

  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;
  bool _failed = false;
  Color? _backdropSeed;

  /// 每次换图自增：异步主色采样回来时对不上号就丢弃（图片已经换了）。
  int _sampleGeneration = 0;

  /// 图片固有宽高比（宽 / 高）；null = 首帧解码前尺寸未知。
  ///
  /// 调用方一律把 null 当「合槽」处理（先按 `cover` 渲染，拿到尺寸再切），避免
  /// 先占位后闪换。
  double? get coverAspect => _aspect;

  /// 加载 / 解码是否已失败（调用方据此走 errorBuilder）。
  bool get coverFailed => _failed;

  /// 垫底底色种子（图片非透明像素的加权平均色），null = 尚未采样完成，或整图
  /// 几乎不透明、压根不需要底色。语义与调制手法见 [sampleCoverBackdropSeed]。
  Color? get coverBackdropSeed => _backdropSeed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveProbedImage();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (probedImageOf(widget) != probedImageOf(oldWidget)) {
      _aspect = null;
      _failed = false;
      _backdropSeed = null;
      _sampleGeneration++;
      _resolveProbedImage();
    }
  }

  @override
  void dispose() {
    _detachListener();
    super.dispose();
  }

  void _detachListener() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _resolveProbedImage() {
    final ImageProvider provider = probedImageOf(widget);
    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(context),
    );
    if (newStream.key == _stream?.key) return;
    _detachListener();
    // 重挂（滚回视口）时直接用记住的结论：首帧就是终态的槽向与底色，不先画一帧
    // cover 再跳 contain，也不再读回像素采色（见 [CoverProbeMemo]）。
    if (_aspect == null) {
      final double? remembered = CoverProbeMemo.aspectOf(provider);
      if (remembered != null) {
        _aspect = remembered;
        final ({bool known, Color? seed}) seed = CoverProbeMemo.seedOf(
          provider,
          remembered,
        );
        if (seed.known) _backdropSeed = seed.seed;
      }
    }
    final ImageStreamListener listener = ImageStreamListener(
      _onImage,
      onError: _onError,
    );
    _stream = newStream;
    _listener = listener;
    newStream.addListener(listener);
  }

  void _onImage(ImageInfo info, bool syncCall) {
    final double aspect = info.image.width / info.image.height;
    final ImageProvider provider = probedImageOf(widget);
    CoverProbeMemo.rememberAspect(provider, aspect);
    if (needsBackdropSeed(aspect)) {
      final ({bool known, Color? seed}) remembered = CoverProbeMemo.seedOf(
        provider,
        aspect,
      );
      if (remembered.known) {
        info.dispose();
        if (!mounted) return;
        if (_aspect != aspect || _backdropSeed != remembered.seed) {
          setState(() {
            _aspect = aspect;
            _failed = false;
            _backdropSeed = remembered.seed;
          });
        }
        return;
      }
      // 主色采样要读像素（异步），而 info.dispose() 之后底层 image 就不能再用了。
      // clone 拿一份自己的句柄，采样完在 [_sampleBackdrop] 里各自释放。
      _sampleBackdrop(
        info.image.clone(),
        _sampleGeneration,
        provider,
        aspect,
        CoverProviderEpoch.of(provider),
      );
    }
    info.dispose();
    if (!mounted || _aspect == aspect) return;
    setState(() {
      _aspect = aspect;
      _failed = false;
    });
  }

  /// 异步取垫底底色。[generation] 用来丢弃过期结果：采样期间 widget 可能已经换图。
  /// 结果按 [provider] 记进 [CoverProbeMemo]（即使本卡已卸载，下次挂载也用得上）；
  /// [epoch] 是拿到这张源图时 provider 的代际号，采样期间被驱逐过就不写 memo。
  Future<void> _sampleBackdrop(
    ui.Image image,
    int generation,
    ImageProvider provider,
    double aspect,
    int epoch,
  ) async {
    try {
      final CoverBackdropSeed? seed = await sampleCoverBackdropSeed(image);
      CoverProbeMemo.rememberSeed(provider, aspect, seed?.color, epoch: epoch);
      if (!mounted || generation != _sampleGeneration) return;
      final Color? color = seed?.color;
      if (_backdropSeed == color) return;
      setState(() => _backdropSeed = color);
    } finally {
      image.dispose();
    }
  }

  void _onError(Object exception, StackTrace? stackTrace) {
    if (!mounted || _failed) return;
    setState(() => _failed = true);
  }
}

/// 「这是一张横图」的判定阈值：宽高比 ≥ 此值算横图。
///
/// **两个槽向组件共用同一个真相源**：抽帧 16:9≈1.78 是横图；刮削海报 2:3≈0.71
/// 与方图 1.0 都不是。此前竖槽组件与宽幅组件各写了一份 `1.2`，同一个概念两处独立
/// 常量 —— 改一个不会带动另一个（TODO-2426）。
const double kCoverLandscapeAspectThreshold = 1.2;

/// 不合槽时压在模糊垫底之上的半透明压暗层颜色（两个槽向组件同值）。
const Color kCoverBackdropDimColor = Color(0x59000000);
