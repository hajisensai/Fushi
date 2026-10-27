import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show formatFushiPlaybackTime;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem, FushiModalSheetFrame, FushiSearchField;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show fushiMotionDuration;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame;
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 点播清单里的一部视频（电脑 `library` 操作的一项）。
@immutable
class VideoRemoteLibraryEntry {
  const VideoRemoteLibraryEntry({
    required this.bookUid,
    required this.title,
    this.collection,
    this.positionMs = 0,
    this.coverVersion,
  });

  factory VideoRemoteLibraryEntry.fromJson(Map<String, dynamic> json) =>
      VideoRemoteLibraryEntry(
        bookUid: json['bookUid']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        collection: json['collection']?.toString(),
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        coverVersion: (json['coverVersion'] as num?)?.toInt(),
      );

  final String bookUid;
  final String title;
  final String? collection;
  final int positionMs;

  /// 电脑上封面文件的版本（修改时间）；null = 没有封面（旧版电脑也不带），
  /// 不去拉图。
  final int? coverVersion;
}

/// 点播清单一行的封面图；返回 null = 这一行只显示图标。
typedef VideoRemoteLibraryCoverResolver =
    ImageProvider? Function(VideoRemoteLibraryEntry entry);

/// `library` 的一页结果。
@immutable
class VideoRemoteLibraryPage {
  const VideoRemoteLibraryPage({
    required this.items,
    required this.total,
    this.currentBookUid,
  });

  factory VideoRemoteLibraryPage.fromJson(Map<String, dynamic> json) =>
      VideoRemoteLibraryPage(
        items: <VideoRemoteLibraryEntry>[
          for (final Object? item in json['items'] as List? ?? <Object?>[])
            if (item is Map)
              VideoRemoteLibraryEntry.fromJson(Map<String, dynamic>.from(item)),
        ],
        total: (json['total'] as num?)?.toInt() ?? 0,
        currentBookUid: json['currentBookUid']?.toString(),
      );

  final List<VideoRemoteLibraryEntry> items;
  final int total;

  /// 电脑上正在放的那部（没开视频为 null）。
  final String? currentBookUid;
}

/// 取一页点播清单：[query] 为搜索词（空 = 全部），[offset] 为起始下标。
typedef VideoRemoteLibraryLoader =
    Future<VideoRemoteLibraryPage> Function(String query, int offset);

/// 点播弹层：列出电脑的视频库（最近播放在前），可搜索；选中返回该视频的
/// `bookUid`，关掉返回 null。网络与错误提示归调用方，本组件只在清单里显示
/// 加载失败。
Future<String?> showVideoRemoteLibrarySheet({
  required BuildContext context,
  required VideoRemoteLibraryLoader load,
  VideoRemoteLibraryCoverResolver? coverFor,
}) => adaptiveModalSheet<String>(
  context: context,
  builder: (BuildContext sheetContext) => VideoRemoteLibrarySheet(
    load: load,
    coverFor: coverFor,
    onPick: (String bookUid) => Navigator.of(sheetContext).pop(bookUid),
  ),
);

/// [showVideoRemoteLibrarySheet] 的内容（单独成组件便于测试）。
class VideoRemoteLibrarySheet extends StatefulWidget {
  const VideoRemoteLibrarySheet({
    super.key,
    required this.load,
    required this.onPick,
    this.coverFor,
  });

  final VideoRemoteLibraryLoader load;
  final ValueChanged<String> onPick;

  /// 每行的封面；null = 全部只显示图标。
  final VideoRemoteLibraryCoverResolver? coverFor;

  @override
  State<VideoRemoteLibrarySheet> createState() =>
      _VideoRemoteLibrarySheetState();
}

class _VideoRemoteLibrarySheetState extends State<VideoRemoteLibrarySheet> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final List<VideoRemoteLibraryEntry> _items = <VideoRemoteLibraryEntry>[];
  String _query = '';
  String? _current;
  int _total = 0;
  bool _loading = false;
  bool _failed = false;

  /// 换搜索词即作废在飞的旧请求（结果按序号丢弃）。
  int _serial = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (value.trim() == _query) return;
      _query = value.trim();
      unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    _items.clear();
    _total = 0;
    await _fetch();
  }

  void _maybeLoadMore() {
    if (_loading || _failed || _items.length >= _total) return;
    if (_scroll.position.extentAfter < 400) unawaited(_fetch());
  }

  Future<void> _fetch() async {
    final int serial = ++_serial;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final VideoRemoteLibraryPage page = await widget.load(
        _query,
        _items.length,
      );
      if (!mounted || serial != _serial) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _current = page.currentBookUid;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || serial != _serial) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.video_remote_library_title,
      leadingIcon: FushiIcons.video,
      maxHeightFactor: 0.86,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSearchField(
            fieldKey: const ValueKey<String>('video-remote-library-search'),
            controller: _search,
            focusNode: _searchFocus,
            hintText: t.video_remote_library_search_hint,
            onChanged: _onQueryChanged,
            onSubmitted: _onQueryChanged,
            onClear: () {
              _search.clear();
              _onQueryChanged('');
            },
          ),
          const SizedBox(height: 8),
          Flexible(child: _list(context)),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (_items.isEmpty) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: FushiCircularProgressIndicator()),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _failed
              ? t.video_remote_error_unreachable
              : _query.isEmpty
              ? t.video_remote_library_empty
              : t.video_remote_library_no_match,
          key: const ValueKey<String>('video-remote-library-empty'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    final bool more = _items.length < _total;
    return FushiEntranceScope(
      replayKey: _query,
      child: ListView.builder(
        key: const ValueKey<String>('video-remote-library-list'),
        controller: _scroll,
        shrinkWrap: true,
        itemCount: _items.length + (more ? 1 : 0),
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: FushiCircularProgressIndicator()),
            );
          }
          return _tile(context, _items[i]);
        }),
      ),
    );
  }

  Widget _tile(BuildContext context, VideoRemoteLibraryEntry entry) {
    final bool current = entry.bookUid == _current;
    final String? collection = entry.collection;
    final String subtitle = <String>[
      if (current) t.video_remote_library_now_playing,
      if (collection != null && collection.isNotEmpty) collection,
      if (!current && entry.positionMs > 0)
        t.video_remote_library_resume(
          time: formatFushiPlaybackTime(
            Duration(milliseconds: entry.positionMs),
          ),
        ),
    ].join(' · ');
    final Widget icon = FushiIcon(
      current ? FushiIcons.playCircle : FushiIcons.video,
    );
    final ImageProvider? cover = widget.coverFor?.call(entry);
    return FushiPressScale(
      child: FushiListItem(
        key: ValueKey<String>('video-remote-library-${entry.bookUid}'),
        selected: current,
        leading: cover == null
            ? icon
            : _VideoRemoteLibraryCover(
                key: ValueKey<String>(
                  'video-remote-library-cover-${entry.bookUid}',
                ),
                image: cover,
                current: current,
                fallback: icon,
              ),
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        onTap: () {
          fushiSelectionHaptic(context);
          widget.onPick(entry.bookUid);
        },
      ),
    );
  }
}

/// 点播行首的封面缩略图：取不到（拉图失败 / 解码失败）时退回图标；正在放的
/// 那部压一层播放标记。
class _VideoRemoteLibraryCover extends StatelessWidget {
  const _VideoRemoteLibraryCover({
    super.key,
    required this.image,
    required this.current,
    required this.fallback,
  });

  final ImageProvider image;
  final bool current;
  final Widget fallback;

  static const double _width = 48;
  static const double _height = 64;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
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
              Image(
                image: image,
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
                        Center(child: fallback),
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
