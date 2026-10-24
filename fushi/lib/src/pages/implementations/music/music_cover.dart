import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

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

/// 专辑 / 曲目封面：目录封面文件优先，其次曲目内嵌封面，都没有画音符占位。
class MusicCover extends StatelessWidget {
  const MusicCover({
    super.key,
    this.coverPath,
    this.embeddedFromPath,
    this.size,
    this.borderRadius = 12,
  });

  /// 目录封面 / 缓存封面文件。
  final String? coverPath;

  /// 有内嵌封面的音频文件路径（[coverPath] 为空时用）。
  final String? embeddedFromPath;
  final double? size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: FushiIcon(
          FushiIcons.music,
          color: scheme.onSurfaceVariant,
          size: size == null ? 40 : size! * 0.4,
        ),
      ),
    );
    final String? file = coverPath;
    Widget child;
    if (file != null && File(file).existsSync()) {
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
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: AspectRatio(aspectRatio: 1, child: child),
      ),
    );
  }
}
