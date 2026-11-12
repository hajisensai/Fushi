/// One link dialog for every tracking site: pick the local item (when none
/// was given), pick a connected site that tracks its kind, search there
/// (title, id or link), pick a result. Saving replaces that site's link for
/// the item and sends the item's current progress; the page offers Undo.
///
/// One click on a result links, except for a book on a site that plans the
/// unit itself: there the click selects, the number that will be sent can
/// be corrected, and "Link" saves (T1 F16). Changing a link marks the
/// current entry (listed first even when the search does not find it).
library;

import 'dart:async';

import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/page/tracking_local_targets.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/book_tracking_link.dart'
    show BookLinkPlan;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';
import 'package:material_ui/material_ui.dart';

/// How the dialog ended when the user saved a link.
final class TrackingLinkOutcome {
  const TrackingLinkOutcome({
    required this.sent,
    required this.entryName,
    required this.siteName,
    required this.undo,
    this.held = true,
  });

  /// The current progress went out (or is on its way); false = sending
  /// failed and the update stays queued.
  final bool sent;

  /// The site entry linked to, and the site.
  final String entryName;
  final String siteName;

  /// Puts the site's links back as they were ([MediaTrackingService.undoLink]).
  final TrackingLinkUndo undo;

  /// This link queued an update that waits for the Undo window; false =
  /// nothing was queued, so nothing is "sent when the message closes".
  final bool held;
}

/// Opens the link dialog. [item] null = the user picks a local item first.
/// [existing] = the link being changed (its site is preselected and its unit
/// kept). [onOpenSettings] = where "no site" sends the user. Null when the
/// user cancelled.
Future<TrackingLinkOutcome?> showTrackingLinkDialog(
  BuildContext context, {
  required MediaTrackingService service,
  required FushiDatabase database,
  MediaTrackingLocalTarget? item,
  MediaTrackingMappingRow? existing,
  VoidCallback? onOpenSettings,
}) => showAppDialog<TrackingLinkOutcome>(
  context: context,
  builder: (BuildContext context) => TrackingLinkDialog(
    service: service,
    database: database,
    item: item,
    existing: existing,
    onOpenSettings: onOpenSettings,
  ),
);

class TrackingLinkDialog extends StatefulWidget {
  const TrackingLinkDialog({
    required this.service,
    required this.database,
    this.item,
    this.existing,
    this.onOpenSettings,
    super.key,
  });

  final MediaTrackingService service;
  final FushiDatabase database;
  final MediaTrackingLocalTarget? item;
  final MediaTrackingMappingRow? existing;
  final VoidCallback? onOpenSettings;

  @override
  State<TrackingLinkDialog> createState() => _TrackingLinkDialogState();
}

class _TrackingLinkDialogState extends State<TrackingLinkDialog> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _offset = TextEditingController();

  /// The number a planned book link sends (volume, or chapters added).
  final TextEditingController _bookNumber = TextEditingController();

  /// Planned book links: the selected result and its planned unit / number.
  TrackingSearchHit? _selected;
  BookLinkPlan? _plan;

  /// Local items to pick from; null until loaded (only without an item).
  List<MediaTrackingLocalTarget>? _targets;
  MediaTrackingLocalTarget? _target;

  /// Searches [_targets] ("Link an item", T2 G10).
  final TextEditingController _itemQuery = TextEditingController();

  /// How the Tracking page names each local item's kind (Anime / Live
  /// action / Video, the same rule as its rows).
  TrackingRowFacts _facts = TrackingRowFacts.empty;

  /// The picker is open again after an item was chosen.
  bool _choosingItem = false;
  List<TrackingProvider> _sites = const <TrackingProvider>[];
  String? _siteId;
  TrackingProgressMode _mode = TrackingProgressMode.episode;

  List<TrackingSearchHit> _results = const <TrackingSearchHit>[];
  bool _searching = false;
  bool _searched = false;
  bool _saving = false;
  String? _error;

  /// Bumped per search; an answer to an older search is dropped.
  int _searchGeneration = 0;

  /// The item is a video collection holding more than one season: one link
  /// could never send, so the dialog explains instead of searching.
  bool _multiSeason = false;

  /// Links the chosen item already has, by site ([_linkOn]). Read when an
  /// item is chosen, so "Link an item" marks the current entry the same way
  /// as opening the dialog from the item's own row ([TrackingLinkDialog.existing]).
  List<MediaTrackingMappingRow> _itemLinks = const <MediaTrackingMappingRow>[];

  MediaTrackingService get _service => widget.service;

  /// The item's link on [siteId]: the link being changed when it is on that
  /// site, else one the chosen item already has there.
  MediaTrackingMappingRow? _linkOn(String? siteId) {
    if (siteId == null) return null;
    final MediaTrackingMappingRow? existing = widget.existing;
    if (existing != null && existing.provider == siteId) return existing;
    for (final MediaTrackingMappingRow link in _itemLinks) {
      if (link.provider == siteId) return link;
    }
    return null;
  }

  /// Reads [target]'s links ([_itemLinks]) and applies the current link's
  /// unit on the chosen site.
  Future<void> _loadItemLinks(MediaTrackingLocalTarget target) async {
    final List<MediaTrackingMappingRow> links = await _service.linksOfItem(
      mediaType: target.type,
      mediaKey: target.key,
    );
    if (!mounted ||
        _target?.key != target.key ||
        _target?.type != target.type) {
      return;
    }
    setState(() {
      _itemLinks = links;
      if (_selected == null) _applyUnitDefaults();
    });
  }

  @override
  void initState() {
    super.initState();
    final MediaTrackingLocalTarget? item = widget.item;
    if (item != null) {
      _applySelection(item);
      unawaited(_loadItemLinks(item));
      unawaited(_checkThenSearch(item));
    } else {
      unawaited(_loadTargets());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _offset.dispose();
    _bookNumber.dispose();
    _itemQuery.dispose();
    super.dispose();
  }

  /// Searches for [item] unless it can never get a link that sends.
  Future<void> _checkThenSearch(MediaTrackingLocalTarget item) async {
    final bool multiSeason = await _service.isMultiSeasonCollection(
      item.type,
      item.key,
    );
    if (!mounted) return;
    if (multiSeason) {
      setState(() => _multiSeason = true);
      return;
    }
    await _preferWorkTitle(item);
    if (mounted && _siteId != null) await _search();
  }

  /// Puts the work's name ([trackingWorkTitlesFor]: scraped title, series
  /// card, media server series) in the search box instead of the cleaned
  /// file name, unless the user typed something meanwhile.
  Future<void> _preferWorkTitle(MediaTrackingLocalTarget target) async {
    final String fallback = trackingInitialQuery(target.title);
    final List<String> works = await trackingWorkTitlesFor(
      widget.database,
      target.type,
      target.key,
    );
    if (!mounted ||
        works.isEmpty ||
        _target?.key != target.key ||
        _target?.type != target.type ||
        _query.text.trim() != fallback) {
      return;
    }
    setState(
      () => _query.text = trackingInitialQuery(target.title, workTitles: works),
    );
  }

  /// Nothing is chosen for the user: a pre-chosen first item was searched
  /// and one click away from a wrong link (T2 G2, G10).
  Future<void> _loadTargets() async {
    final List<MediaTrackingLocalTarget> targets =
        await loadMediaTrackingLocalTargets(widget.database);
    final TrackingRowFacts facts = await loadTrackingRowFacts(widget.database);
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _facts = facts;
    });
  }

  /// [target]'s kind as the Tracking page names it.
  String _targetKindLabel(MediaTrackingLocalTarget target) {
    final TrackingRowKind? kind = trackingRowKindOf(
      target.kind,
      nature: _facts.of(target.type.value, target.key).nature,
    );
    return kind == null
        ? trackingKindLabel(target.kind.value)
        : trackingRowKindLabel(kind);
  }

  /// Makes [target] the item to link: its eligible sites, the preselected
  /// site, the unit, the search text.
  void _select(MediaTrackingLocalTarget target, {required bool search}) {
    setState(() {
      _choosingItem = false;
      _applySelection(target);
    });
    unawaited(() async {
      await _loadItemLinks(target);
      await _preferWorkTitle(target);
      if (mounted && search && _siteId != null) await _search();
    }());
  }

  void _applySelection(MediaTrackingLocalTarget target) {
    final List<TrackingProvider> sites = _service.manualLinkSitesFor(
      target.kind,
    );
    // Keeps the query the user typed when only the kind changes.
    final bool sameItem =
        _target?.key == target.key && _target?.type == target.type;
    final String? keep = widget.existing?.provider ?? _siteId;
    final String? siteId = sites.isEmpty
        ? null
        : sites.any((TrackingProvider s) => s.id == keep)
        ? keep
        : sites.first.id;
    if (!sameItem) _itemLinks = const <MediaTrackingMappingRow>[];
    _target = target;
    _sites = sites;
    _siteId = siteId;
    if (!sameItem || _query.text.trim().isEmpty) {
      _query.text = trackingInitialQuery(target.title);
    }
    _results = const <TrackingSearchHit>[];
    _searched = false;
    _error = null;
    _clearSelection();
    _applyUnitDefaults();
  }

  void _clearSelection() {
    _selected = null;
    _plan = null;
    _bookNumber.clear();
  }

  /// Links the item as [kind] (a PDF: novel or manga).
  void _selectKind(TrackingKind kind) {
    final MediaTrackingLocalTarget? target = _target;
    if (target == null || kind == target.kind) return;
    _select(target.asKind(kind), search: true);
  }

  void _selectSite(String siteId) {
    if (siteId == _siteId) return;
    setState(() {
      _siteId = siteId;
      _results = const <TrackingSearchHit>[];
      _searched = false;
      _error = null;
      _clearSelection();
      _applyUnitDefaults();
    });
    unawaited(_search());
  }

  TrackingProvider? get _site {
    for (final TrackingProvider site in _sites) {
      if (site.id == _siteId) return site;
    }
    return null;
  }

  /// Units the user may pick for the current item on the current site.
  List<TrackingProgressMode> get _modes {
    final MediaTrackingLocalTarget? target = _target;
    final TrackingProvider? site = _site;
    if (target == null || site == null) return const <TrackingProgressMode>[];
    return <TrackingProgressMode>[
      for (final TrackingProgressMode mode in allowedTrackingModesFor(
        target.type,
      ))
        if (site.capabilities.accepts(target.kind, mode)) mode,
    ];
  }

  /// The site plans a book's unit itself (the Track sheet's rule).
  bool get _planned {
    final MediaTrackingLocalTarget? target = _target;
    final String? siteId = _siteId;
    return target != null &&
        siteId != null &&
        _service.plansBookLink(target.type, siteId);
  }

  /// The changed link's unit when it is on the chosen site, else the media
  /// type's default.
  void _applyUnitDefaults() {
    final List<TrackingProgressMode> modes = _modes;
    final MediaTrackingMappingRow? existing = _linkOn(_siteId);
    final TrackingProgressMode? existingMode = existing == null
        ? null
        : TrackingProgressMode.tryParse(existing.progressMode);
    if (existing != null &&
        existing.provider == _siteId &&
        existingMode != null &&
        modes.contains(existingMode)) {
      _mode = existingMode;
      _offset.text = '${existing.progressOffset}';
      return;
    }
    final MediaTrackingLocalTarget? target = _target;
    final TrackingProgressMode preferred = target == null
        ? TrackingProgressMode.episode
        : defaultTrackingModeFor(target.type);
    _mode = modes.contains(preferred) || modes.isEmpty
        ? preferred
        : modes.first;
    _offset.text = '${_initialOffsetFor(_mode)}';
  }

  /// The item's own starting number for [mode] when it has one, else the
  /// unit's default.
  int _initialOffsetFor(TrackingProgressMode mode) {
    final int? own = _target?.initialOffset;
    return own != null && mode == TrackingProgressMode.episode && own > 0
        ? own
        : defaultTrackingOffsetFor(mode);
  }

  Future<void> _search() async {
    final MediaTrackingLocalTarget? target = _target;
    final String? siteId = _siteId;
    final String query = _query.text.trim();
    if (target == null || siteId == null || query.isEmpty || _multiSeason) {
      return;
    }
    final int generation = ++_searchGeneration;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final List<TrackingSearchHit> found = await _service.searchSiteSubjects(
        providerId: siteId,
        kind: target.kind,
        query: query,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = found;
        _searched = true;
      });
    } catch (error, stack) {
      // Logged so a rate limit can be told from an outage (T1 F18).
      ErrorLogService.instance.log('TrackingLinkDialog.search', error, stack);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = const <TrackingSearchHit>[];
        _error = t.media_tracking_track_search_failed;
      });
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  /// The link being changed, when it is on the chosen site.
  MediaTrackingMappingRow? get _current => _linkOn(_siteId);

  /// The results as listed: the current entry first (also when the search
  /// did not find it), then the rest.
  List<TrackingSearchHit> get _shownResults {
    final MediaTrackingMappingRow? current = _current;
    if (current == null || !_searched) return _results;
    final TrackingSearchHit currentHit = _results.firstWhere(
      (TrackingSearchHit hit) => hit.subjectId == current.subjectId,
      orElse: () => TrackingSearchHit(
        subjectId: current.subjectId,
        name: current.subjectName,
        kind: _target?.kind,
      ),
    );
    return <TrackingSearchHit>[
      currentHit,
      for (final TrackingSearchHit hit in _results)
        if (hit.subjectId != current.subjectId) hit,
    ];
  }

  /// A result was clicked: links at once, or (planned book links) selects
  /// it and pre-fills the number it would send.
  Future<void> _pick(TrackingSearchHit hit) async {
    if (!_planned) {
      if (!_offsetValid) return;
      return _save(hit);
    }
    final MediaTrackingLocalTarget? target = _target;
    final String? siteId = _siteId;
    if (target == null || siteId == null) return;
    setState(() {
      _selected = hit;
      _error = null;
    });
    BookLinkPlan? plan;
    try {
      plan = await _service.planBookLinkForHit(
        mediaType: target.type,
        mediaKey: target.key,
        providerId: siteId,
        hit: hit,
        asKind: target.kind,
      );
    } catch (error, stack) {
      ErrorLogService.instance.log('TrackingLinkDialog.plan', error, stack);
    }
    if (!mounted || !identical(_selected, hit)) return;
    final MediaTrackingMappingRow? current = _current;
    // The current entry keeps the unit and number it was saved with, over
    // the plan (T2 G4: reopening showed the planned number, and Link put
    // it back silently).
    if (current != null && current.subjectId == hit.subjectId) {
      plan = switch (TrackingProgressMode.tryParse(current.progressMode)) {
        final TrackingProgressMode mode => (
          mode: mode,
          offset: current.progressOffset,
        ),
        null => plan,
      };
    }
    setState(() {
      _plan = plan;
      _bookNumber.text = plan == null ? '' : '${plan.offset}';
    });
  }

  /// The number in [text] when it is a whole number of at least
  /// [trackingNumberMin] for [mode]; null otherwise (T2 G5: nothing is
  /// guessed from a wrong entry).
  static int? _validNumber(TrackingProgressMode mode, String text) {
    final int? value = int.tryParse(text.trim());
    if (value == null || value < trackingNumberMin(mode)) return null;
    return value;
  }

  /// The one-click "Starting number" is valid (or not asked for).
  bool get _offsetValid =>
      _planned ||
      _mode == TrackingProgressMode.status ||
      _validNumber(_mode, _offset.text) != null;

  /// The planned book link's number is valid (or not asked for).
  bool get _bookNumberValid {
    final BookLinkPlan? plan = _plan;
    return plan == null ||
        plan.mode == TrackingProgressMode.status ||
        _validNumber(plan.mode, _bookNumber.text) != null;
  }

  /// Saves the selected result of a planned book link with the number in
  /// the field.
  void _saveSelected() {
    final TrackingSearchHit? hit = _selected;
    final BookLinkPlan? plan = _plan;
    if (hit == null || !_bookNumberValid) return;
    unawaited(
      _save(
        hit,
        bookPlan: plan == null
            ? null
            : (
                mode: plan.mode,
                offset: normalizeTrackingProgressOffset(
                  plan.mode,
                  _validNumber(plan.mode, _bookNumber.text) ?? plan.offset,
                ),
              ),
      ),
    );
  }

  Future<void> _save(TrackingSearchHit hit, {BookLinkPlan? bookPlan}) async {
    final MediaTrackingLocalTarget? target = _target;
    final String? siteId = _siteId;
    final TrackingProvider? site = _site;
    if (target == null || siteId == null || site == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final ({
        MediaTrackingSyncResult? result,
        TrackingLinkUndo undo,
        bool held,
      })
      linked = await _service.linkItemToSubjectUndoable(
        mediaType: target.type,
        mediaKey: target.key,
        mediaTitle: target.title,
        kind: target.kind,
        providerId: siteId,
        hit: hit,
        progressMode: _mode,
        progressOffset: normalizeTrackingProgressOffset(
          _mode,
          int.tryParse(_offset.text.trim()),
        ),
        bookPlan: bookPlan,
      );
      if (!mounted) return;
      final MediaTrackingSyncResult? result = linked.result;
      Navigator.of(context).pop(
        TrackingLinkOutcome(
          sent: result == null || result.isSuccess,
          entryName: hit.name,
          siteName: site.displayName,
          undo: linked.undo,
          held: linked.held,
        ),
      );
    } on MultiSeasonCollectionLinkError {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _multiSeason = true;
      });
    } on MediaServerLibraryLinkError {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = t.media_tracking_link_server_season_unknown;
      });
    } catch (error, stack) {
      ErrorLogService.instance.log('TrackingLinkDialog.save', error, stack);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = t.media_tracking_track_link_failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final MediaTrackingLocalTarget? target = _target;
    final List<MediaTrackingLocalTarget>? targets = _targets;
    final bool loadingTargets = widget.item == null && targets == null;
    return FushiAlertDialog(
      key: const ValueKey<String>('tracking-link-dialog'),
      icon: const FushiIcon(FushiIcons.tracking),
      title: Text(t.media_tracking_link_title),
      // Search results can be many windows tall: the whole dialog scrolls
      // (the default fit-or-grow shell treats such content as fill-height).
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: <Widget>[
            if (loadingTargets)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: FushiCircularProgressIndicator(),
                ),
              )
            else if (widget.item == null && targets!.isEmpty)
              FushiInlineNotice(message: t.media_tracking_link_no_local_items)
            else if (widget.item == null)
              ..._localItemPicker(context, targets!)
            else
              Text(
                target!.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.bodyLargeEmphasized,
              ),
            if (target != null) ..._siteAndSearch(context, target),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        if (_planned && !_multiSeason && _sites.isNotEmpty)
          FushiFilledButton(
            key: const ValueKey<String>('tracking-link-save'),
            onPressed: _selected == null || _saving || !_bookNumberValid
                ? null
                : _saveSelected,
            child: Text(t.media_tracking_link_save),
          ),
      ],
    );
  }

  /// Height of the results area (library picker and site search).
  static const double _resultsHeight = 280;

  /// Items the picker lists at most; typing narrows the rest.
  static const int _pickerLimit = 30;

  /// "Link an item": a search over the library (hundreds of items) and the
  /// matches, each with its kind as the page names it (T2 G10). Once an
  /// item is chosen it stays shown with a way to choose another.
  List<Widget> _localItemPicker(
    BuildContext context,
    List<MediaTrackingLocalTarget> targets,
  ) {
    final MediaTrackingLocalTarget? chosen = _target;
    if (chosen != null && !_choosingItem) {
      return <Widget>[
        FushiGroupedListItem(
          key: const ValueKey<String>('tracking-link-local-chosen'),
          index: 0,
          count: 1,
          selected: true,
          child: ListTile(
            title: Text(
              chosen.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_targetKindLabel(chosen)),
            trailing: FushiTextButton(
              key: const ValueKey<String>('tracking-link-local-change'),
              onPressed: () => setState(() => _choosingItem = true),
              child: Text(t.media_tracking_link_local_change),
            ),
          ),
        ),
      ];
    }
    final String query = _itemQuery.text.trim().toLowerCase();
    final List<MediaTrackingLocalTarget> matches = <MediaTrackingLocalTarget>[
      for (final MediaTrackingLocalTarget target in targets)
        if (query.isEmpty || target.title.toLowerCase().contains(query)) target,
    ];
    final int shown = matches.length < _pickerLimit
        ? matches.length
        : _pickerLimit;
    return <Widget>[
      FushiTextFieldControl(
        key: const ValueKey<String>('tracking-link-local-search'),
        controller: _itemQuery,
        autofocus: true,
        autocorrect: false,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: t.media_tracking_local_item,
          hintText: t.media_tracking_link_local_search_hint,
          prefixIcon: const FushiIcon(FushiIcons.search),
          border: const FushiOutlinedFieldBorder(),
        ),
      ),
      // A fixed-height results area: the dialog does not resize while the
      // user types (T3 H5).
      SizedBox(
        height: _resultsHeight,
        child: matches.isEmpty
            ? FushiInlineNotice(message: t.media_tracking_link_local_no_match)
            : SingleChildScrollView(
                child: FushiEntranceScope(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < shown; i++)
                        FushiStaggeredEntrance(
                          key: ValueKey<String>(
                            'tracking-link-local-${matches[i].type.value}-'
                            '${matches[i].key}',
                          ),
                          index: i,
                          child: FushiPressScale(
                            child: FushiGroupedListItem(
                              index: i,
                              count: shown,
                              selected:
                                  matches[i].key == chosen?.key &&
                                  matches[i].type == chosen?.type,
                              onTap: () => _select(matches[i], search: true),
                              child: ListTile(
                                title: Text(
                                  matches[i].title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(_targetKindLabel(matches[i])),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
      // The line keeps its space when nothing is left out, so the dialog
      // does not shrink on the first keystroke.
      Visibility(
        key: const ValueKey<String>('tracking-link-local-more'),
        visible: matches.length > shown,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: Text(
          t.media_tracking_link_local_more(n: '${matches.length - shown}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.bodySmall,
        ),
      ),
    ];
  }

  List<Widget> _siteAndSearch(
    BuildContext context,
    MediaTrackingLocalTarget target,
  ) {
    if (_multiSeason) {
      return <Widget>[
        FushiInlineNotice(
          key: const ValueKey<String>('tracking-link-multi-season'),
          severity: FushiNoticeSeverity.warning,
          message: t.media_tracking_multi_season_link_refused,
        ),
      ];
    }
    if (_sites.isEmpty) {
      final VoidCallback? onOpenSettings = widget.onOpenSettings;
      return <Widget>[
        if (target.kinds.length > 1) _kindPicker(context, target),
        FushiInlineNotice(
          key: const ValueKey<String>('tracking-link-no-site'),
          severity: FushiNoticeSeverity.warning,
          message: t.media_tracking_link_no_site(
            kind: trackingKindLabel(target.kind.value),
          ),
          actions: <Widget>[
            if (onOpenSettings != null)
              FushiTextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onOpenSettings();
                },
                child: Text(t.settings),
              ),
          ],
        ),
      ];
    }
    final List<TrackingProgressMode> modes = _modes;
    final bool planned = _planned;
    final List<TrackingSearchHit> shown = _shownResults;
    return <Widget>[
      if (target.kinds.length > 1) _kindPicker(context, target),
      if (_sites.length > 1) _sitePicker(context),
      if (!planned && modes.length > 1)
        adaptiveSegmentedButton<TrackingProgressMode>(
          context: context,
          segments: <ButtonSegment<TrackingProgressMode>>[
            for (final TrackingProgressMode mode in modes)
              ButtonSegment<TrackingProgressMode>(
                value: mode,
                label: Text(trackingProgressModeLabel(mode.value)),
              ),
          ],
          selected: <TrackingProgressMode>{_mode},
          onSelectionChanged: (Set<TrackingProgressMode> value) {
            if (value.isEmpty) return;
            setState(() {
              _mode = value.first;
              _offset.text = '${_initialOffsetFor(_mode)}';
            });
          },
        ),
      // A status link has no number to start from.
      if (!planned && _mode != TrackingProgressMode.status)
        FushiTextFieldControl(
          key: const ValueKey<String>('tracking-link-offset'),
          controller: _offset,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t.media_tracking_progress_offset,
            helperText: trackingNumberHelp(_mode),
            errorText: _offsetValid
                ? null
                : t.media_tracking_link_number_invalid(
                    min: '${trackingNumberMin(_mode)}',
                  ),
            border: const FushiOutlinedFieldBorder(),
          ),
        ),
      FushiTextFieldControl(
        key: const ValueKey<String>('tracking-link-query'),
        controller: _query,
        autocorrect: false,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => unawaited(_search()),
        decoration: InputDecoration(
          hintText: t.media_tracking_track_search_hint,
          border: const FushiOutlinedFieldBorder(),
          suffixIcon: FushiIconButtonControl(
            tooltip: t.media_tracking_track_search,
            onPressed: _searching ? null : () => unawaited(_search()),
            icon: const FushiIcon(FushiIcons.search),
          ),
        ),
      ),
      if (_searching || _saving)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: FushiCircularProgressIndicator(),
          ),
        ),
      if (_error case final String error)
        FushiInlineNotice(severity: FushiNoticeSeverity.error, message: error),
      if (!_searching && _searched && shown.isEmpty && _error == null)
        FushiInlineNotice(message: t.media_tracking_track_no_results),
      // One click links (T2 G2): say so, and that Undo comes first.
      if (!planned && !_searching && shown.isNotEmpty)
        FushiInlineNotice(
          key: const ValueKey<String>('tracking-link-one-click-hint'),
          message: t.media_tracking_link_one_click_hint,
        ),
      if (planned) ..._bookNumberField(),
      if (_searching || shown.isNotEmpty)
        SizedBox(
          height: _resultsHeight,
          child: _searching
              ? const SizedBox.shrink()
              : SingleChildScrollView(
                  child: FushiEntranceScope(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (int i = 0; i < shown.length; i++)
                          _ResultTile(
                            key: ValueKey<String>(
                              'tracking-link-result-${shown[i].subjectId}',
                            ),
                            index: i,
                            count: shown.length,
                            hit: shown[i],
                            busy: _saving || !_offsetValid,
                            current: _current?.subjectId == shown[i].subjectId,
                            selected: identical(_selected, shown[i]),
                            onPick: () => unawaited(_pick(shown[i])),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
    ];
  }

  /// Planned book links: how to save, and (once a result is selected) the
  /// number that will be sent, pre-filled from the planned unit.
  List<Widget> _bookNumberField() {
    final BookLinkPlan? plan = _plan;
    return <Widget>[
      if (_selected == null)
        FushiInlineNotice(
          key: const ValueKey<String>('tracking-link-pick-hint'),
          message: t.media_tracking_link_pick_then_save,
        ),
      if (plan != null && plan.mode != TrackingProgressMode.status)
        FushiTextFieldControl(
          key: const ValueKey<String>('tracking-link-book-number'),
          controller: _bookNumber,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: plan.mode == TrackingProgressMode.volume
                ? t.media_tracking_link_volume_to_send
                : t.media_tracking_progress_offset,
            helperText: trackingNumberHelp(plan.mode),
            errorText: _bookNumberValid
                ? null
                : t.media_tracking_link_number_invalid(
                    min: '${trackingNumberMin(plan.mode)}',
                  ),
            border: const FushiOutlinedFieldBorder(),
          ),
        ),
    ];
  }

  /// "Track as": novel or manga for a PDF.
  Widget _kindPicker(BuildContext context, MediaTrackingLocalTarget target) =>
      Column(
        key: const ValueKey<String>('tracking-link-kind'),
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: <Widget>[
          Text(t.media_tracking_track_as_label),
          adaptiveSegmentedButton<TrackingKind>(
            context: context,
            segments: <ButtonSegment<TrackingKind>>[
              for (final TrackingKind kind in target.kinds)
                ButtonSegment<TrackingKind>(
                  value: kind,
                  label: Text(
                    trackingKindLabel(kind.value),
                    key: ValueKey<String>('tracking-link-kind-${kind.value}'),
                  ),
                ),
            ],
            selected: <TrackingKind>{target.kind},
            onSelectionChanged: (Set<TrackingKind> value) {
              if (value.isNotEmpty) _selectKind(value.first);
            },
          ),
        ],
      );

  Widget _sitePicker(BuildContext context) {
    if (_sites.length <= 3) {
      return adaptiveSegmentedButton<String>(
        context: context,
        segments: <ButtonSegment<String>>[
          for (final TrackingProvider site in _sites)
            ButtonSegment<String>(
              value: site.id,
              label: Text(
                site.displayName,
                key: ValueKey<String>('tracking-link-site-${site.id}'),
              ),
            ),
        ],
        selected: <String>{?_siteId},
        onSelectionChanged: (Set<String> value) {
          if (value.isNotEmpty) _selectSite(value.first);
        },
      );
    }
    return FushiDropdownButtonFormField<String>(
      key: const ValueKey<String>('tracking-link-site'),
      initialValue: _siteId,
      isExpanded: true,
      decoration: InputDecoration(labelText: t.media_tracking_link_site_label),
      items: <DropdownMenuItem<String>>[
        for (final TrackingProvider site in _sites)
          DropdownMenuItem<String>(
            value: site.id,
            child: Text(site.displayName),
          ),
      ],
      onChanged: (String? value) {
        if (value != null) _selectSite(value);
      },
    );
  }
}

/// One search result: name, other title, facts; tap links.
class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.index,
    required this.count,
    required this.hit,
    required this.busy,
    required this.onPick,
    this.current = false,
    this.selected = false,
    super.key,
  });

  final int index;
  final int count;
  final TrackingSearchHit hit;
  final bool busy;
  final VoidCallback onPick;

  /// The entry the item is linked to now (changing a link).
  final bool current;

  /// Selected for saving (planned book links).
  final bool selected;

  String _facts() => <String>[
    if (hit.kind case final TrackingKind kind) trackingKindLabel(kind.value),
    if (hit.year case final int year) '$year',
    if (hit.episodeCount case final int episodes)
      trackingEpisodesCount(episodes),
    if (hit.finalVolume case final int volumes) trackingVolumesCount(volumes),
    if (hit.totalChapters case final int chapters)
      trackingChaptersCount(chapters),
    if (hit.isFinished case final bool finished)
      finished
          ? t.media_tracking_track_finished
          : t.media_tracking_track_releasing,
    '#${hit.subjectId}',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiStaggeredEntrance(
      index: index,
      child: FushiPressScale(
        enabled: !busy,
        child: FushiGroupedListItem(
          index: index,
          count: count,
          selected: selected,
          onTap: busy ? null : onPick,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (current)
                  Row(
                    key: const ValueKey<String>('tracking-link-current'),
                    spacing: 4,
                    children: <Widget>[
                      FushiIcon(FushiIcons.check, size: 16, color: cs.primary),
                      Text(
                        t.media_tracking_link_current,
                        style: type.labelMedium.copyWith(color: cs.primary),
                      ),
                    ],
                  ),
                Text(
                  hit.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: type.bodyLargeEmphasized,
                ),
                if (hit.altName.isNotEmpty)
                  Text(
                    hit.altName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
                  ),
                const SizedBox(height: 2),
                Text(
                  _facts(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The least number a link's number field takes for [mode]: an episode or
/// volume is counted from 1, chapters before a book from 0.
int trackingNumberMin(TrackingProgressMode mode) =>
    mode == TrackingProgressMode.chapter ? 0 : 1;

/// What a link's number means for [mode] (the field's helper line).
String? trackingNumberHelp(TrackingProgressMode mode) => switch (mode) {
  TrackingProgressMode.episode => t.media_tracking_link_offset_helper_episode,
  TrackingProgressMode.volume => t.media_tracking_link_offset_helper_volume,
  TrackingProgressMode.chapter => t.media_tracking_link_offset_helper_chapter,
  _ => null,
};
