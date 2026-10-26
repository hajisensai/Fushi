/// 动画进度 ↔ 原作进度（作品图谱 L5，spec `docs/specs/2026-10-24-cross-media-links.md`
/// §6）：挂在「同一作品」区块下面，每条已确认的「原作（书）→ 改编（视频）」连接一张卡：
/// 「看到第 5 集 ≈ 原作第 2 卷」+ 手动对应点 +「编辑对应」。
///
/// 对应点只来自用户手动记录（`adaptation_progress_anchors`）。按字幕与原文自动推断
/// 依赖 L4 `fushi_corpus`，尚未实现（[kAdaptationProgressInferrer] 为 null），编辑框里
/// 明示「暂未支持」。
library;

import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter;
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/adaptation_progress.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart'
    show parsedEpisodeNumbersOf;
import 'package:material_ui/material_ui.dart';

/// 一条可做进度对应的连接（原作是书 / 有声书、改编是视频合集 / 单个视频）。
typedef AdaptationProgressLink = ({
  AdaptationProgressPair pair,
  MediaLinkView view,
});

bool _isSourceKind(String kind) =>
    kind == MediaLinkKind.book.dbValue ||
    kind == MediaLinkKind.audiobook.dbValue;

bool _isAdaptationKind(String kind) =>
    kind == MediaLinkKind.videoCollection.dbValue ||
    kind == MediaLinkKind.videoEpisode.dbValue;

/// 从本页已确认的连接里挑出能做进度对应的那几条（纯函数）。
List<AdaptationProgressLink> adaptationProgressLinksOf(
  Iterable<MediaLinkView> confirmed,
) => <AdaptationProgressLink>[
  for (final MediaLinkView v in confirmed)
    if (v.relation == MediaLinkRelation.adaptation &&
        _isSourceKind(v.row.fromKind) &&
        _isAdaptationKind(v.row.toKind))
      (
        pair: (
          sourceKind: v.row.fromKind,
          sourceKey: v.row.fromKey,
          adaptationKind: v.row.toKind,
          adaptationKey: v.row.toKey,
        ),
        view: v,
      ),
];

/// 一集视频的观看事实（用于求「看到第几集」）。
typedef WatchedEpisodeFact = ({int? episode, bool started});

/// 看到第几集：开始看过（有播放位置或已看完）的集里集号最大的那一集；集号解析不出
/// 时用合集里的顺位（1 起）。都没看过返回 null（纯函数）。
int? watchedEpisodeFrom(List<WatchedEpisodeFact> facts) {
  int? best;
  for (int i = 0; i < facts.length; i++) {
    if (!facts[i].started) continue;
    final int ep = facts[i].episode ?? (i + 1);
    if (best == null || ep > best) best = ep;
  }
  return best;
}

bool _started(VideoBookRow row) =>
    row.completedAt != null || row.lastPositionMs > 0;

/// 改编端（视频合集 / 单个视频）当前看到第几集。
Future<int?> loadWatchedEpisode(
  FushiDatabase db,
  String adaptationKind,
  String adaptationKey,
) async {
  if (adaptationKind == MediaLinkKind.videoEpisode.dbValue) {
    final VideoBookRow? row = await db.getVideoBookByBookUid(adaptationKey);
    if (row == null || !_started(row)) return null;
    return parsedEpisodeNumbersOf(<String>[row.videoPath]).first ??
        row.currentEpisode + 1;
  }
  final int? id = collectionIdOfTagEntryKey(adaptationKey);
  if (id == null) return null;
  final List<VideoBookRow> rows = <VideoBookRow>[];
  for (final MediaCollectionItemRow item in await db.getCollectionItems(id)) {
    if (item.mediaType != MediaKind.video.dbValue) continue;
    final VideoBookRow? row = await db.getVideoBookByBookUid(item.entryKey);
    if (row != null) rows.add(row);
  }
  final List<int?> numbers = parsedEpisodeNumbersOf(<String>[
    for (final VideoBookRow r in rows) r.videoPath,
  ]);
  return watchedEpisodeFrom(<WatchedEpisodeFact>[
    for (int i = 0; i < rows.length; i++)
      (episode: numbers[i], started: _started(rows[i])),
  ]);
}

AdaptationProgressAnchor _anchorOf(AdaptationProgressAnchorRow r) =>
    AdaptationProgressAnchor(
      episode: r.episodeNumber,
      unit: AdaptationSourceUnit.parse(r.sourceUnit),
      number: r.sourceNumber,
    );

/// 「第 2 卷」/「第 3 章」。
String adaptationPositionLabel(AdaptationSourceUnit unit, int number) =>
    switch (unit) {
      AdaptationSourceUnit.volume => t.adaptation_progress_unit_volume(
        number: number,
      ),
      AdaptationSourceUnit.chapter => t.adaptation_progress_unit_chapter(
        number: number,
      ),
    };

/// 卡片上的进度一句话（纯函数）。
String adaptationProgressLine(
  List<AdaptationProgressAnchor> anchors,
  int? watchedEpisode,
) {
  if (anchors.isEmpty) return t.adaptation_progress_empty;
  if (watchedEpisode == null) return t.adaptation_progress_not_started;
  final AdaptationProgressAnchor? at = estimateSourceProgress(
    anchors,
    watchedEpisode,
  );
  if (at == null) {
    return t.adaptation_progress_no_anchor(episode: watchedEpisode);
  }
  return t.adaptation_progress_estimate(
    episode: watchedEpisode,
    position: adaptationPositionLabel(at.unit, at.number),
  );
}

/// 「同一作品」区块下的原作进度卡片组（没有可对应的连接时不渲染）。
class AdaptationProgressSection extends StatelessWidget {
  const AdaptationProgressSection({
    required this.database,
    required this.links,
    super.key,
  });

  final FushiDatabase database;
  final List<AdaptationProgressLink> links;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      key: const ValueKey<String>('adaptation-progress-section'),
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.rowVertical,
        tokens.spacing.page,
        0,
      ),
      child: FushiEntranceScope(
        replayKey: links.length,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < links.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap),
                  child: _AdaptationProgressCard(
                    key: ValueKey<String>(
                      'adaptation-progress-${links[i].pair.sourceKey}-'
                      '${links[i].pair.adaptationKey}',
                    ),
                    database: database,
                    link: links[i],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdaptationProgressCard extends StatefulWidget {
  const _AdaptationProgressCard({
    required this.database,
    required this.link,
    super.key,
  });

  final FushiDatabase database;
  final AdaptationProgressLink link;

  @override
  State<_AdaptationProgressCard> createState() =>
      _AdaptationProgressCardState();
}

class _AdaptationProgressCardState extends State<_AdaptationProgressCard> {
  late Future<({List<AdaptationProgressAnchor> anchors, int? watched})> _data =
      _load();
  StreamSubscription<Set<TableUpdate>>? _sub;

  Future<({List<AdaptationProgressAnchor> anchors, int? watched})>
  _load() async {
    final AdaptationProgressPair p = widget.link.pair;
    final List<AdaptationProgressAnchor> anchors = <AdaptationProgressAnchor>[
      for (final AdaptationProgressAnchorRow r
          in await widget.database.adaptationProgressAnchorsFor(p))
        _anchorOf(r),
    ];
    final int? watched = await loadWatchedEpisode(
      widget.database,
      p.adaptationKind,
      p.adaptationKey,
    );
    return (anchors: anchors, watched: watched);
  }

  @override
  void initState() {
    super.initState();
    // tableUpdates 手动订阅（BUG-834 范式，不用 drift `.watch()`）。
    _sub = widget.database
        .tableUpdates(
          TableUpdateQuery.onTable(widget.database.adaptationProgressAnchors),
        )
        .listen((_) {
          if (!mounted) return;
          setState(() {
            _data = _load();
          });
        });
  }

  @override
  void didUpdateWidget(covariant _AdaptationProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.pair != widget.link.pair) _data = _load();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiCard(
      child:
          FutureBuilder<
            ({List<AdaptationProgressAnchor> anchors, int? watched})
          >(
            future: _data,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<
                    ({List<AdaptationProgressAnchor> anchors, int? watched})
                  >
                  s,
                ) {
                  final List<AdaptationProgressAnchor> anchors =
                      s.data?.anchors ?? const <AdaptationProgressAnchor>[];
                  return FushiAnimatedSize(
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    curve: FushiMotion.standard,
                    alignment: Alignment.topCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            FushiIcon(
                              mediaLinkKindIcon(
                                widget.link.view.other.endpoint.kind,
                              ),
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              // 「原作进度对应 · 对端标题」一行：同页有多条改编连接时靠对端标题区分。
                              child: Text(
                                '${t.adaptation_progress_title} · '
                                '${widget.link.view.other.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            FushiTextButton(
                              key: const ValueKey<String>(
                                'adaptation-progress-edit',
                              ),
                              onPressed: () => unawaited(
                                showAdaptationProgressEditor(
                                  context: context,
                                  database: widget.database,
                                  pair: widget.link.pair,
                                ),
                              ),
                              child: Text(t.adaptation_progress_edit),
                            ),
                          ],
                        ),
                        if (s.hasData)
                          Text(
                            adaptationProgressLine(anchors, s.data!.watched),
                            key: const ValueKey<String>(
                              'adaptation-progress-line',
                            ),
                            style: theme.textTheme.bodyMedium,
                          ),
                        if (anchors.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: <Widget>[
                              for (final AdaptationProgressAnchor a in anchors)
                                FushiChip(
                                  label: Text(
                                    t.adaptation_progress_anchor(
                                      episode: a.episode,
                                      position: adaptationPositionLabel(
                                        a.unit,
                                        a.number,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  );
                },
          ),
    );
  }
}

/// 编辑一对端点的手动对应点：列表（可删）+「第 [集] 集 ≈ [卷 / 章] 第 [号]」添加行。
Future<void> showAdaptationProgressEditor({
  required BuildContext context,
  required FushiDatabase database,
  required AdaptationProgressPair pair,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiDialogFrame(
    maxWidth: 520,
    padding: const EdgeInsets.all(20),
    child: _AdaptationProgressEditor(database: database, pair: pair),
  ),
);

class _AdaptationProgressEditor extends StatefulWidget {
  const _AdaptationProgressEditor({required this.database, required this.pair});

  final FushiDatabase database;
  final AdaptationProgressPair pair;

  @override
  State<_AdaptationProgressEditor> createState() =>
      _AdaptationProgressEditorState();
}

class _AdaptationProgressEditorState extends State<_AdaptationProgressEditor> {
  final TextEditingController _episode = TextEditingController();
  final TextEditingController _number = TextEditingController();
  AdaptationSourceUnit _unit = AdaptationSourceUnit.volume;
  late Future<List<AdaptationProgressAnchorRow>> _rows = _load();
  bool _invalid = false;

  Future<List<AdaptationProgressAnchorRow>> _load() =>
      widget.database.adaptationProgressAnchorsFor(widget.pair);

  @override
  void dispose() {
    _episode.dispose();
    _number.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final int? ep = int.tryParse(_episode.text.trim());
    final int? no = int.tryParse(_number.text.trim());
    if (ep == null || no == null || ep < 1 || no < 1) {
      setState(() => _invalid = true);
      return;
    }
    await widget.database.upsertAdaptationProgressAnchor(
      AdaptationProgressAnchorsCompanion.insert(
        sourceKind: widget.pair.sourceKind,
        sourceKey: widget.pair.sourceKey,
        adaptationKind: widget.pair.adaptationKind,
        adaptationKey: widget.pair.adaptationKey,
        episodeNumber: ep,
        sourceUnit: _unit.dbValue,
        sourceNumber: no,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!mounted) return;
    _episode.clear();
    _number.clear();
    setState(() {
      _invalid = false;
      _rows = _load();
    });
  }

  Future<void> _remove(int episode) async {
    await widget.database.deleteAdaptationProgressAnchor(widget.pair, episode);
    if (!mounted) return;
    setState(() {
      _rows = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t.adaptation_progress_title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        FutureBuilder<List<AdaptationProgressAnchorRow>>(
          future: _rows,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<AdaptationProgressAnchorRow>> s,
              ) {
                final List<AdaptationProgressAnchorRow> rows =
                    s.data ?? const <AdaptationProgressAnchorRow>[];
                if (rows.isEmpty) {
                  return Text(
                    t.adaptation_progress_empty,
                    style: theme.textTheme.bodyMedium,
                  );
                }
                return FushiEntranceScope(
                  replayKey: rows.length,
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < rows.length; i++)
                        FushiStaggeredEntrance(
                          index: i,
                          child: FushiListItem(
                            key: ValueKey<String>(
                              'adaptation-anchor-${rows[i].episodeNumber}',
                            ),
                            title: Text(
                              t.adaptation_progress_anchor(
                                episode: rows[i].episodeNumber,
                                position: adaptationPositionLabel(
                                  AdaptationSourceUnit.parse(
                                    rows[i].sourceUnit,
                                  ),
                                  rows[i].sourceNumber,
                                ),
                              ),
                            ),
                            trailing: FushiTextButton(
                              key: ValueKey<String>(
                                'adaptation-anchor-remove-${rows[i].episodeNumber}',
                              ),
                              onPressed: () =>
                                  unawaited(_remove(rows[i].episodeNumber)),
                              child: Text(t.adaptation_progress_remove),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: FushiTextField(
                key: const ValueKey<String>('adaptation-anchor-episode'),
                controller: _episode,
                labelText: t.adaptation_progress_episode_field,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Text('≈'),
            const SizedBox(width: 8),
            Expanded(
              child: FushiTextField(
                key: const ValueKey<String>('adaptation-anchor-number'),
                controller: _number,
                labelText: t.adaptation_progress_number_field,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onSubmitted: (_) => unawaited(_add()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        adaptiveSegmentedButton<AdaptationSourceUnit>(
          context: context,
          segments: <ButtonSegment<AdaptationSourceUnit>>[
            ButtonSegment<AdaptationSourceUnit>(
              value: AdaptationSourceUnit.volume,
              label: Text(t.adaptation_progress_unit_volume_label),
            ),
            ButtonSegment<AdaptationSourceUnit>(
              value: AdaptationSourceUnit.chapter,
              label: Text(t.adaptation_progress_unit_chapter_label),
            ),
          ],
          selected: <AdaptationSourceUnit>{_unit},
          onSelectionChanged: (Set<AdaptationSourceUnit> v) =>
              setState(() => _unit = v.first),
        ),
        if (_invalid) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            t.adaptation_progress_invalid,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FushiFilledButton.icon(
            key: const ValueKey<String>('adaptation-anchor-add'),
            onPressed: () => unawaited(_add()),
            icon: const FushiIcon(FushiIcons.add),
            label: Text(t.adaptation_progress_add),
          ),
        ),
        if (kAdaptationProgressInferrer == null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            t.adaptation_progress_infer_unavailable,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
