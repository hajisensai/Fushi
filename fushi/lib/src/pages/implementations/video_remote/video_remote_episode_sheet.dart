import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem, FushiModalSheetFrame;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show fushiMotionDuration;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame;
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 选集弹层里的一集（电脑 `playbackOptions.episodes` 的一项）。
@immutable
class VideoRemoteEpisodeEntry {
  const VideoRemoteEpisodeEntry({
    required this.index,
    required this.title,
    this.current = false,
    this.hasCover = false,
  });

  factory VideoRemoteEpisodeEntry.fromJson(Map<String, dynamic> json) =>
      VideoRemoteEpisodeEntry(
        index: (json['index'] as num?)?.toInt() ?? 0,
        title: json['title']?.toString() ?? '',
        current: json['current'] == true,
        hasCover: json['hasCover'] == true,
      );

  /// 电脑剧集列表里的下标（`episode` 命令用它）。
  final int index;
  final String title;
  final bool current;

  /// 电脑说这一集有封面（旧版电脑不报 = 没有，不去问）。
  final bool hasCover;
}

/// 某一集的封面；null = 没有（只画图标）。
typedef VideoRemoteEpisodeCoverResolver =
    ImageProvider? Function(VideoRemoteEpisodeEntry entry);

/// 选集弹层：带 16:9 封面的剧集列表，打开时滚到当前集；选中返回该集的
/// [VideoRemoteEpisodeEntry.index]，关掉返回 null。
Future<int?> showVideoRemoteEpisodeSheet({
  required BuildContext context,
  required List<VideoRemoteEpisodeEntry> episodes,
  VideoRemoteEpisodeCoverResolver? coverFor,
}) => adaptiveModalSheet<int>(
  context: context,
  builder: (BuildContext sheetContext) => VideoRemoteEpisodeSheet(
    episodes: episodes,
    coverFor: coverFor,
    onPick: (int index) => Navigator.of(sheetContext).pop(index),
  ),
);

/// [showVideoRemoteEpisodeSheet] 的内容（单独成组件便于测试）。
class VideoRemoteEpisodeSheet extends StatefulWidget {
  const VideoRemoteEpisodeSheet({
    super.key,
    required this.episodes,
    required this.onPick,
    this.coverFor,
  });

  final List<VideoRemoteEpisodeEntry> episodes;
  final ValueChanged<int> onPick;
  final VideoRemoteEpisodeCoverResolver? coverFor;

  /// 每行固定高度：封面 16:9（112×63）+ 上下留白。固定行高才能打开时直接定位到
  /// 当前集，不必先把前面的行都排一遍。
  static const double rowExtent = 79;

  @override
  State<VideoRemoteEpisodeSheet> createState() =>
      _VideoRemoteEpisodeSheetState();
}

class _VideoRemoteEpisodeSheetState extends State<VideoRemoteEpisodeSheet> {
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final int current = widget.episodes.indexWhere(
      (VideoRemoteEpisodeEntry e) => e.current,
    );
    // 当前集上面留一行，让用户看得到上一集。
    _scroll = ScrollController(
      initialScrollOffset: current <= 1
          ? 0
          : (current - 1) * VideoRemoteEpisodeSheet.rowExtent,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.video_episode_list,
      leadingIcon: FushiIcons.playlist,
      maxHeightFactor: 0.86,
      body: widget.episodes.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t.video_episode_list_empty,
                key: const ValueKey<String>('video-remote-episodes-empty'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          : FushiEntranceScope(
              child: ListView.builder(
                key: const ValueKey<String>('video-remote-episode-list'),
                controller: _scroll,
                shrinkWrap: true,
                itemExtent: VideoRemoteEpisodeSheet.rowExtent,
                itemCount: widget.episodes.length,
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int i) =>
                      _tile(context, widget.episodes[i]),
                ),
              ),
            ),
    );
  }

  Widget _tile(BuildContext context, VideoRemoteEpisodeEntry entry) {
    final ImageProvider? cover = entry.hasCover
        ? widget.coverFor?.call(entry)
        : null;
    return FushiPressScale(
      child: FushiListItem(
        key: ValueKey<String>('video-remote-episode-${entry.index}'),
        selected: entry.current,
        leading: _VideoRemoteEpisodeCover(
          key: ValueKey<String>('video-remote-episode-cover-${entry.index}'),
          image: cover,
          current: entry.current,
        ),
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: entry.current
            ? Text(t.video_remote_library_now_playing)
            : null,
        onTap: () {
          fushiSelectionHaptic(context);
          widget.onPick(entry.index);
        },
      ),
    );
  }
}

/// 选集行首的 16:9 封面：没有封面 / 取图失败画图标占位；当前集压一层播放标记。
/// 与点播清单的封面缩略图同一套形状与配色。
class _VideoRemoteEpisodeCover extends StatelessWidget {
  const _VideoRemoteEpisodeCover({
    super.key,
    required this.image,
    required this.current,
  });

  final ImageProvider? image;
  final bool current;

  static const double _width = 112;
  static const double _height = 63;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final Widget placeholder = Center(
      child: FushiIcon(FushiIcons.video, color: scheme.onSurfaceVariant),
    );
    final ImageProvider? cover = image;
    return SizedBox(
      width: _width,
      height: _height,
      // 列表行小图：光面海报材质简化档（用户 2026-10-26：圆角 + 内描边 +
      // 轻光泽，无投影 / 扫光）；墨水屏退回描边框。
      child: ShelfCoverMaterialScope(
        material: ShelfCoverMaterial.glossyPoster,
        child: ShelfCoverFrame(
          density: ShelfCoverDensity.compact,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColoredBox(color: scheme.containerOf(FushiTone.neutral)),
              if (cover == null)
                placeholder
              else
                Image(
                  // 按显示尺寸解码，长列表不会把整张剧照解进内存。
                  image: ResizeImage.resizeIfNeeded(
                    (_width * dpr).round(),
                    null,
                    cover,
                  ),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder:
                      (
                        BuildContext context,
                        Widget child,
                        int? frame,
                        bool wasSynchronouslyLoaded,
                      ) {
                        if (wasSynchronouslyLoaded) return child;
                        return AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: fushiMotionDuration(
                            context,
                            const Duration(milliseconds: 200),
                          ),
                          child: child,
                        );
                      },
                  errorBuilder:
                      (BuildContext context, Object _, StackTrace? __) =>
                          placeholder,
                ),
              if (current)
                ColoredBox(
                  color: scheme.scrim.withValues(alpha: 0.35),
                  child: Center(
                    child: FushiIcon(
                      FushiIcons.playCircle,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
