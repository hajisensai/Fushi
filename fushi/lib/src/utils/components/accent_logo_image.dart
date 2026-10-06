/// 吉祥物 logo 跟随主题强调色的图片源（换色算法见 `logo_accent_tint.dart`）。
///
/// 用在应用内所有画吉祥物的地方：宽屏 rail 品牌位（默认预设图标）、阅读器悬浮球、
/// 桌面系统悬浮球球面。基线紫下 [accentLogoImageProvider] 直接返回原 [AssetImage]，
/// 与改造前逐像素一致；其余强调色解码后在 isolate 里逐像素换色。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/misc/logo_accent_tint.dart';

/// [asset] 按 [accent]（当前 ColorScheme 的 primary）换色后的图片源。
///
/// [decodeWidth] 只在换色路径生效（恒等路径保持调用方原有的解码方式）：换色要
/// 逐像素过一遍，按显示尺寸解码，别把 1024² 原图整张搬进 isolate。
ImageProvider<Object> accentLogoImageProvider(
  String asset, {
  required Color accent,
  int? decodeWidth,
  AssetBundle? bundle,
}) {
  return tintedLogoImageProvider(
    asset,
    tint: LogoAccentTint.fromAccent(accent.toARGB32()),
    decodeWidth: decodeWidth,
    bundle: bundle,
  );
}

/// 同 [accentLogoImageProvider]，参数是已算好的 [tint]（[AccentLogoTintBuilder] 用）。
ImageProvider<Object> tintedLogoImageProvider(
  String asset, {
  required LogoAccentTint tint,
  int? decodeWidth,
  AssetBundle? bundle,
}) {
  if (tint.isIdentity) return AssetImage(asset, bundle: bundle);
  return AccentLogoImage(
    asset,
    tint: tint,
    decodeWidth: decodeWidth,
    bundle: bundle,
  );
}

/// 按 [tint] 换色的 asset 图片。key 即自身（asset + 参数），交给 Flutter 的
/// [ImageCache] 缓存：同一主题反复 build 不会重算。
@immutable
class AccentLogoImage extends ImageProvider<AccentLogoImage> {
  const AccentLogoImage(
    this.assetName, {
    required this.tint,
    this.decodeWidth,
    this.bundle,
  });

  final String assetName;
  final LogoAccentTint tint;
  final int? decodeWidth;
  final AssetBundle? bundle;

  @override
  Future<AccentLogoImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<AccentLogoImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    AccentLogoImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _load(key),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<AccentLogoImage>('Image provider', this),
      ],
    );
  }

  static Future<ImageInfo> _load(AccentLogoImage key) async {
    final ByteData data = await (key.bundle ?? rootBundle).load(key.assetName);
    final ui.Codec codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      targetWidth: key.decodeWidth,
    );
    final ui.Image source;
    try {
      source = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    try {
      return ImageInfo(
        image: await tintLogoImage(source, key.tint),
        debugLabel: key.assetName,
      );
    } finally {
      source.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AccentLogoImage &&
      other.assetName == assetName &&
      other.tint == tint &&
      other.decodeWidth == decodeWidth &&
      other.bundle == bundle;

  @override
  int get hashCode => Object.hash(assetName, tint, decodeWidth, bundle);

  @override
  String toString() =>
      'AccentLogoImage("$assetName", $tint, decodeWidth: $decodeWidth)';
}

/// 把已解码的 [source] 按 [tint] 换色成一张新图（[source] 不释放，归调用方）。
/// 逐像素换色在后台 isolate 跑。
Future<ui.Image> tintLogoImage(ui.Image source, LogoAccentTint tint) async {
  final int width = source.width;
  final int height = source.height;
  final ByteData? raw = await source.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  if (raw == null) {
    throw StateError('logo 像素读取失败');
  }
  final Uint8List tinted = await compute(_tintLogoRgbaEntry, (
    raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
    tint,
  ));
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    tinted,
  );
  final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  try {
    final ui.Codec codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

Uint8List _tintLogoRgbaEntry((Uint8List, LogoAccentTint) args) =>
    tintLogoRgba(args.$1, args.$2);

/// 主题强调色 → [LogoAccentTint]，按「强调色稳定下来」再提交。
///
/// 主题切换带交叉过渡（`fushiThemeAnimationStyle`），过渡期间 `Theme.of` 每帧给出
/// 一个插值出来的 primary；直接跟着换，每帧都会生成一张新换色图（每张都要整图过
/// 一遍 isolate）。这里首帧立即采用，之后强调色变化时等它 [settle] 内不再变化才
/// 提交，一次主题切换只解码最终那一张。
class AccentLogoTintBuilder extends StatefulWidget {
  const AccentLogoTintBuilder({
    super.key,
    required this.accent,
    required this.builder,
    this.settle = const Duration(milliseconds: 80),
  });

  final Color accent;
  final Widget Function(BuildContext context, LogoAccentTint tint) builder;
  final Duration settle;

  @override
  State<AccentLogoTintBuilder> createState() => _AccentLogoTintBuilderState();
}

class _AccentLogoTintBuilderState extends State<AccentLogoTintBuilder> {
  late LogoAccentTint _shown = LogoAccentTint.fromAccent(
    widget.accent.toARGB32(),
  );
  LogoAccentTint? _pending;
  Timer? _timer;

  @override
  void didUpdateWidget(AccentLogoTintBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accent == widget.accent) return;
    final LogoAccentTint next = LogoAccentTint.fromAccent(
      widget.accent.toARGB32(),
    );
    if (next == _shown) {
      _pending = null;
      _timer?.cancel();
      return;
    }
    if (next == _pending) return;
    _pending = next;
    _timer?.cancel();
    _timer = Timer(widget.settle, () {
      final LogoAccentTint? pending = _pending;
      if (!mounted || pending == null) return;
      setState(() {
        _shown = pending;
        _pending = null;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _shown);
}
