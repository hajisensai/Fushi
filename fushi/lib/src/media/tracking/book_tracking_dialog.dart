import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart' show MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

/// Opens the Track view for one book or manga: per site, its link (unit,
/// how it was made, change volume, unlink), the title matches waiting for
/// approval, and a manual search (title, ID or link).
Future<void> showBookTrackingDialog(
  BuildContext context, {
  required MediaTrackingService service,
  required String bookKey,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext context) =>
      BookTrackingDialog(service: service, bookKey: bookKey),
);

class BookTrackingDialog extends StatefulWidget {
  const BookTrackingDialog({
    required this.service,
    required this.bookKey,
    super.key,
  });

  final MediaTrackingService service;
  final String bookKey;

  @override
  State<BookTrackingDialog> createState() => _BookTrackingDialogState();
}

class _BookTrackingDialogState extends State<BookTrackingDialog> {
  BookTrackingOverview? _overview;
  bool _linking = true;

  /// The kind the user picked for a PDF (novel or manga); null = what the
  /// service says (its links' kind, else novel).
  TrackingKind? _kind;

  /// Provider ids with an action running (buttons off meanwhile).
  final Set<String> _busy = <String>{};
  final Map<String, TextEditingController> _queries =
      <String, TextEditingController>{};
  final Map<String, List<TrackingBookSubject>> _results =
      <String, List<TrackingBookSubject>>{};

  MediaTrackingService get _service => widget.service;

  /// [_busy] key of the do-not-track buttons (not a provider id).
  static const String _ignoreBusyKey = '#ignore';

  @override
  void initState() {
    super.initState();
    _service.statusRevision.addListener(_reload);
    unawaited(_open());
  }

  @override
  void dispose() {
    _service.statusRevision.removeListener(_reload);
    for (final TextEditingController controller in _queries.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Shows what is stored at once, then links where it can (the same
  /// linking reading does) and shows the result.
  Future<void> _open() async {
    await _reload();
    try {
      await _service.refreshBookLinks(widget.bookKey);
    } catch (_) {
      // Linking failures are logged by the service; the view still works.
    }
    if (!mounted) return;
    setState(() => _linking = false);
    await _reload();
  }

  Future<void> _reload() async {
    final BookTrackingOverview? overview = await _service.loadBookTracking(
      widget.bookKey,
      asKind: _kind,
    );
    if (mounted) setState(() => _overview = overview);
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(text)));
  }

  Future<void> _run(String providerId, Future<void> Function() action) async {
    setState(() => _busy.add(providerId));
    try {
      await action();
    } catch (_) {
      _message(t.media_tracking_track_link_failed);
    } finally {
      if (mounted) setState(() => _busy.remove(providerId));
      await _reload();
    }
  }

  Future<void> _search(String providerId) async {
    final String query = _queries[providerId]?.text.trim() ?? '';
    if (query.isEmpty) return;
    setState(() => _busy.add(providerId));
    try {
      final List<TrackingBookSubject> found = await _service.searchBookSubjects(
        providerId: providerId,
        bookKey: widget.bookKey,
        query: query,
        asKind: _overview?.kind,
      );
      if (!mounted) return;
      setState(() => _results[providerId] = found);
    } catch (_) {
      _message(t.media_tracking_track_search_failed);
    } finally {
      if (mounted) setState(() => _busy.remove(providerId));
    }
  }

  Future<void> _link(String providerId, TrackingBookSubject subject) =>
      _run(providerId, () async {
        await _service.linkBookToSubject(
          bookKey: widget.bookKey,
          providerId: providerId,
          subject: subject,
          asKind: _overview?.kind,
        );
        if (mounted) setState(() => _results.remove(providerId));
      });

  Future<void> _changeVolume(MediaTrackingMappingRow link) async {
    final String? value = await showFushiTextInputDialog(
      context: context,
      title: t.media_tracking_track_change_volume,
      labelText: t.media_tracking_track_volume_label,
      initialValue: '${link.progressOffset}',
      keyboardType: TextInputType.number,
      validator: (String value) {
        final int? number = int.tryParse(value.trim());
        return number == null || number < 1
            ? t.media_tracking_track_volume_label
            : null;
      },
    );
    final int? volume = int.tryParse(value?.trim() ?? '');
    if (volume == null || volume < 1) return;
    await _run(
      link.provider,
      () => _service.setBookLinkVolume(
        bookKey: widget.bookKey,
        providerId: link.provider,
        volume: volume,
      ),
    );
  }

  Future<void> _unlink(MediaTrackingMappingRow link) async {
    final String site = _service.siteNameOf(link.provider);
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.media_tracking_track_unlink,
      message: t.media_tracking_track_unlink_confirm(site: site),
      confirmLabel: t.media_tracking_track_unlink,
      cancelLabel: t.cancel,
      icon: FushiIcons.linkOff,
      destructive: true,
    );
    if (!confirmed) return;
    await _run(
      link.provider,
      () => _service.unlinkBook(
        bookKey: widget.bookKey,
        providerId: link.provider,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final BookTrackingOverview? overview = _overview;
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.tracking),
      title: Text(t.media_tracking_track_title),
      // Search results on several sites make the content many windows tall:
      // past the fit probe's limit it would be laid out as a fill dialog
      // (viewport height, no scroll) and overflow. The content is a min-size
      // column, so it scrolls as a whole.
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: overview == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: FushiCircularProgressIndicator(),
                ),
              )
            : FushiEntranceScope(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      overview.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: type.titleMediumEmphasized,
                    ),
                    if (_linking) ...<Widget>[
                      const SizedBox(height: 8),
                      const FushiLinearProgressIndicator(),
                    ],
                    if (overview.isPrivate) ...<Widget>[
                      const SizedBox(height: 8),
                      _Note(
                        icon: FushiIcons.lock,
                        text: t.media_tracking_track_private,
                      ),
                    ],
                    if (overview.kinds.length > 1) ...<Widget>[
                      const SizedBox(height: 8),
                      _buildKind(overview),
                    ],
                    const SizedBox(height: 8),
                    _buildIgnore(overview),
                    for (int i = 0; i < overview.sites.length; i++)
                      FushiStaggeredEntrance(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _buildSite(
                            context,
                            overview,
                            overview.sites[i],
                          ),
                        ),
                      ),
                    if (overview.sites.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          t.media_tracking_sites_not_connected,
                          style: type.bodyMedium.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.media_tracking_close),
        ),
      ],
    );
  }

  /// "Track as" for a PDF: novel or manga. Switching shows that kind's sites
  /// and searches; a link keeps the kind it was made with.
  Widget _buildKind(BookTrackingOverview overview) => Column(
    key: const ValueKey<String>('book-tracking-kind'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        t.media_tracking_track_as_label,
        style: context.fushiType.labelLarge,
      ),
      const SizedBox(height: 4),
      adaptiveSegmentedButton<TrackingKind>(
        context: context,
        segments: <ButtonSegment<TrackingKind>>[
          for (final TrackingKind kind in overview.kinds)
            ButtonSegment<TrackingKind>(
              value: kind,
              label: Text(
                trackingKindLabel(kind.value),
                key: ValueKey<String>('book-tracking-kind-${kind.value}'),
              ),
            ),
        ],
        selected: <TrackingKind>{overview.kind},
        onSelectionChanged: (Set<TrackingKind> value) {
          if (value.isEmpty || value.first == overview.kind) return;
          setState(() {
            _kind = value.first;
            _results.clear();
          });
          unawaited(_reload());
        },
      ),
    ],
  );

  /// Do-not-track for this book and its series: a note and "Track again"
  /// when one is on the list, else "Don't track" (and "Don't track the
  /// series" when the book is in a series).
  Widget _buildIgnore(BookTrackingOverview overview) {
    final ({int id, String name})? series = overview.series;
    final bool busy = _busy.contains(_ignoreBusyKey);
    Widget button({
      required String key,
      required String label,
      required IconData icon,
      required Future<void> Function() action,
    }) => FushiPressScale(
      enabled: !busy,
      child: FushiTextButton.icon(
        key: ValueKey<String>(key),
        onPressed: busy ? null : () => unawaited(_run(_ignoreBusyKey, action)),
        icon: FushiIcon(icon),
        label: Text(label),
      ),
    );
    final List<Widget> notes = <Widget>[
      if (overview.ignored)
        _Note(
          icon: FushiIcons.block,
          text: t.media_tracking_ignore_item_paused_note,
        ),
      if (overview.seriesIgnored && series != null)
        _Note(
          icon: FushiIcons.block,
          text: t.media_tracking_ignore_series_paused_note(name: series.name),
        ),
    ];
    final List<Widget> buttons = <Widget>[
      if (overview.ignored)
        button(
          key: 'book-tracking-track-again',
          label: t.media_tracking_ignore_undo_action,
          icon: FushiIcons.undo,
          action: () => _service.trackAgain(
            mediaType: TrackingMediaType.book.value,
            mediaKey: overview.bookKey,
          ),
        )
      else if (!overview.seriesIgnored)
        button(
          key: 'book-tracking-ignore',
          label: t.media_tracking_ignore_action,
          icon: FushiIcons.block,
          action: () => _service.ignoreItem(
            mediaType: TrackingMediaType.book,
            mediaKey: overview.bookKey,
            mediaTitle: overview.title,
            kind: overview.kind,
          ),
        ),
      if (series != null && overview.seriesIgnored)
        button(
          key: 'book-tracking-series-track-again',
          label: t.media_tracking_ignore_undo_action,
          icon: FushiIcons.undo,
          action: () => _service.trackAgain(
            mediaType: TrackingMediaType.bookCollection.value,
            mediaKey: series.id.toString(),
          ),
        )
      else if (series != null && !overview.ignored)
        button(
          key: 'book-tracking-ignore-series',
          label: t.media_tracking_ignore_series_action,
          icon: FushiIcons.block,
          action: () => _service.ignoreItem(
            mediaType: TrackingMediaType.bookCollection,
            mediaKey: series.id.toString(),
            mediaTitle: series.name,
            kind: overview.kind,
          ),
        ),
    ];
    return Column(
      key: const ValueKey<String>('book-tracking-ignore-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: <Widget>[
        ...notes,
        Wrap(spacing: 8, runSpacing: 4, children: buttons),
      ],
    );
  }

  Widget _buildSite(
    BuildContext context,
    BookTrackingOverview overview,
    BookTrackingSite site,
  ) {
    final FushiTypography type = context.fushiType;
    final bool busy = _busy.contains(site.providerId);
    final MediaTrackingMappingRow? link = site.link;
    final bool usable = site.connected && site.kindEnabled;
    final bool paused = overview.ignored || overview.seriesIgnored;
    final List<TrackingBookSubject>? results = _results[site.providerId];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _service.siteNameOf(site.providerId),
                style: type.titleSmallEmphasized,
              ),
            ),
            // A link of a book (or series) on the do-not-track list sends
            // nothing: the badge says so instead of "Linked" (T2 G14).
            FushiTag(
              key: const ValueKey<String>('book-tracking-site-badge'),
              dense: true,
              tone: link == null
                  ? FushiTagTone.neutral
                  : paused
                  ? FushiTagTone.warning
                  : FushiTagTone.success,
              icon: link == null
                  ? FushiIcons.linkOff
                  : paused
                  ? FushiIcons.pause
                  : FushiIcons.link,
              text: link == null
                  ? t.media_tracking_track_not_linked
                  : paused
                  ? t.media_tracking_ignore_paused
                  : t.media_tracking_track_linked,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!site.connected)
          _Note(
            icon: FushiIcons.info,
            text: t.media_tracking_track_not_connected,
          )
        else if (!site.kindEnabled)
          _Note(icon: FushiIcons.info, text: t.media_tracking_track_kind_off),
        if (link != null)
          _LinkTile(
            link: link,
            busy: busy || !usable,
            onChangeVolume: () => unawaited(_changeVolume(link)),
            onUnlink: () => unawaited(_unlink(link)),
          ),
        if (usable && !overview.isPrivate) ...<Widget>[
          if (link == null && site.suggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(t.media_tracking_track_suggestions, style: type.labelLarge),
            const SizedBox(height: 4),
            for (int i = 0; i < site.suggestions.length; i++)
              _SubjectTile(
                index: i,
                count: site.suggestions.length,
                subject: subjectOfSuggestion(site.suggestions[i]),
                score: site.suggestions[i].score,
                busy: busy,
                onLink: () => unawaited(
                  _run(
                    site.providerId,
                    () => _service.approveSuggestion(site.suggestions[i]),
                  ),
                ),
                onDismiss: () => unawaited(
                  _run(
                    site.providerId,
                    () => _service.dismissSuggestion(site.suggestions[i].id),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 8),
          _SearchRow(
            controller: _queries.putIfAbsent(
              site.providerId,
              () => TextEditingController(text: overview.searchQuery),
            ),
            busy: busy,
            onSearch: () => unawaited(_search(site.providerId)),
          ),
          if (results != null && results.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _Note(
                icon: FushiIcons.search,
                text: t.media_tracking_track_no_results,
              ),
            ),
          if (results != null && results.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            for (int i = 0; i < results.length; i++)
              _SubjectTile(
                index: i,
                count: results.length,
                subject: results[i],
                busy: busy,
                onLink: () => unawaited(_link(site.providerId, results[i])),
              ),
          ],
        ],
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FushiIcon(icon, size: 18, color: cs.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: context.fushiType.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.link,
    required this.busy,
    required this.onChangeVolume,
    required this.onUnlink,
  });

  final MediaTrackingMappingRow link;
  final bool busy;
  final VoidCallback onChangeVolume;
  final VoidCallback onUnlink;

  static String sourceLabel(MediaTrackingMappingRow link) {
    final String percent = '${((link.confidence ?? 0) * 100).round()}';
    return switch (link.linkSource) {
      TrackingLinkSource.auto => t.media_tracking_track_source_auto(
        percent: percent,
      ),
      TrackingLinkSource.suggestion => t.media_tracking_track_source_suggestion(
        percent: percent,
      ),
      TrackingLinkSource.id => t.media_tracking_track_source_id,
      _ => t.media_tracking_track_source_manual,
    };
  }

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool byVolume =
        link.progressMode == TrackingProgressMode.volume.value;
    return FushiGroupedListItem(
      index: 0,
      count: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    link.subjectName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyLargeEmphasized,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      byVolume
                          ? t.media_tracking_track_by_volume(
                              volume: '${link.progressOffset}',
                            )
                          : t.media_tracking_track_by_chapter,
                      sourceLabel(link),
                      '#${link.subjectId}',
                    ].join(' · '),
                    style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (byVolume)
              FushiIconButton(
                icon: FushiIcons.edit,
                tooltip: t.media_tracking_track_change_volume,
                onTap: onChangeVolume,
                enabled: !busy,
              ),
            FushiIconButton(
              icon: FushiIcons.linkOff,
              tooltip: t.media_tracking_track_unlink,
              onTap: onUnlink,
              enabled: !busy,
            ),
          ],
        ),
      ),
    );
  }
}

/// A suggestion ([score] set) or a search result: name, facts, and Link
/// (plus "Not this one" for suggestions).
class _SubjectTile extends StatelessWidget {
  const _SubjectTile({
    required this.index,
    required this.count,
    required this.subject,
    required this.busy,
    required this.onLink,
    this.score,
    this.onDismiss,
  });

  final int index;
  final int count;
  final TrackingBookSubject subject;
  final bool busy;
  final double? score;
  final VoidCallback onLink;
  final VoidCallback? onDismiss;

  String _facts() => <String>[
    if (subject.authors.isNotEmpty) subject.authors.first,
    if (subject.finalVolume case final int volumes)
      trackingVolumesCount(volumes),
    if (subject.totalChapters case final int chapters)
      trackingChaptersCount(chapters),
    subject.isFinished
        ? t.media_tracking_track_finished
        : t.media_tracking_track_releasing,
    '#${subject.subjectId}',
  ].join(' · ');

  /// The score is a still value, not progress: no moving wave.
  Widget _meter(BuildContext context, double value) {
    if (isGlassDesign(context) || isEinkTheme(context)) {
      return FushiLinearProgressIndicator(value: value);
    }
    final ThemeData theme = Theme.of(context);
    return FushiWavyLinearProgress(
      value: value,
      color: theme.progressIndicatorTheme.color ?? theme.colorScheme.primary,
      trackColor:
          theme.progressIndicatorTheme.linearTrackColor ??
          theme.colorScheme.secondaryContainer,
      waving: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double? score = this.score;
    final VoidCallback? onDismiss = this.onDismiss;
    return FushiStaggeredEntrance(
      index: index,
      child: FushiPressScale(
        enabled: !busy,
        child: FushiGroupedListItem(
          index: index,
          count: count,
          onTap: busy ? null : onLink,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  subject.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: type.bodyLargeEmphasized,
                ),
                const SizedBox(height: 2),
                Text(
                  _facts(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
                ),
                if (score != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    t.media_tracking_track_suggestion_match(
                      percent: '${(score * 100).round()}',
                    ),
                    style: type.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  _meter(context, score.clamp(0, 1).toDouble()),
                ],
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: <Widget>[
                    if (onDismiss != null)
                      FushiTextButton(
                        onPressed: busy ? null : onDismiss,
                        child: Text(t.media_tracking_track_dismiss),
                      ),
                    FushiFilledButton.tonalIcon(
                      onPressed: busy ? null : onLink,
                      icon: const FushiIcon(FushiIcons.link),
                      label: Text(t.media_tracking_track_approve),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.controller,
    required this.busy,
    required this.onSearch,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: FushiTextFieldControl(
            controller: controller,
            autocorrect: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSearch(),
            decoration: InputDecoration(
              hintText: t.media_tracking_track_search_hint,
              border: const FushiOutlinedFieldBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (busy)
          const SizedBox.square(
            dimension: 40,
            child: Padding(
              padding: EdgeInsets.all(10),
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          FushiIconButton(
            icon: FushiIcons.search,
            tooltip: t.media_tracking_track_search,
            onTap: onSearch,
          ),
      ],
    );
  }
}
