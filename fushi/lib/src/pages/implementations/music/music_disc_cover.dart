/// 专辑封面位上的**真盘面图**（用户 2026-11-11）：专辑有真实的盘面扫描
/// （[MusicDiscArtService]）就把封面位换成那张盘——裁成圆、落投影、悬停时转一点；
/// 没有就保持原来的方形专辑封面，不拿专辑封面假造盘面。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 悬停时盘转过的圈数。
const double kMusicDiscHoverTurns = 0.08;

/// 盘面图在方形封面位里占的边长比例（四周留出投影）。
const double kMusicDiscArtInset = 0.94;

/// 一张真盘面扫描：圆形裁切 + 投影；[hovering] 时转一个小角度（时长走动效令牌，
/// 系统关动画时直接到位）。
class MusicDiscFace extends StatelessWidget {
  const MusicDiscFace({
    super.key,
    required this.imagePath,
    this.hovering = false,
    this.cacheSize,
  });

  final String imagePath;
  final bool hovering;

  /// 解码边长（逻辑像素 × 2 由调用方给，null = 512）。
  final int? cacheSize;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: AnimatedRotation(
          turns: hovering ? kMusicDiscHoverTurns : 0,
          duration: fushiMotionDuration(context, FushiMotion.long),
          curve: Curves.easeOutCubic,
          child: ClipOval(
            child: Image.file(
              File(imagePath),
              fit: BoxFit.cover,
              cacheWidth: cacheSize ?? 512,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// 专辑封面位：有真盘面图画盘，没有画 [fallback]（原方形封面）。查找结果按专辑
/// 缓存在 [MusicDiscArtService] 里，滚动回来不会重查。
class MusicDiscArtOrCover extends StatefulWidget {
  const MusicDiscArtOrCover({
    super.key,
    required this.albumUid,
    required this.fallback,
    this.trackPath,
    this.mbReleaseId,
    this.hovering = false,
    this.size,
    this.service,
  });

  final String albumUid;

  /// 专辑里任一曲目的路径（取它所在目录找本地扫描图）；远程来源的不找。
  final String? trackPath;
  final String? mbReleaseId;
  final Widget fallback;
  final bool hovering;

  /// 显示边长（决定解码尺寸）；null 时按 256 解码。
  final double? size;

  /// 测试注入；缺省用 [MusicDiscArtService.instance]。
  final MusicDiscArtService? service;

  @override
  State<MusicDiscArtOrCover> createState() => _MusicDiscArtOrCoverState();
}

/// 本地目录才找扫描图（`sftp://` 等远程路径不碰文件系统）。
String? musicLocalAlbumDirOf(String? trackPath) {
  if (trackPath == null || trackPath.contains('://')) return null;
  return p.dirname(trackPath);
}

class _MusicDiscArtOrCoverState extends State<MusicDiscArtOrCover> {
  late Future<String?> _art = _lookup();

  Future<String?> _lookup() =>
      (widget.service ?? MusicDiscArtService.instance).resolve(
        albumUid: widget.albumUid,
        albumDir: musicLocalAlbumDirOf(widget.trackPath),
        mbReleaseId: widget.mbReleaseId,
      );

  @override
  void didUpdateWidget(MusicDiscArtOrCover old) {
    super.didUpdateWidget(old);
    if (old.albumUid != widget.albumUid ||
        old.mbReleaseId != widget.mbReleaseId ||
        old.trackPath != widget.trackPath) {
      _art = _lookup();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _art,
      builder: (BuildContext context, AsyncSnapshot<String?> snap) {
        final String? path = snap.data;
        if (path == null) return widget.fallback;
        final double? size = widget.size;
        return Center(
          child: FractionallySizedBox(
            widthFactor: kMusicDiscArtInset,
            heightFactor: kMusicDiscArtInset,
            child: MusicDiscFace(
              key: ValueKey<String>('music-disc-art-${widget.albumUid}'),
              imagePath: path,
              hovering: widget.hovering,
              cacheSize: size == null ? 512 : (size * 2).round(),
            ),
          ),
        );
      },
    );
  }
}
