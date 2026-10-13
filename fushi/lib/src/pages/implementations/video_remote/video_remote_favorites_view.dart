import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiChromeReveal;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show formatFushiPlaybackTime;
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiCheckbox;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 收藏查词回调：第 [charOffset] 个字（grapheme 下标）+ 查词弹框的全局锚点矩形
/// [anchor]（同 [VideoRemoteLookupCallback]；键盘查词为 [Rect.zero]）。
typedef VideoRemoteFavoriteLookupCallback =
    void Function(VideoRemoteFavoriteEntry entry, int charOffset, Rect anchor);

/// 收藏列表（纯展示）：顶部「当前视频 / 全部视频」连接式按钮组 + 搜索，下面
/// 卡片列表错峰进场。长按卡片进入多选，选中后批量取消收藏。
///
/// [entries] 是调用方按 [scope] 取回的那一批；搜索在本组件里按
/// [matchesMediaSearch] 同口径过滤（主轨 / 副轨 / 视频名任一命中）。多选与搜索词
/// 是本组件的临时状态（旋转时由调用方用 GlobalKey 保住）。
class VideoRemoteFavoritesView extends StatefulWidget {
  const VideoRemoteFavoritesView({
    super.key,
    required this.entries,
    required this.scope,
    required this.onOpen,
    required this.onRemove,
    this.onLookup,
    this.padding = EdgeInsets.zero,
    this.loading = false,
    this.lookupHighlight,
  });

  final List<VideoRemoteFavoriteEntry> entries;

  /// 这一页的范围（范围选择器由外层脚手架固定在翻页之上，不随页滑动）。
  final VideoRemoteFavoritesScope scope;

  /// 点卡片：回放这句（跨视频由页面先确认）。
  final ValueChanged<VideoRemoteFavoriteEntry> onOpen;

  /// 批量取消收藏（按 [VideoRemoteFavoriteEntry.id]）。
  final ValueChanged<Set<String>> onRemove;

  /// 点句子里的字查词；null = 句子只显示，不逐字可点。
  final VideoRemoteFavoriteLookupCallback? onLookup;

  /// 被浮动栏遮住的边距。
  final EdgeInsets padding;

  /// 正在取这一批（空列表时显示加载中而不是空态）。
  final bool loading;

  /// 正在查的词（只画在它所属的那张卡上）；null = 不高亮。
  final VideoRemoteLookupHighlight? lookupHighlight;

  @override
  State<VideoRemoteFavoritesView> createState() =>
      _VideoRemoteFavoritesViewState();
}

class _VideoRemoteFavoritesViewState extends State<VideoRemoteFavoritesView> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'video-remote-search');
  final Set<String> _selected = <String>{};
  bool _selecting = false;

  @override
  void didUpdateWidget(covariant VideoRemoteFavoritesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entries, widget.entries)) {
      final Set<String> ids = <String>{
        for (final VideoRemoteFavoriteEntry e in widget.entries) e.id,
      };
      _selected.removeWhere((String id) => !ids.contains(id));
      if (_selected.isEmpty) _selecting = false;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<VideoRemoteFavoriteEntry> get _visible => filterByMediaSearch(
    widget.entries,
    _query.text,
    (VideoRemoteFavoriteEntry e) => <String>[
      e.text,
      e.secondaryText ?? '',
      e.videoTitle,
    ],
  );

  void _toggle(VideoRemoteFavoriteEntry entry) {
    setState(() {
      if (!_selected.remove(entry.id)) _selected.add(entry.id);
      _selecting = _selected.isNotEmpty;
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selecting = false;
    });
  }

  void _removeSelected() {
    if (_selected.isEmpty) return;
    final Set<String> ids = Set<String>.of(_selected);
    _clearSelection();
    widget.onRemove(ids);
  }

  @override
  Widget build(BuildContext context) {
    final List<VideoRemoteFavoriteEntry> visible = _visible;
    return Padding(
      padding: EdgeInsets.only(
        top: widget.padding.top,
        left: widget.padding.left,
        right: widget.padding.right,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('video-remote-favorites-search'),
              controller: _query,
              focusNode: _searchFocus,
              hintText: t.video_remote_favorites_search_hint,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => setState(() {}),
              onClear: () => setState(_query.clear),
            ),
          ),
          FushiChromeReveal(
            visible: _selecting,
            from: AxisDirection.up,
            child: _SelectionBar(
              count: _selected.length,
              onCancel: _clearSelection,
              onRemove: _removeSelected,
            ),
          ),
          Expanded(child: _buildList(context, visible)),
        ],
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    List<VideoRemoteFavoriteEntry> visible,
  ) {
    if (visible.isEmpty) {
      if (widget.loading) {
        return const FushiLoadingView();
      }
      final bool searching = _query.text.trim().isNotEmpty;
      return Padding(
        padding: EdgeInsets.only(bottom: widget.padding.bottom),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: FushiPlaceholderMessage(
              key: const ValueKey<String>('video-remote-favorites-empty'),
              icon: searching ? FushiIcons.searchOff : FushiIcons.star,
              message: searching
                  ? t.video_remote_favorites_search_empty
                  : t.video_remote_favorites_empty,
              detail: searching ? null : t.video_remote_favorites_empty_hint,
            ),
          ),
        ),
      );
    }
    final bool showVideo = widget.scope == VideoRemoteFavoritesScope.allVideos;
    return FushiEntranceScope(
      replayKey: widget.scope,
      child: ListView.builder(
        key: const ValueKey<String>('video-remote-favorites-list'),
        padding: EdgeInsets.fromLTRB(16, 8, 16, widget.padding.bottom + 16),
        itemCount: visible.length,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
          final VideoRemoteFavoriteEntry entry = visible[index];
          final bool selected = _selected.contains(entry.id);
          final VideoRemoteFavoriteLookupCallback? lookup = widget.onLookup;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _FavoriteCard(
              key: ValueKey<String>('video-remote-favorite-${entry.id}'),
              entry: entry,
              showVideo: showVideo,
              selecting: _selecting,
              selected: selected,
              onTap: _selecting
                  ? () => _toggle(entry)
                  : () => widget.onOpen(entry),
              onLongPress: () => _toggle(entry),
              lookupHighlight: widget.lookupHighlight?.rangeForFavorite(entry),
              onLookup: _selecting || lookup == null
                  ? null
                  : (int charOffset, Rect anchor) =>
                        lookup(entry, charOffset, anchor),
            ),
          );
        }),
      ),
    );
  }
}

/// 多选时浮出的操作条：已选数 + 取消 + 批量取消收藏。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onCancel,
    required this.onRemove,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: cs.secondaryContainer,
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: <Widget>[
              FushiIconButtonControl(
                tooltip: t.cancel,
                onPressed: onCancel,
                icon: FushiIcon(
                  FushiIcons.close,
                  color: cs.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  t.video_remote_favorites_selected(n: count),
                  key: const ValueKey<String>('video-remote-selection-count'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.onSecondaryContainer,
                  ),
                ),
              ),
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('video-remote-favorites-remove'),
                onPressed: count == 0 ? null : onRemove,
                icon: const FushiIcon(FushiIcons.delete),
                label: Text(t.video_remote_remove),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一张收藏卡：句子（可逐字查词）+ 副轨 + 元信息（全部视频时带视频名）。
class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard({
    super.key,
    required this.entry,
    required this.showVideo,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onLookup,
    this.lookupHighlight,
  });

  final VideoRemoteFavoriteEntry entry;
  final bool showVideo;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(int charOffset, Rect anchor)? onLookup;
  final SubtitleTranscriptHighlightRange? lookupHighlight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle sentenceStyle =
        (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
          color: cs.onSurface,
          height: 1.45,
        );
    final String episode = (entry.episodeLabel ?? '').trim();
    final List<String> meta = <String>[
      if (showVideo && entry.videoTitle.trim().isNotEmpty)
        entry.videoTitle.trim(),
      if (showVideo && episode.isNotEmpty) episode,
      formatFushiPlaybackTime(entry.start),
    ];
    final void Function(int charOffset, Rect anchor)? lookup = onLookup;
    return FushiCard(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (lookup == null)
                  Text(entry.text, style: sentenceStyle)
                else
                  SubtitleTranscriptText(
                    text: entry.text,
                    style: sentenceStyle,
                    lookupHighlight: lookupHighlight,
                    onLookup: lookup,
                    onBackgroundTap: onTap,
                  ),
                if ((entry.secondaryText ?? '').trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.secondaryText!.trim(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    if (entry.isCurrentVideo && showVideo) ...<Widget>[
                      FushiIcon(
                        FushiIcons.playCircle,
                        size: 14,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        meta.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (selecting)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4),
              child: FushiCheckbox(
                value: selected,
                onChanged: (_) => onLongPress(),
              ),
            ),
        ],
      ),
    );
  }
}
