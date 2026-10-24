import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 手动连接里可选的关系（主题曲 / 原声需要音乐端点、声优需要人物端点，那两类
/// 本地条目落地前不提供）。
const List<MediaLinkRelation> kMediaLinkPickableRelations = <MediaLinkRelation>[
  MediaLinkRelation.adaptation,
  MediaLinkRelation.sameWork,
];

/// 详情页「关联作品」入口：选目标种类 → 关系 → 方向（有方向关系才问）→ 点选目标
/// 条目即写一条手动连接（`upsertManualMediaLink`，恒为已确认）。返回是否写入了。
Future<bool> showMediaLinkEditorDialog({
  required BuildContext context,
  required FushiDatabase database,
  required MediaLinkEndpoint self,
}) async {
  final MediaLinkEntry? written = await showAppDialog<MediaLinkEntry>(
    context: context,
    builder: (BuildContext _) =>
        MediaLinkEditorDialog(database: database, self: self),
  );
  if (written == null) return false;
  FushiToast.show(msg: t.media_link_saved, severity: ToastSeverity.success);
  return true;
}

/// [showMediaLinkEditorDialog] 的对话框本体（公开以便 widget 测试直接挂）。
class MediaLinkEditorDialog extends StatefulWidget {
  const MediaLinkEditorDialog({
    required this.database,
    required this.self,
    super.key,
  });

  final FushiDatabase database;
  final MediaLinkEndpoint self;

  @override
  State<MediaLinkEditorDialog> createState() => _MediaLinkEditorDialogState();
}

class _MediaLinkEditorDialogState extends State<MediaLinkEditorDialog> {
  late MediaLinkKind _kind = _initialKind();
  MediaLinkRelation _relation = MediaLinkRelation.adaptation;

  /// adaptation 方向：true = 本条是原作（本条 → 目标）。
  bool _selfIsOriginal = true;
  String _query = '';
  bool _saving = false;
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 候选按种类缓存（State 持有，不在 build 里现取：BUG-2010 同一纪律）。
  final Map<MediaLinkKind, Future<List<MediaLinkEntry>>> _candidates =
      <MediaLinkKind, Future<List<MediaLinkEntry>>>{};

  /// 默认目标种类：跨模块联动最常见的是「另一个模块」，所以避开本条自己的种类。
  MediaLinkKind _initialKind() => switch (widget.self.kind) {
    MediaLinkKind.videoCollection ||
    MediaLinkKind.videoEpisode => MediaLinkKind.book,
    _ => MediaLinkKind.videoCollection,
  };

  Future<List<MediaLinkEntry>> _candidatesFor(MediaLinkKind kind) => _candidates
      .putIfAbsent(kind, () => loadMediaLinkCandidates(widget.database, kind));

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _pick(MediaLinkEntry target) async {
    if (_saving) return;
    setState(() => _saving = true);
    final bool selfIsFrom =
        _relation != MediaLinkRelation.adaptation || _selfIsOriginal;
    await widget.database.upsertManualMediaLink(
      relation: _relation,
      from: selfIsFrom ? widget.self : target.endpoint,
      to: selfIsFrom ? target.endpoint : widget.self,
    );
    if (!mounted) return;
    Navigator.of(context).pop(target);
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.media_link_editor_title,
        leadingIcon: FushiIcons.link,
        scrollable: true,
        bodyPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.gap / 2,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            adaptiveSegmentedButton<MediaLinkKind>(
              context: context,
              segments: <ButtonSegment<MediaLinkKind>>[
                for (final MediaLinkKind k in kMediaLinkPickableKinds)
                  ButtonSegment<MediaLinkKind>(
                    value: k,
                    label: Text(mediaLinkKindLabel(k)),
                  ),
              ],
              selected: <MediaLinkKind>{_kind},
              onSelectionChanged: (Set<MediaLinkKind> s) =>
                  setState(() => _kind = s.first),
            ),
            _label(context, t.media_link_editor_relation),
            adaptiveSegmentedButton<MediaLinkRelation>(
              context: context,
              segments: <ButtonSegment<MediaLinkRelation>>[
                for (final MediaLinkRelation r in kMediaLinkPickableRelations)
                  ButtonSegment<MediaLinkRelation>(
                    value: r,
                    label: Text(mediaLinkRelationLabel(r)),
                  ),
              ],
              selected: <MediaLinkRelation>{_relation},
              onSelectionChanged: (Set<MediaLinkRelation> s) =>
                  setState(() => _relation = s.first),
            ),
            FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              child: _relation.directed
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _label(context, t.media_link_editor_direction),
                        adaptiveSegmentedButton<bool>(
                          context: context,
                          segments: <ButtonSegment<bool>>[
                            ButtonSegment<bool>(
                              value: true,
                              label: Text(t.media_link_direction_this_original),
                            ),
                            ButtonSegment<bool>(
                              value: false,
                              label: Text(
                                t.media_link_direction_target_original,
                              ),
                            ),
                          ],
                          selected: <bool>{_selfIsOriginal},
                          onSelectionChanged: (Set<bool> s) =>
                              setState(() => _selfIsOriginal = s.first),
                        ),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: 12),
            FushiSearchField(
              controller: _search,
              focusNode: _searchFocus,
              hintText: t.media_link_editor_search_hint,
              onChanged: (String v) => setState(() => _query = v),
              onSubmitted: (String v) => setState(() => _query = v),
              onClear: () => setState(() => _query = ''),
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<MediaLinkEntry>>(
              future: _candidatesFor(_kind),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<MediaLinkEntry>> snap,
                  ) {
                    final List<MediaLinkEntry> all =
                        snap.data ?? const <MediaLinkEntry>[];
                    final List<MediaLinkEntry> shown = <MediaLinkEntry>[
                      for (final MediaLinkEntry e in all)
                        if (!(e.endpoint.kind == widget.self.kind &&
                                e.endpoint.key == widget.self.key) &&
                            matchesMediaSearch(
                              query: _query,
                              titles: <String>[e.title],
                            ))
                          e,
                    ];
                    if (snap.connectionState == ConnectionState.done &&
                        shown.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: Text(t.media_link_editor_empty)),
                      );
                    }
                    return FushiEntranceScope(
                      replayKey: _kind,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (int i = 0; i < shown.length; i++)
                            FushiStaggeredEntrance(
                              index: i,
                              child: FushiListItem(
                                key: ValueKey<String>(
                                  'media-link-candidate-${shown[i].endpoint.key}',
                                ),
                                leading: FushiListLeadingIcon(
                                  mediaLinkKindIcon(shown[i].endpoint.kind),
                                  shape: FushiLeadingShape.square,
                                ),
                                title: Text(shown[i].title),
                                trailing: const FushiIcon(FushiIcons.link),
                                onTap: _saving ? null : () => _pick(shown[i]),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
            ),
          ],
        ),
      ),
    );
  }
}
