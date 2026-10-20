import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_cover_image.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show formatFushiPlaybackTime;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem, FushiModalSheetFrame, FushiSearchField;
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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
    this.hasCover = false,
  });

  factory VideoRemoteLibraryEntry.fromJson(Map<String, dynamic> json) =>
      VideoRemoteLibraryEntry(
        bookUid: json['bookUid']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        collection: json['collection']?.toString(),
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        hasCover: json['hasCover'] == true,
      );

  final String bookUid;
  final String title;
  final String? collection;
  final int positionMs;

  /// 电脑说这部有封面（旧版电脑不报 = 没有，不去问）。
  final bool hasCover;
}

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

/// 某部视频的封面；null = 没有（画占位）。
typedef VideoRemoteLibraryCoverResolver =
    ImageProvider? Function(VideoRemoteLibraryEntry entry);

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

  /// 封面预览；null = 只画图标（不问电脑要封面）。
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
    return FushiPressScale(
      child: FushiListItem(
        key: ValueKey<String>('video-remote-library-${entry.bookUid}'),
        selected: current,
        leading: VideoRemoteCoverThumb(
          key: ValueKey<String>('video-remote-library-cover-${entry.bookUid}'),
          cover: entry.hasCover ? widget.coverFor?.call(entry) : null,
          width: 48,
          height: 68,
          badge: current ? const _NowPlayingBadge() : null,
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

/// 封面右下角的「正在播放」小角标。
class _NowPlayingBadge extends StatelessWidget {
  const _NowPlayingBadge();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: FushiIcon(FushiIcons.playCircle, size: 16, color: cs.onPrimary),
      ),
    );
  }
}
