import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart' show FushiDesignTokens;

/// 内嵌封面字节的进程内缓存（按音频路径）。取封面要读整个文件头里的图片块，放后台
/// isolate；同一张专辑的封面在网格 / 专辑页 / 播放条里会被要很多次，缓存最近 64 张。
class MusicEmbeddedCoverCache {
  MusicEmbeddedCoverCache._();

  static final MusicEmbeddedCoverCache instance = MusicEmbeddedCoverCache._();

  static const int _capacity = 64;
  final Map<String, Future<Uint8List?>> _cache = <String, Future<Uint8List?>>{};

  Future<Uint8List?> load(String audioPath) {
    final Future<Uint8List?>? hit = _cache.remove(audioPath);
    if (hit != null) {
      _cache[audioPath] = hit; // 移到最近
      return hit;
    }
    final Future<Uint8List?> loading = Isolate.run(
      () => readMusicEmbeddedCover(audioPath),
    );
    _cache[audioPath] = loading;
    while (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first);
    }
    return loading;
  }
}

/// 音乐页的悬停不放大（用户 2026-10-29：「音乐这鼠标悬浮上去会放大，砍掉」），
/// 只留 3D 倾斜、扫光与投影。音乐里所有 [FushiHoverLift] 一律传它。
const double kMusicHoverLiftScale = 1;

/// 音乐封面统一套专辑「唱片」材质（[ShelfCoverMaterial.glossyAlbum]；用户
/// 2026-10-29：「音乐所有地方也得做材质」）。网格卡由卡壳自己包材质与
/// [FushiHoverLift]，这里管其余单独摆放的封面：
/// - [compact]：列表行 / 播放条的小缩略图，只留圆角、光泽与内描边；
/// - [tilt]：大图（详情页 / 歌词页）自带悬停抬升与 3D 倾斜视差。
Widget musicMaterialCover(
  Widget cover, {
  double? size,
  bool compact = false,
  bool tilt = false,
}) {
  final Widget frame = ShelfCoverMaterialScope(
    material: ShelfCoverMaterial.glossyAlbum,
    child: SizedBox(
      width: size,
      height: size,
      child: AspectRatio(
        aspectRatio: kShelfAlbumAspectRatio,
        child: ShelfCoverFrame(
          density: compact
              ? ShelfCoverDensity.compact
              : ShelfCoverDensity.regular,
          child: cover,
        ),
      ),
    ),
  );
  if (!tilt || compact) return frame;
  return FushiHoverLift(scale: kMusicHoverLiftScale, builder: (_, _) => frame);
}

/// 专辑 / 曲目封面：目录封面文件优先，其次曲目内嵌封面，都没有画音符占位。
/// 在线封面请求头：部分音乐 CDN 对 `Dart/x (dart:io)` 这个默认 UA 一律回 403，
/// 浏览器形态的 UA 才放行（2026-10-29 实测）。
const Map<String, String> kMusicCoverRequestHeaders = <String, String>{
  'User-Agent': 'Mozilla/5.0',
};

class MusicCover extends StatelessWidget {
  const MusicCover({
    super.key,
    this.coverPath,
    this.embeddedFromPath,
    this.size,
    this.borderRadius,
  });

  /// 目录封面 / 缓存封面文件；服务器曲库的封面是 `http(s)://` 地址（服务器侧缩放）。
  final String? coverPath;

  /// 有内嵌封面的音频文件路径（[coverPath] 为空时用）。
  final String? embeddedFromPath;
  final double? size;

  /// 缺省 = 设计令牌的卡内小件圆角（与书架封面框同形）；祖先有
  /// [ShelfCoverMaterialScope]（如专辑网格的 [ShelfCoverMaterial.glossyAlbum]）时
  /// 取材质圆角，被 `ShelfCoverFrame` 包着时内外轮廓重合、角上不露衬底。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget placeholder = ColoredBox(
      color: scheme.secondaryContainer,
      child: Center(
        child: FushiIcon(
          FushiIcons.music,
          color: scheme.onSecondaryContainer,
          size: size == null ? 40 : size! * 0.4,
        ),
      ),
    );
    final String? file = coverPath;
    Widget child;
    if (file != null &&
        (file.startsWith('http://') || file.startsWith('https://'))) {
      // 服务器曲库封面走全应用代理装配（裸 Image.network 会绕过代理）。
      child = Image(
        image: ResizeImage.resizeIfNeeded(
          size == null ? 512 : (size! * 2).round(),
          null,
          AppHttpImage(file, headers: kMusicCoverRequestHeaders),
        ),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else if (file != null && File(file).existsSync()) {
      child = Image.file(
        File(file),
        fit: BoxFit.cover,
        cacheWidth: size == null ? 512 : (size! * 2).round(),
        errorBuilder: (_, _, _) => placeholder,
      );
    } else if (embeddedFromPath != null) {
      child = FutureBuilder<Uint8List?>(
        future: MusicEmbeddedCoverCache.instance.load(embeddedFromPath!),
        builder: (BuildContext context, AsyncSnapshot<Uint8List?> snap) {
          final Uint8List? bytes = snap.data;
          if (bytes == null) return placeholder;
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: size == null ? 512 : (size! * 2).round(),
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      );
    } else {
      child = placeholder;
    }
    return ClipRRect(
      borderRadius:
          borderRadius ??
          (shelfCoverMaterialOf(context) != null
              ? shelfCoverRadius(context)
              : FushiDesignTokens.of(context).radii.cardRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: AspectRatio(aspectRatio: 1, child: child),
      ),
    );
  }
}
