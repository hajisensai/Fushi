/// 群唱的用户素材包（folia `customPacks.ts`：自定义头像包 / 表情包）：从共享素材库
/// （`LyricVisualizerAssetStore`，`visualizer_assets/cappella/<包名>/`）列出图片、逐张解码，
/// 交给画家按下标借用。还没解完的那张画内置图（生成头像 / 程序贴纸）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_cover.dart';

/// 素材目录名（样式名，冻结）。
const String kCappellaAssetStyle = 'cappella';

/// 一个包最多用几张（folia 表情包也是有上限的槽位）。
const int kCappellaMaxPackImages = 32;

/// 打开素材库（app 里是数据目录下的共享实例；测试可换成临时目录）。
typedef CappellaAssetStoreOpener = Future<LyricVisualizerAssetStore> Function();

/// 画家读的图片池：[length] 是包里的图数（下标稳定，按文件名排序），[imageAt] 没解完为 null。
abstract interface class CappellaImagePool {
  int get length;
  ui.Image? imageAt(int index);
}

/// 一个素材包的图片池：[load] 换包时退掉旧图；图到手时通知监听者。
class CappellaAssetPack extends ChangeNotifier implements CappellaImagePool {
  CappellaAssetPack({CappellaAssetStoreOpener? openStore})
    : _openStore = openStore ?? LyricVisualizerAssetStore.open;

  final CappellaAssetStoreOpener _openStore;
  final List<LyricVisualizerImageLoader> _loaders =
      <LyricVisualizerImageLoader>[];
  String? _pack;
  int _generation = 0;
  bool _disposed = false;

  /// 当前包名（null = 没加载）。
  String? get pack => _pack;

  @override
  int get length => _loaders.length;

  @override
  ui.Image? imageAt(int index) =>
      index >= 0 && index < _loaders.length ? _loaders[index].image : null;

  /// 加载 [pack]（null = 不用素材包，清空）。同一个包不重复加载。
  void load(String? pack) {
    if (_disposed || pack == _pack) return;
    _pack = pack;
    final int gen = ++_generation;
    final bool had = _loaders.isNotEmpty;
    _clear();
    if (had) notifyListeners();
    if (pack == null) return;
    _list(pack, gen);
  }

  Future<void> _list(String pack, int gen) async {
    List<File> files;
    try {
      final LyricVisualizerAssetStore store = await _openStore();
      files = await store.list(kCappellaAssetStyle, pack);
    } on Object {
      // 素材库打不开（没有数据目录 / 包名不合法）：按空包处理，画内置图。
      return;
    }
    if (_disposed || gen != _generation) return;
    for (final File f in files.take(kCappellaMaxPackImages)) {
      final LyricVisualizerImageLoader loader = LyricVisualizerImageLoader()
        ..addListener(_changed);
      loader.loadProvider(FileImage(f), key: f.path);
      _loaders.add(loader);
    }
    if (_loaders.isNotEmpty) notifyListeners();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    for (final LyricVisualizerImageLoader l in _loaders) {
      l
        ..removeListener(_changed)
        ..dispose();
    }
    _loaders.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _clear();
    super.dispose();
  }
}

/// 固定数量的图片池（测试用 / 已解码好的图）。
class CappellaFixedImagePool implements CappellaImagePool {
  const CappellaFixedImagePool(this.images);

  final List<ui.Image?> images;

  @override
  int get length => images.length;

  @override
  ui.Image? imageAt(int index) =>
      index >= 0 && index < images.length ? images[index] : null;
}

/// 把 [image] 按 contain 画进 [box]（表情图：保持比例、居中）。
void paintCappellaPoolImage(
  Canvas canvas,
  Rect box,
  ui.Image image,
  double opacity, {
  bool cover = false,
}) {
  if (opacity <= 0) return;
  final Size src = Size(image.width.toDouble(), image.height.toDouble());
  if (src.isEmpty) return;
  final FittedSizes fit = applyBoxFit(
    cover ? BoxFit.cover : BoxFit.contain,
    src,
    box.size,
  );
  final Rect from = Alignment.center.inscribe(fit.source, Offset.zero & src);
  final Rect to = Alignment.center.inscribe(fit.destination, box);
  canvas.drawImageRect(
    image,
    from,
    to,
    Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Colors.white.withValues(alpha: opacity.clamp(0.0, 1.0)),
  );
}
