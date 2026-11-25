// The "Tracking" section of a series card's page: per site, the card's
// series link (one link that counts every volume, also ones added later)
// and how it counts each volume. Series links are managed here; a volume's
// Track sheet only shows how its series link counts it.
import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/book_tracking_dialog.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart'
    show trackingKindOfValue;
import 'package:fushi/src/media/tracking/page/tracking_page_rows.dart'
    show TrackingRowAction, TrackingRowMenu;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart' show MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/book_series_link.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Above this many volumes, a series link's volume rows fold behind a summary.
const int kSeriesCardVolumeFoldThreshold = 5;

/// A volume the series link cannot count until the user acts (no number, or
/// looks like another series): it stays visible when the volume list folds.
/// Same split as the Tracking page's "Needs attention".
bool seriesMemberNeedsAttention(TrackingSeriesMember member) =>
    member.state == TrackingSeriesMemberState.noNumber ||
    member.state == TrackingSeriesMemberState.otherSeries;

/// The "Tracking" section of series card [collectionId]'s page. Shows
/// nothing for a card that is not the series card of its books, or when no
/// site is signed in and the card has no series link.
class SeriesCardTrackingSection extends StatefulWidget {
  const SeriesCardTrackingSection({
    required this.service,
    required this.collectionId,
    super.key,
  });

  final MediaTrackingService service;
  final int collectionId;

  @override
  State<SeriesCardTrackingSection> createState() =>
      _SeriesCardTrackingSectionState();
}

class _SeriesCardTrackingSectionState extends State<SeriesCardTrackingSection> {
  SeriesCardTracking? _data;

  /// Provider ids with an action running (their buttons off meanwhile).
  final Set<String> _busy = <String>{};

  MediaTrackingService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _service.statusRevision.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(SeriesCardTrackingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.statusRevision.removeListener(_reload);
      widget.service.statusRevision.addListener(_reload);
    }
    if (oldWidget.collectionId != widget.collectionId ||
        oldWidget.service != widget.service) {
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _service.statusRevision.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final SeriesCardTracking? data = await _service.loadSeriesCardTracking(
      widget.collectionId,
    );
    if (mounted) setState(() => _data = data);
  }

  Future<void> _run(String providerId, Future<void> Function() action) async {
    setState(() => _busy.add(providerId));
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            FushiSnackBar(content: Text(t.media_tracking_track_link_failed)),
          );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(providerId));
    }
    await _reload();
  }

  Future<void> _linkSeries(
    SeriesCardTracking data,
    SeriesCardTrackingSite site,
  ) async {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _SeriesLinkSearchDialog(
        service: _service,
        data: data,
        providerId: site.providerId,
      ),
    );
    await _reload();
  }

  Future<void> _removeSeriesLink(
    SeriesCardTracking data,
    MediaTrackingMappingRow link,
  ) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.tracking_series_remove,
      message: t.tracking_series_remove_confirm(
        series: data.name,
        site: _service.siteNameOf(link.provider),
      ),
      confirmLabel: t.tracking_series_remove,
      cancelLabel: t.cancel,
      icon: FushiIcons.linkOff,
      destructive: true,
    );
    if (!confirmed) return;
    await _run(link.provider, () => _service.removeLink(link));
  }

  /// "Change volume number": the volume gets its own link to the series'
  /// site entry with that number.
  Future<void> _changeNumber(
    String providerId,
    TrackingSeriesMember member,
  ) async {
    final int? current = member.volume;
    final String? value = await showFushiTextInputDialog(
      context: context,
      title: t.tracking_series_change_number,
      labelText: t.media_tracking_track_volume_label,
      initialValue: current == null ? '' : '$current',
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
      providerId,
      () => _service.setSeriesVolumeNumber(
        bookKey: member.bookKey,
        providerId: providerId,
        volume: volume,
      ),
    );
  }

  /// The volume's Track sheet; [separateOn] opens its search to link it on
  /// its own there. Its "series card" button leads back here: it closes.
  Future<void> _openTrackSheet(String bookKey, {String? separateOn}) async {
    await showBookTrackingDialog(
      context,
      service: _service,
      bookKey: bookKey,
      separateOn: separateOn,
      openSeriesCard: (BuildContext sheet, int _, String _) async =>
          Navigator.of(sheet).pop(),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final SeriesCardTracking? data = _data;
    if (data == null) return const SizedBox.shrink();
    final List<SeriesCardTrackingSite> sites = <SeriesCardTrackingSite>[
      for (final SeriesCardTrackingSite site in data.sites)
        if (site.connected || site.seriesLink != null) site,
    ];
    if (sites.isEmpty) return const SizedBox.shrink();
    return FushiEntranceScope(
      child: Column(
        key: const ValueKey<String>('series-card-tracking'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSectionTitle(t.tracking_series_section_title),
          if (data.ignored)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TrackingNote(
                icon: FushiIcons.pause,
                text: t.media_tracking_ignore_paused,
              ),
            ),
          for (int i = 0; i < sites.length; i++)
            FushiStaggeredEntrance(
              index: i,
              child: Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 16),
                child: _buildSite(data, sites[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSite(SeriesCardTracking data, SeriesCardTrackingSite site) {
    final FushiTypography type = context.fushiType;
    final String id = site.providerId;
    final bool busy = _busy.contains(id);
    final MediaTrackingMappingRow? link = site.seriesLink;
    final bool usable = site.connected && site.kindEnabled;
    return Column(
      key: ValueKey<String>('series-card-tracking-site-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(_service.siteNameOf(id), style: type.titleSmall),
            ),
            FushiTag(
              dense: true,
              tone: link == null ? FushiTagTone.neutral : FushiTagTone.success,
              icon: link == null ? FushiIcons.linkOff : FushiIcons.link,
              text: link == null
                  ? t.media_tracking_track_not_linked
                  : t.media_tracking_track_linked,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (link != null) ...<Widget>[
          _buildLink(data, site, link, busy: busy),
          if (site.coverage.numberedByPosition) ...<Widget>[
            const SizedBox(height: 8),
            TrackingNote(
              icon: FushiIcons.info,
              text: t.tracking_series_by_position,
            ),
          ],
          const SizedBox(height: 8),
          ..._buildVolumes(data, site, busy: busy || !usable),
        ] else if (usable)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiPressScale(
              enabled: !busy,
              child: FushiTextButton.icon(
                key: ValueKey<String>('series-card-tracking-link-$id'),
                onPressed: busy
                    ? null
                    : () => unawaited(_linkSeries(data, site)),
                icon: const FushiIcon(FushiIcons.link),
                label: Text(t.tracking_series_link_action),
              ),
            ),
          )
        else
          TrackingNote(
            icon: FushiIcons.info,
            text: t.media_tracking_track_kind_off,
          ),
      ],
    );
  }

  /// The series link: the site entry, how it was made, what it counts; open
  /// on the site and remove.
  Widget _buildLink(
    SeriesCardTracking data,
    SeriesCardTrackingSite site,
    MediaTrackingMappingRow link, {
    required bool busy,
  }) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TrackingKind? kind = trackingKindOfValue(link.kind);
    final Uri? url = kind == null
        ? null
        : _service.subjectPageUrl(link.provider, link.subjectId, kind);
    return FushiGroupedListItem(
      key: ValueKey<String>('series-card-tracking-link-row-${link.provider}'),
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
                      trackingSeriesUnitLabel(site.coverage),
                      trackingLinkSourceLabel(link),
                      '#${link.subjectId}',
                    ].join(' · '),
                    key: ValueKey<String>(
                      'series-card-tracking-unit-${link.provider}',
                    ),
                    style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (url != null)
              FushiIconButton(
                icon: FushiIcons.openInNew,
                tooltip: t.media_tracking_page_open_on_site(
                  site: _service.siteNameOf(link.provider),
                ),
                onTap: () => unawaited(
                  launchUrl(url, mode: LaunchMode.externalApplication),
                ),
              ),
            FushiIconButton(
              key: ValueKey<String>(
                'series-card-tracking-remove-${link.provider}',
              ),
              icon: FushiIcons.linkOff,
              tooltip: t.tracking_series_remove,
              onTap: () => unawaited(_removeSeriesLink(data, link)),
              enabled: !busy,
            ),
          ],
        ),
      ),
    );
  }

  /// The volume rows of [site]'s series link. A card with more than
  /// [kSeriesCardVolumeFoldThreshold] volumes folds the rows that need
  /// nothing from the user behind one summary row; volumes waiting for the
  /// user ([seriesMemberNeedsAttention]) stay visible above it.
  List<Widget> _buildVolumes(
    SeriesCardTracking data,
    SeriesCardTrackingSite site, {
    required bool busy,
  }) {
    final List<TrackingSeriesMember> members = site.coverage.members;
    List<Widget> rows(List<TrackingSeriesMember> group) => <Widget>[
      for (int i = 0; i < group.length; i++)
        _buildVolume(
          data,
          site,
          group[i],
          index: i,
          count: group.length,
          busy: busy,
        ),
    ];
    if (members.length <= kSeriesCardVolumeFoldThreshold) return rows(members);
    final List<TrackingSeriesMember> attention = <TrackingSeriesMember>[
      for (final TrackingSeriesMember member in members)
        if (seriesMemberNeedsAttention(member)) member,
    ];
    final List<TrackingSeriesMember> rest = <TrackingSeriesMember>[
      for (final TrackingSeriesMember member in members)
        if (!seriesMemberNeedsAttention(member)) member,
    ];
    return <Widget>[
      ...rows(attention),
      if (attention.isNotEmpty && rest.isNotEmpty) const SizedBox(height: 8),
      if (rest.isNotEmpty)
        // Keyed per site: the tile keeps its open state across reloads (a
        // renumbered or excluded volume does not snap it shut). Not persisted.
        FushiExpansionTile(
          key: ValueKey<String>('series-card-tracking-fold-${site.providerId}'),
          leading: const FushiListLeadingIcon(
            FushiIcons.check,
            shape: FushiLeadingShape.square,
            tone: FushiCardTone.secondary,
          ),
          title: Text(trackingVolumesCount(members.length)),
          subtitle: Text(trackingSeriesFoldSummary(site.coverage)),
          childrenPadding: const EdgeInsets.only(top: 4),
          children: rows(rest),
        ),
    ];
  }

  /// One volume: its number and whether the series link counts it, with
  /// what the user can do about it in the row menu.
  Widget _buildVolume(
    SeriesCardTracking data,
    SeriesCardTrackingSite site,
    TrackingSeriesMember member, {
    required int index,
    required int count,
    required bool busy,
  }) {
    final String id = site.providerId;
    final int? volume = member.volume;
    final bool counts =
        member.counted || member.state == TrackingSeriesMemberState.ownLink;
    TrackingRowAction action(
      String key,
      String label,
      IconData icon,
      VoidCallback onSelected,
    ) => TrackingRowAction(
      id: key,
      label: label,
      icon: icon,
      onSelected: onSelected,
    );
    final TrackingRowAction exclude = action(
      'exclude',
      t.tracking_series_exclude_volume,
      FushiIcons.block,
      () => unawaited(
        _run(
          id,
          () => _service.ignoreItem(
            mediaType: TrackingMediaType.book,
            mediaKey: member.bookKey,
            mediaTitle: member.title,
            kind: data.kind,
          ),
        ),
      ),
    );
    final TrackingRowAction separately = action(
      'separate',
      t.tracking_series_link_separately,
      FushiIcons.link,
      () => unawaited(_openTrackSheet(member.bookKey, separateOn: id)),
    );
    final TrackingRowAction renumber = action(
      'renumber',
      t.tracking_series_change_number,
      FushiIcons.edit,
      () => unawaited(_changeNumber(id, member)),
    );
    final List<TrackingRowAction> actions = switch (member.state) {
      TrackingSeriesMemberState.counted => <TrackingRowAction>[
        exclude,
        separately,
        renumber,
      ],
      TrackingSeriesMemberState.excluded => <TrackingRowAction>[
        action(
          'count-again',
          t.tracking_series_count_again,
          FushiIcons.undo,
          () => unawaited(
            _run(
              id,
              () => _service.trackAgain(
                mediaType: TrackingMediaType.book.value,
                mediaKey: member.bookKey,
              ),
            ),
          ),
        ),
      ],
      TrackingSeriesMemberState.noNumber ||
      TrackingSeriesMemberState.otherSeries => <TrackingRowAction>[
        renumber,
        separately,
        exclude,
      ],
      // Its own link counts it: that link is changed on its Track sheet.
      TrackingSeriesMemberState.ownLink => <TrackingRowAction>[
        action(
          'open-sheet',
          t.tracking_series_open_sheet,
          FushiIcons.edit,
          () => unawaited(_openTrackSheet(member.bookKey)),
        ),
      ],
      // Private or another format: the reason only.
      TrackingSeriesMemberState.private ||
      TrackingSeriesMemberState.otherKind => const <TrackingRowAction>[],
    };
    return FushiHoverLift(
      scale: 1.005,
      builder: (BuildContext context, bool hovering) => FushiGroupedListItem(
        key: ValueKey<String>(
          'series-card-tracking-volume-$id-${member.bookKey}',
        ),
        index: index,
        count: count,
        child: FushiListItem(
          leading: FushiListLeadingIcon(
            counts ? FushiIcons.check : FushiIcons.block,
            shape: FushiLeadingShape.square,
            tone: FushiCardTone.secondary,
          ),
          title: Text(member.title),
          titleMaxLines: 2,
          subtitle: Text(
            <String>[
              if (volume != null)
                site.coverage.numberedByPosition
                    ? t.tracking_series_volume_by_position(volume: '$volume')
                    : t.media_tracking_track_by_volume(volume: '$volume'),
              trackingSeriesStateLabel(member.state),
            ].join(' · '),
          ),
          subtitleMaxLines: 2,
          trailing: actions.isEmpty || busy
              ? null
              : TrackingRowMenu(
                  key: ValueKey<String>(
                    'series-card-tracking-volume-menu-$id-${member.bookKey}',
                  ),
                  actions: actions,
                ),
        ),
      ),
    );
  }
}

/// Searches [providerId] for the site entry of the whole series card and
/// links the card to the one the user picks.
class _SeriesLinkSearchDialog extends StatefulWidget {
  const _SeriesLinkSearchDialog({
    required this.service,
    required this.data,
    required this.providerId,
  });

  final MediaTrackingService service;
  final SeriesCardTracking data;
  final String providerId;

  @override
  State<_SeriesLinkSearchDialog> createState() =>
      _SeriesLinkSearchDialogState();
}

class _SeriesLinkSearchDialogState extends State<_SeriesLinkSearchDialog> {
  late final TextEditingController _query = TextEditingController(
    text: widget.data.searchQuery,
  );
  List<TrackingBookSubject>? _results;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final String query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final List<TrackingBookSubject> found = await widget.service
          .searchBookSubjects(
            providerId: widget.providerId,
            bookKey: widget.data.firstBookKey,
            query: query,
            asKind: widget.data.kind,
          );
      if (mounted) setState(() => _results = found);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _link(TrackingBookSubject subject) async {
    setState(() => _busy = true);
    try {
      await widget.service.linkSeriesToSubject(
        collectionId: widget.data.collectionId,
        providerId: widget.providerId,
        subject: subject,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<TrackingBookSubject>? results = _results;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.tracking),
      title: Text(t.tracking_series_link_action),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TrackingNote(
                icon: FushiIcons.info,
                text: t.tracking_series_link_explain(
                  series: widget.data.name,
                  site: widget.service.siteNameOf(widget.providerId),
                ),
              ),
              const SizedBox(height: 8),
              TrackingSearchRow(
                key: const ValueKey<String>('series-card-tracking-search'),
                controller: _query,
                busy: _busy,
                onSearch: () => unawaited(_search()),
              ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TrackingNote(
                    icon: FushiIcons.error,
                    text: t.media_tracking_track_search_failed,
                  ),
                ),
              if (results != null && results.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TrackingNote(
                    icon: FushiIcons.search,
                    text: t.media_tracking_track_no_results,
                  ),
                ),
              if (results != null && results.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                for (int i = 0; i < results.length; i++)
                  FushiStaggeredEntrance(
                    index: i,
                    child: TrackingSubjectTile(
                      key: ValueKey<String>(
                        'series-card-tracking-result-${results[i].subjectId}',
                      ),
                      index: i,
                      count: results.length,
                      subject: results[i],
                      busy: _busy,
                      onLink: () => unawaited(_link(results[i])),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
      ],
    );
  }
}
