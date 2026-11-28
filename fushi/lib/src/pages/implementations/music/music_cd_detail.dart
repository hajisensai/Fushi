/// CD 专辑详情（设计稿 #music「CD 详情：从色块原位弹簧放大」，照 W 原型
/// `w_proto.html` 的 `openDetail`）：
///
/// - 点带盘面图的专辑色块，面板从色块原位用弹簧放大展开，关闭时缩回原位；
/// - 左侧 hero：淡色大字标题垫底、从右侧滑入，封面落下，唱片从封面后面滑出并慢速
///   旋转（「减少动态效果」/ 墨水屏下不转、不放动画，直接落位）；
/// - 右侧：「专辑 · CD」→ 标题 → 艺人 → 年份 / 格式 / 曲数 / 总时长 → 播放 + 随机 →
///   轨道表。多碟按 DISC 分组（碟号大数字），同一专辑有多个版本（不同目录 / 格式）
///   时按版本分开列（[musicAlbumVersions]）；
/// - 窄窗（< 760）全屏、hero 在上。
///
/// 只有带盘面扫描图的专辑走这里（[MusicDiscArtIndex]）；其余专辑仍是 [MusicAlbumPage]。
/// 面板右上角另有「专辑详情」进完整专辑页（歌词 / 对号 / 加入歌单等低频操作）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_album_versions.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show openMusicPlayerPage;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart'
    show musicAlbumBadges;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_disc_face.dart';
import 'package:fushi/src/pages/implementations/music/music_queue_panel.dart'
    show musicQueueDurationLabel;
import 'package:fushi/src/pages/implementations/music/music_track_list.dart'
    show formatMusicDuration;
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isEinkTheme;
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, fushiCoverBlockRadius, FushiCoverBlockSize;
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart'
    show fushiGeneratedCoverHue;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 窄于这个宽度时面板全屏、hero 在上（W 原型 `full = vw < 760`）。
const double kMusicCdDetailFullScreenWidth = 760;

/// 盘面标签的碟号大字：拼贴设计稿 M3 的固定版式值（介于 headlineSmall 24 与
/// headlineMedium 28 之间，FushiTypeRoles 没有这一阶）。
const double _kDiscNumeralSize = 26;

/// 面板在 [viewport] 里的目标矩形（W 原型：桌面 ≤1160×740 居中、四周至少留 24；
/// 窄窗全屏）。纯函数。
Rect musicCdDetailPanelRect(Size viewport) {
  if (viewport.width < kMusicCdDetailFullScreenWidth) {
    return Offset.zero & viewport;
  }
  final double w = math.min(1160, viewport.width - 48);
  final double h = math.min(740, viewport.height - 48);
  return Rect.fromLTWH(
    (viewport.width - w) / 2,
    (viewport.height - h) / 2,
    w,
    math.max(0, h),
  );
}

/// 打开 CD 详情。[origin] 是被点色块的全局矩形（面板从这里放大、关闭时缩回）；
/// null 时从屏幕中央一个小矩形放大。
Future<void> showMusicCdDetail({
  required BuildContext context,
  required MusicAlbumRow album,
  required List<MusicTrackRow> tracks,
  required String? embeddedCoverPath,
  required String discArtPath,
  required Rect? origin,
  required VoidCallback onOpenAlbumPage,
}) {
  final NavigatorState navigator = Navigator.of(context);
  final RenderObject? overlay = navigator.overlay?.context.findRenderObject();
  Rect? localOrigin;
  if (origin != null && overlay is RenderBox) {
    localOrigin = Rect.fromPoints(
      overlay.globalToLocal(origin.topLeft),
      overlay.globalToLocal(origin.bottomRight),
    );
  }
  final FushiMotionScheme motion = FushiMotionScheme.of(context);
  return navigator.push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      transitionDuration: motion.spatialSlow.duration,
      reverseTransitionDuration: motion.spatialDefault.duration,
      pageBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) => MusicCdDetailPanel(
            animation: animation,
            origin: localOrigin,
            openCurve: motion.spatialSlow.curve,
            closeCurve: motion.spatialDefault.curve,
            album: album,
            tracks: tracks,
            embeddedCoverPath: embeddedCoverPath,
            discArtPath: discArtPath,
            onOpenAlbumPage: onOpenAlbumPage,
          ),
    ),
  );
}

/// CD 详情面板（[showMusicCdDetail] 的路由内容）。[animation] 是路由动画：面板
/// 矩形由 [origin] 插值到 [musicCdDetailPanelRect]。
class MusicCdDetailPanel extends ConsumerStatefulWidget {
  const MusicCdDetailPanel({
    required this.animation,
    required this.origin,
    required this.openCurve,
    required this.closeCurve,
    required this.album,
    required this.tracks,
    required this.embeddedCoverPath,
    required this.discArtPath,
    required this.onOpenAlbumPage,
    super.key,
  });

  final Animation<double> animation;
  final Rect? origin;
  final Curve openCurve;
  final Curve closeCurve;
  final MusicAlbumRow album;

  /// 已按碟号 / 轨号排好的曲目。
  final List<MusicTrackRow> tracks;
  final String? embeddedCoverPath;
  final String discArtPath;
  final VoidCallback onOpenAlbumPage;

  @override
  ConsumerState<MusicCdDetailPanel> createState() => _MusicCdDetailPanelState();
}

class _MusicCdDetailPanelState extends ConsumerState<MusicCdDetailPanel>
    with TickerProviderStateMixin {
  /// hero 里封面落下、唱片滑出、大字滑入的编排（一条时间轴，各段 Interval）。
  late final AnimationController _intro = AnimationController(vsync: this);

  /// 唱片慢速旋转（减少动态效果时不转）。
  late final AnimationController _spin = AnimationController(vsync: this);

  late final CurvedAnimation _panel = CurvedAnimation(
    parent: widget.animation,
    curve: widget.openCurve,
    reverseCurve: widget.closeCurve,
  );

  late final List<MusicAlbumVersion> _versions = musicAlbumVersions(
    widget.tracks,
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool motion = fushiMotionEnabled(context);
    if (!_started) {
      _started = true;
      _intro.duration = fushiMotionDuration(
        context,
        FushiMotion.long + FushiMotion.medium,
      );
      unawaited(_intro.forward());
    }
    if (motion && !_spin.isAnimating) {
      // W 原型 14 s 一圈（`.spin`）：取环境漂移档的三分之一多一点。
      _spin.duration = FushiMotion.ambientDrift * 0.35;
      unawaited(_spin.repeat());
    } else if (!motion && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _panel.dispose();
    _intro.dispose();
    _spin.dispose();
    super.dispose();
  }

  MusicPlaySource get _source => MusicPlaySource.album(
    widget.album.albumUid,
    title: widget.album.title,
    cover: widget.album.coverPath,
  );

  void _play(
    List<MusicTrackRow> tracks, {
    int? start,
    bool shuffle = false,
    bool openPlayer = false,
  }) {
    if (tracks.isEmpty) return;
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    unawaited(
      engine.playQueue(
        <MusicPlayItem>[
          for (final MusicTrackRow t in tracks)
            musicPlayItemOf(
              t,
              album: widget.album,
              trackPathOf: musicTrackPathsOf(widget.tracks),
            ),
        ],
        startIndex: start,
        context: MusicQueueContext.album,
        shuffle: shuffle,
        source: _source,
      ),
    );
    // 「播放全部 / 随机播放」= 开始听这张：直接进播放页（返回回到 CD 详情）。点单曲
    // 只换曲，不离开详情。
    if (openPlayer) openMusicPlayerPage(context);
  }

  void _close() => unawaited(Navigator.of(context).maybePop());

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: FocusScope(
        autofocus: true,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size viewport = constraints.biggest;
            final Rect target = musicCdDetailPanelRect(viewport);
            final bool full = viewport.width < kMusicCdDetailFullScreenWidth;
            final Rect origin =
                widget.origin ??
                Rect.fromCenter(
                  center: target.center,
                  width: target.width * 0.3,
                  height: target.height * 0.3,
                );
            final double originRadius = fushiCoverBlockRadius(
              FushiCoverBlockSize.regular,
              origin.height,
            );
            final double targetRadius = full ? 0 : 40;
            final Widget content = SizedBox(
              width: target.width,
              height: target.height,
              child: _CdPalette(
                album: widget.album,
                embeddedCoverPath: widget.embeddedCoverPath,
                builder: (BuildContext context, FushiCoverBlockColors colors) =>
                    _buildContent(context, target.size, full, colors),
              ),
            );
            return AnimatedBuilder(
              animation: _panel,
              child: content,
              builder: (BuildContext context, Widget? child) {
                final double t = _panel.value;
                final Rect rect = Rect.lerp(origin, target, t)!;
                final double radius =
                    originRadius + (targetRadius - originRadius) * t;
                return Stack(
                  children: <Widget>[
                    Positioned.fromRect(
                      rect: rect,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          math.max(0, radius),
                        ),
                        child: FittedBox(fit: BoxFit.fill, child: child),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    Size size,
    bool phone,
    FushiCoverBlockColors colors,
  ) {
    final double heroW = phone ? size.width : size.width * 0.47;
    final double heroH = phone
        ? math.min(size.height * 0.42, size.width * 0.86)
        : size.height;
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    return Material(
      color: colors.container,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: colors.onContainer),
        child: IconTheme.merge(
          data: IconThemeData(color: colors.onContainer),
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                width: heroW,
                height: heroH,
                child: _buildHero(
                  context,
                  Size(heroW, heroH),
                  phone,
                  colors,
                  panelHeight: size.height,
                  panelWidth: size.width,
                ),
              ),
              Positioned(
                left: phone ? 0 : heroW,
                right: 0,
                top: phone ? heroH : 0,
                bottom: 0,
                child: _buildBody(context, phone, colors),
              ),
              PositionedDirectional(
                top: 18,
                end: 18,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: <Widget>[
                    FushiIconButton(
                      key: const ValueKey<String>('music-cd-open-album'),
                      icon: FushiIcons.info,
                      tooltip: t.music_cd_open_album,
                      backgroundColor: Colors.black.withValues(alpha: 0.3),
                      enabledColor: colors.onContainer,
                      onTap: widget.onOpenAlbumPage,
                    ),
                    FushiIconButton(
                      key: const ValueKey<String>('music-cd-close'),
                      icon: FushiIcons.close,
                      tooltip: l10n.closeButtonTooltip,
                      backgroundColor: Colors.black.withValues(alpha: 0.3),
                      enabledColor: colors.onContainer,
                      onTap: _close,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// hero：淡色大字垫底（从右侧滑入）、唱片在封面后面滑出并旋转、封面落下。
  Widget _buildHero(
    BuildContext context,
    Size hero,
    bool phone,
    FushiCoverBlockColors colors, {
    required double panelHeight,
    required double panelWidth,
  }) {
    final double s = phone
        ? math.min(panelWidth * 0.5, hero.height * 0.62)
        : math.min(hero.width * 0.54, panelHeight * 0.46);
    final double cx = phone ? panelWidth * 0.1 : hero.width * 0.1;
    final double cy = phone ? hero.height * 0.2 : panelHeight * 0.5 - s * 0.62;
    final Offset discOut = phone
        ? Offset(s * 0.74, s * 0.08)
        : Offset(s * 0.56, s * 0.2);
    final FushiMotionScheme motion = FushiMotionScheme.of(context);
    final Animation<double> cover = CurvedAnimation(
      parent: _intro,
      curve: Interval(0.08, 0.7, curve: motion.spatialDefault.curve),
    );
    final Animation<double> disc = CurvedAnimation(
      parent: _intro,
      curve: Interval(0.25, 1, curve: motion.spatialSlow.curve),
    );
    final Animation<double> title = CurvedAnimation(
      parent: _intro,
      curve: Interval(0, 0.9, curve: motion.effectsSlow.curve),
    );
    final double titleSlide = phone ? 140 : 260;
    return ColoredBox(
      color: Color.alphaBlend(
        Colors.black.withValues(alpha: 0.22),
        colors.container,
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          Positioned.fill(
            left: 16,
            top: 16,
            right: 16,
            bottom: 16,
            child: AnimatedBuilder(
              animation: title,
              builder: (BuildContext context, Widget? child) =>
                  Transform.translate(
                    offset: Offset(titleSlide * (1 - title.value), 0),
                    child: child,
                  ),
              child: Opacity(
                opacity: 0.24,
                child: FushiFitTitle(
                  text: widget.album.title,
                  color: colors.accent,
                  maxSize: phone ? panelWidth * 0.34 : panelHeight * 0.4,
                  minSize: 14,
                ),
              ),
            ),
          ),
          Positioned(
            left: cx,
            top: cy,
            width: s,
            height: s,
            child: AnimatedBuilder(
              animation: disc,
              builder: (BuildContext context, Widget? child) {
                final double v = disc.value;
                return Transform.translate(
                  offset: discOut * v,
                  child: Transform.rotate(
                    angle: -40 * math.pi / 180 * (1 - v),
                    child: child,
                  ),
                );
              },
              child: RotationTransition(
                turns: _spin,
                child: _DiscFace(path: widget.discArtPath),
              ),
            ),
          ),
          Positioned(
            left: cx,
            top: cy,
            width: s,
            height: s,
            child: AnimatedBuilder(
              animation: cover,
              builder: (BuildContext context, Widget? child) {
                final double v = cover.value;
                return Transform.translate(
                  offset: Offset(0, 60 * (1 - v)),
                  child: Transform.rotate(
                    angle: (-16 + 10 * v) * math.pi / 180,
                    child: Transform.scale(
                      scale: 0.55 + 0.45 * v,
                      child: child,
                    ),
                  ),
                );
              },
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(26)),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Color(0x80000000),
                      offset: Offset(0, 18),
                      blurRadius: 44,
                    ),
                  ],
                ),
                child: MusicCover(
                  coverPath: widget.album.coverPath,
                  embeddedFromPath: widget.embeddedCoverPath,
                  title: widget.album.title,
                  borderRadius: const BorderRadius.all(Radius.circular(26)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 右侧（窄窗在下）：抬头 → 标题 → 艺人 → 信息胶囊 → 播放 / 随机 → 轨道表。
  Widget _buildBody(
    BuildContext context,
    bool phone,
    FushiCoverBlockColors colors,
  ) {
    final MusicAlbumRow album = widget.album;
    final MusicAlbumVersion first = _versions.isEmpty
        ? const MusicAlbumVersion(label: '', tracks: <MusicTrackRow>[])
        : _versions.first;
    final bool multiVersion = _versions.length > 1;
    final List<String> badges = musicAlbumBadges(first.tracks).badges;
    final int totalMs = first.totalDurationMs;
    final List<String> pills = <String>[
      ?_releaseYear(album.releaseDate),
      if (multiVersion)
        t.music_cd_versions_count(count: _versions.length)
      else if (badges.isNotEmpty)
        badges.first,
      t.music_tracks_count(count: first.tracks.length),
      if (totalMs > 0) musicQueueDurationLabel(Duration(milliseconds: totalMs)),
    ];
    final List<Widget> head = <Widget>[
      Text(
        t.music_cd_kicker,
        style: context.fushiType.labelMedium.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
          color: colors.accent,
        ),
      ),
      const SizedBox(height: 10),
      Text(
        album.title,
        style: TextStyle(
          fontSize: phone ? 28 : 44,
          fontWeight: FontWeight.w900,
          height: 1.02,
          letterSpacing: -0.4,
          color: colors.onContainer,
        ),
      ),
      if (album.albumArtistCredit case final String artist) ...<Widget>[
        const SizedBox(height: 10),
        Text(
          artist,
          style: context.fushiType.titleMedium.copyWith(
            fontWeight: FontWeight.w600,
            color: colors.onContainer,
          ),
        ),
      ],
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final String pill in pills)
            DecoratedBox(
              decoration: ShapeDecoration(
                color: colors.onContainer.withValues(alpha: 0.1),
                shape: const StadiumBorder(),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 7,
                ),
                child: Text(
                  pill,
                  style: context.fushiType.labelMedium.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: <Widget>[
          FushiPressScale(
            child: FushiFilledButton.icon(
              key: const ValueKey<String>('music-cd-play'),
              size: FushiButtonSize.m,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.container,
              ),
              onPressed: first.tracks.isEmpty
                  ? null
                  : () => _play(first.tracks, openPlayer: true),
              icon: const FushiIcon(FushiIcons.play),
              label: Text(t.music_play_all),
            ),
          ),
          FushiPressScale(
            child: FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('music-cd-shuffle'),
              size: FushiButtonSize.m,
              style: FilledButton.styleFrom(
                backgroundColor: colors.onContainer.withValues(alpha: 0.1),
                foregroundColor: colors.onContainer,
              ),
              onPressed: first.tracks.isEmpty
                  ? null
                  : () => _play(first.tracks, shuffle: true, openPlayer: true),
              icon: const FushiIcon(FushiIcons.shuffle),
              label: Text(t.music_shuffle_play),
            ),
          ),
        ],
      ),
      const SizedBox(height: 22),
    ];
    final List<Widget> rows = <Widget>[...head];
    for (int v = 0; v < _versions.length; v++) {
      final MusicAlbumVersion version = _versions[v];
      if (multiVersion) {
        rows.add(
          _VersionHeader(
            key: ValueKey<String>('music-cd-version-$v'),
            label: t.music_cd_version_heading(n: v + 1, label: version.label),
            count: version.tracks.length,
            colors: colors,
          ),
        );
      }
      final Map<int?, List<MusicTrackRow>> discs = version.discs;
      final bool multiDisc = discs.length > 1;
      for (final MapEntry<int?, List<MusicTrackRow>> d in discs.entries) {
        if (multiDisc) {
          rows.add(
            _DiscHeader(
              key: ValueKey<String>('music-cd-disc-$v-${d.key}'),
              number: d.key,
              count: d.value.length,
              colors: colors,
            ),
          );
        }
        for (int i = 0; i < d.value.length; i++) {
          final MusicTrackRow track = d.value[i];
          rows.add(
            _TrackLine(
              key: ValueKey<String>('music-cd-track-${track.trackUid}'),
              number: track.trackNo ?? i + 1,
              track: track,
              colors: colors,
              onTap: () =>
                  _play(version.tracks, start: version.tracks.indexOf(track)),
            ),
          );
        }
      }
    }
    return FushiEntranceScope(
      child: ListView.builder(
        key: const ValueKey<String>('music-cd-body'),
        padding: phone
            ? const EdgeInsets.fromLTRB(20, 22, 20, 40)
            : const EdgeInsets.fromLTRB(40, 44, 40, 40),
        itemCount: rows.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => rows[i],
        ),
      ),
    );
  }
}

/// 发行日期里的年份；没有或不是年份开头为 null。
String? _releaseYear(String? releaseDate) =>
    releaseDate == null ? null : RegExp(r'^\d{4}').stringMatch(releaseDate);

/// 面板配色：与专辑色块同一套（封面取色 → [FushiCoverBlockColors]；没封面按标题
/// 色相；墨水屏中性色）。取色走色块同一份缓存（[coverColorSchemeCache]），从色块
/// 点进来时一般已算好。
class _CdPalette extends StatefulWidget {
  const _CdPalette({
    required this.album,
    required this.embeddedCoverPath,
    required this.builder,
  });

  final MusicAlbumRow album;
  final String? embeddedCoverPath;
  final Widget Function(BuildContext context, FushiCoverBlockColors colors)
  builder;

  @override
  State<_CdPalette> createState() => _CdPaletteState();
}

class _CdPaletteState extends State<_CdPalette> {
  ImageProvider? _for;
  Brightness? _brightness;
  ColorScheme? _scheme;

  void _resolve(ImageProvider? image, Brightness brightness) {
    if (image == _for && brightness == _brightness) return;
    _for = image;
    _brightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    unawaited(
      coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
        if (!mounted || _for != image || _brightness != brightness) return;
        setState(() => _scheme = s);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool eink = isEinkTheme(context);
    final bool hasCover = musicHasCoverSource(
      widget.album.coverPath,
      widget.embeddedCoverPath,
    );
    return MusicCoverTintSource(
      coverPath: widget.album.coverPath,
      embeddedFromPath: widget.embeddedCoverPath,
      builder: (BuildContext context, ImageProvider? tint) {
        _resolve(eink ? null : tint, theme.brightness);
        final FushiCoverBlockColors colors = !hasCover && !eink
            ? FushiCoverBlockColors.fromHue(
                theme,
                fushiGeneratedCoverHue(widget.album.title),
              )
            : FushiCoverBlockColors.resolve(theme, _scheme);
        return widget.builder(context, colors);
      },
    );
  }
}

/// 唱片盘面：真实扫描图按量出的印刷区对正（[MusicDiscFace]），带投影。
class _DiscFace extends StatelessWidget {
  const _DiscFace({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => MusicDiscFace(
    path: path,
    shadows: const <BoxShadow>[
      BoxShadow(
        color: Color(0x99000000),
        offset: Offset(0, 20),
        blurRadius: 50,
      ),
    ],
  );
}

/// 版本分组头（「版本 1 · 目录名」+ 曲数）。
class _VersionHeader extends StatelessWidget {
  const _VersionHeader({
    required this.label,
    required this.count,
    required this.colors,
    super.key,
  });

  final String label;
  final int count;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 6),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: colors.onContainer.withValues(alpha: 0.07),
        borderRadius: const BorderRadius.all(Radius.circular(14)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: DefaultTextStyle.merge(
          style: context.fushiType.labelMedium.copyWith(
            fontWeight: FontWeight.w800,
            color: colors.accent,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(t.music_tracks_count(count: count)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 碟分组头：小字「DISC」+ 大号碟号 + 曲数。
class _DiscHeader extends StatelessWidget {
  const _DiscHeader({
    required this.number,
    required this.count,
    required this.colors,
    super.key,
  });

  final int? number;
  final int count;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Semantics(
      header: true,
      label: t.music_disc_label(n: number ?? 0),
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          spacing: 8,
          children: <Widget>[
            Text(
              t.music_cd_disc_kicker,
              style: context.fushiType.labelSmall.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: colors.accent,
              ),
            ),
            Text(
              number == null ? '—' : '$number',
              style: context.fushiType.headlineSmall.copyWith(
                fontSize: _kDiscNumeralSize,
                fontWeight: FontWeight.w900,
                color: colors.accent,
              ),
            ),
            const Spacer(),
            Text(
              t.music_tracks_count(count: count),
              style: context.fushiType.labelMedium.copyWith(
                color: colors.accent,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 轨道表的一行：轨号 · 曲名 · 时长；悬停 / 焦点铺浅底，点按从这一首播放该版本。
class _TrackLine extends StatelessWidget {
  const _TrackLine({
    required this.number,
    required this.track,
    required this.colors,
    required this.onTap,
    super.key,
  });

  final int number;
  final MusicTrackRow track;
  final FushiCoverBlockColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const BorderRadius radius = BorderRadius.all(Radius.circular(18));
    final TextStyle figures = TextStyle(
      color: colors.accent,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return FushiPressScale(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          hoverColor: colors.onContainer.withValues(alpha: 0.08),
          focusColor: colors.onContainer.withValues(alpha: 0.14),
          highlightColor: colors.onContainer.withValues(alpha: 0.1),
          splashColor: colors.onContainer.withValues(alpha: 0.1),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              spacing: 14,
              children: <Widget>[
                SizedBox(
                  width: 24,
                  child: Text(
                    '$number',
                    textAlign: TextAlign.end,
                    style: figures.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Expanded(
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodyMedium,
                  ),
                ),
                Text(formatMusicDuration(track.durationMs), style: figures),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
