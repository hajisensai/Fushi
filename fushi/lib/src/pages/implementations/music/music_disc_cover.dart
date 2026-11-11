/// 专辑封面位上的**盒子 + 盘面**（用户 2026-11-11：「让盒子封面和盘面都显示」）：专辑有
/// 真实的盘面扫描（[MusicDiscArtService]）时，盒子（封面）在左上、整张盘在右下压住盒子一角，
/// 盘面完整可见——不靠悬停，手机上一样看得全（用户 2026-11-11：盘被挡住就没意义）；
/// 桌面悬停时盘只转一下。没有盘面扫描就只画原来的方形封面，不拿封面假造盘面。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/metadata/music_album_release_matcher.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 悬停时盘转过的圈数。
const double kMusicDiscHoverTurns = 0.08;

/// 有盘时盒子（封面）占封面位边长的比例，贴左上角。
const double kMusicDiscCaseFraction = 0.68;

/// 盘的直径占封面位边长的比例，贴右下角、画在盒子上面（整张可见）。
const double kMusicDiscDiameterFraction = 0.62;

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

  /// 解码边长（物理像素），null = 512。
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
              blurRadius: 10,
              offset: const Offset(0, 4),
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

/// 盒子 + 盘的组合（方形封面位里）：盒子贴左上，盘贴右下压在盒子上，两者都不出格。
class MusicDiscCaseAndFace extends StatelessWidget {
  const MusicDiscCaseAndFace({
    super.key,
    required this.cover,
    required this.discPath,
    this.hovering = false,
    this.size,
  });

  /// 盒子：原来的方形封面（带材质框）。
  final Widget cover;
  final String discPath;
  final bool hovering;

  /// 封面位边长（决定盘的解码尺寸）；null 时按布局约束。
  final double? size;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double side = constraints.biggest.shortestSide.isFinite
            ? constraints.biggest.shortestSide
            : (size ?? 200);
        final double caseSide = side * kMusicDiscCaseFraction;
        final double disc = side * kMusicDiscDiameterFraction;
        final double dpr = MediaQuery.devicePixelRatioOf(context);
        return SizedBox.square(
          dimension: side,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                width: caseSide,
                height: caseSide,
                child: cover,
              ),
              Positioned(
                right: 0,
                bottom: 0,
                width: disc,
                height: disc,
                child: MusicDiscFace(
                  imagePath: discPath,
                  hovering: hovering,
                  cacheSize: (disc * dpr).round(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 专辑封面位：有真盘面扫描画「盒子 + 盘」，没有只画 [cover]。查找结果按专辑缓存在
/// [MusicDiscArtService] 里；后台对上 MusicBrainz 发行（[releaseMatcher]）后自动重查。
class MusicDiscArtOrCover extends StatefulWidget {
  const MusicDiscArtOrCover({
    super.key,
    required this.albumUid,
    required this.cover,
    this.trackPath,
    this.mbReleaseId,
    this.releaseMatcher,
    this.hovering = false,
    this.size,
    this.service,
  });

  final String albumUid;

  /// 原来的方形封面（带材质框）；有盘时当盒子画。
  final Widget cover;

  /// 专辑里任一曲目的路径（取它所在目录找本地扫描图）；远程来源的不找。
  final String? trackPath;

  /// 标签里的发行 id。
  final String? mbReleaseId;

  /// 后台自动对号（标签没有发行 id 时用它的结论）。
  final MusicAlbumReleaseMatcher? releaseMatcher;
  final bool hovering;

  /// 封面位边长；null 时按布局约束。
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
  StreamSubscription<String>? _matched;

  MusicDiscArtService get _service =>
      widget.service ?? MusicDiscArtService.instance;

  Future<String?> _lookup() {
    final MusicAlbumReleaseMatcher? matcher = widget.releaseMatcher;
    return _service.resolve(
      albumUid: widget.albumUid,
      albumDir: musicLocalAlbumDirOf(widget.trackPath),
      mbReleaseId: widget.mbReleaseId,
      matchedRelease: matcher == null
          ? null
          : () => matcher.releaseIdOf(widget.albumUid),
    );
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    unawaited(_matched?.cancel());
    _matched = widget.releaseMatcher?.matchedAlbums.listen((String uid) {
      if (uid != widget.albumUid || !mounted) return;
      _service.invalidate(uid);
      setState(() => _art = _lookup());
    });
  }

  @override
  void didUpdateWidget(MusicDiscArtOrCover old) {
    super.didUpdateWidget(old);
    if (old.releaseMatcher != widget.releaseMatcher) _listen();
    if (old.albumUid != widget.albumUid ||
        old.mbReleaseId != widget.mbReleaseId ||
        old.trackPath != widget.trackPath) {
      _art = _lookup();
    }
  }

  @override
  void dispose() {
    unawaited(_matched?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _art,
      builder: (BuildContext context, AsyncSnapshot<String?> snap) {
        final String? path = snap.data;
        if (path == null) return widget.cover;
        return MusicDiscCaseAndFace(
          key: ValueKey<String>('music-disc-art-${widget.albumUid}'),
          cover: widget.cover,
          discPath: path,
          hovering: widget.hovering,
          size: widget.size,
        );
      },
    );
  }
}
