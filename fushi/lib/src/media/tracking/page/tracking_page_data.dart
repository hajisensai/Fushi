/// What the Tracking page lists, computed once per snapshot (no I/O): the
/// "Needs attention" entries, every link, and the filter over them. The rows
/// are plain values so a list of thousands builds lazily with no per-row
/// async work.
library;

import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        MediaTrackingActivityRow,
        MediaTrackingIgnoredRow,
        MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';

/// The page's tabs.
enum TrackingPageTab {
  attention,
  linked,

  /// The do-not-track list.
  ignored,

  /// The local log of sends, newest first.
  activity,
}

/// Why an entry is in "Needs attention".
enum TrackingAttentionReason {
  /// A connected site rejected the stored sign-in.
  signIn,

  /// The last send of a link failed (still queued, retried later).
  failed,

  /// A local item with progress that no site is linked to, while a
  /// connected site tracks its kind.
  unlinked,

  /// A saved link that can never send (a video collection that holds more
  /// than one season, [MediaTrackingHomeSnapshot.inertMappingIds]).
  inert,

  /// A library link of a row added from a media server, made before such
  /// rows were tracked by their server identity only
  /// ([MediaTrackingHomeSnapshot.mediaServerInertMappingIds]): it never
  /// sends.
  inertMediaServer,
}

/// Why an unlinked item was not linked by itself, from what the app
/// knows (never guessed).
enum TrackingUnlinkedDetail {
  /// A video collection holding more than one season.
  multiSeason,

  /// A site found possible matches that wait for the user.
  suggestions,

  /// A media server episode whose server ids matched no site entry.
  serverNoMatch,

  /// A library video without scraped metadata (automatic linking matches
  /// from it).
  notScraped,

  /// Automatic linking found no sure match.
  noMatch,

  /// The user removed its link by hand: automatic linking leaves it alone
  /// (T2 G6, G7).
  removedByUser,
}

/// One "Needs attention" row.
final class TrackingAttentionEntry {
  const TrackingAttentionEntry._({
    required this.reason,
    required this.title,
    this.rawName,
    this.kind,
    this.rowKind,
    this.siteId,
    this.error,
    this.item,
    this.mapping,
    this.detail,
  });

  final TrackingAttentionReason reason;

  /// The cleaned title ([trackingRowTitle]); the site's name for
  /// [TrackingAttentionReason.signIn].
  final String title;

  /// The raw local name when it says more than [title] (second line).
  final String? rawName;

  /// Null for sign-in rows (they are about a site, not a title).
  final TrackingKind? kind;

  /// How the row names its kind ([trackingRowKindOf]).
  final TrackingRowKind? rowKind;

  /// Unlinked rows: why it was not linked by itself.
  final TrackingUnlinkedDetail? detail;
  final String? siteId;
  final String? error;
  final MediaTrackingUnlinkedItem? item;
  final MediaTrackingMappingRow? mapping;
}

/// [value] (a persisted `TrackingKind.value`) as the enum; null when unknown.
TrackingKind? trackingKindOfValue(String value) {
  for (final TrackingKind kind in TrackingKind.values) {
    if (kind.value == value) return kind;
  }
  return null;
}

/// [value] (a persisted `TrackingMediaType.value`) as the enum.
TrackingMediaType? trackingMediaTypeOfValue(String value) {
  for (final TrackingMediaType type in TrackingMediaType.values) {
    if (type.value == value) return type;
  }
  return null;
}

/// The page's view of one [MediaTrackingHomeSnapshot].
final class TrackingPageData {
  TrackingPageData._({
    required this.connectedSites,
    required this.siteNames,
    required this.lastSyncAt,
    required this.attention,
    required this.linked,
    required this.linkGroups,
    required this.failedMappingIds,
    required this.ignored,
    required this.ignoreIndex,
    required this.seriesIndex,
    required this.activity,
    required this.facts,
  });

  /// [ignored] and [ignoreIndex]: the do-not-track list (rows, and which
  /// links it pauses). [seriesIndex]: which series each item is in ("Don't
  /// track the series" from a member's row).
  factory TrackingPageData.of(
    MediaTrackingHomeSnapshot snapshot, {
    List<MediaTrackingIgnoredRow> ignored = const <MediaTrackingIgnoredRow>[],
    TrackingIgnoreIndex ignoreIndex = TrackingIgnoreIndex.empty,
    TrackingSeriesIndex seriesIndex = TrackingSeriesIndex.empty,
    List<MediaTrackingActivityRow> activity =
        const <MediaTrackingActivityRow>[],
    TrackingRowFacts facts = TrackingRowFacts.empty,
  }) {
    ({String title, String? raw}) names(String raw, String type, String key) {
      final String title = trackingRowTitle(raw, facts.of(type, key));
      return (title: title, raw: trackingRowRawName(raw, title));
    }

    TrackingRowKind? linkKind(MediaTrackingMappingRow mapping) =>
        trackingRowKindOf(
          trackingKindOfValue(mapping.kind),
          nature: facts.of(mapping.mediaType, mapping.mediaKey).nature,
          linked: true,
        );
    TrackingAttentionEntry ofMapping(
      TrackingAttentionReason reason,
      MediaTrackingMappingRow mapping, {
      required String siteId,
      String? error,
      String? rawTitle,
    }) {
      final ({String title, String? raw}) n = names(
        rawTitle ?? mapping.mediaTitle,
        mapping.mediaType,
        mapping.mediaKey,
      );
      return TrackingAttentionEntry._(
        reason: reason,
        title: n.title,
        rawName: n.raw,
        kind: trackingKindOfValue(mapping.kind),
        rowKind: linkKind(mapping),
        siteId: siteId,
        error: error,
        mapping: mapping,
      );
    }

    TrackingAttentionEntry ofUnlinked(MediaTrackingUnlinkedItem item) {
      final TrackingItemFacts itemFacts = facts.of(
        item.mediaType.value,
        item.mediaKey,
      );
      final ({String title, String? raw}) n = names(
        item.mediaTitle,
        item.mediaType.value,
        item.mediaKey,
      );
      final bool remote =
          item.mediaType == TrackingMediaType.remoteSeries ||
          item.mediaType == TrackingMediaType.remoteVideo;
      final bool video =
          item.mediaType == TrackingMediaType.video ||
          item.mediaType == TrackingMediaType.videoCollection;
      return TrackingAttentionEntry._(
        reason: TrackingAttentionReason.unlinked,
        title: n.title,
        rawName: n.raw,
        kind: item.kind,
        rowKind: trackingRowKindOf(item.kind, nature: itemFacts.nature),
        item: item,
        detail: item.multiSeason
            ? TrackingUnlinkedDetail.multiSeason
            : item.removedByUser
            ? TrackingUnlinkedDetail.removedByUser
            : item.hasSuggestions
            ? TrackingUnlinkedDetail.suggestions
            : remote
            ? TrackingUnlinkedDetail.serverNoMatch
            : video && !itemFacts.scraped
            ? TrackingUnlinkedDetail.notScraped
            : TrackingUnlinkedDetail.noMatch,
      );
    }

    TrackingLinkedEntry linkedEntry(MediaTrackingMappingRow mapping) {
      final ({String title, String? raw}) n = names(
        mapping.mediaTitle,
        mapping.mediaType,
        mapping.mediaKey,
      );
      return TrackingLinkedEntry(
        mapping: mapping,
        title: n.title,
        rawName: n.raw,
        rowKind: linkKind(mapping),
      );
    }

    final List<MediaTrackingProviderStatus> connected =
        <MediaTrackingProviderStatus>[
          for (final MediaTrackingProviderStatus site in snapshot.sites)
            if (site.enabled && site.configured) site,
        ];
    final Set<String> connectedIds = <String>{
      for (final MediaTrackingProviderStatus site in connected) site.providerId,
    };
    String nameOf(String id) => snapshot.siteNames[id] ?? id;
    final Map<int, MediaTrackingMappingRow> mappingById =
        <int, MediaTrackingMappingRow>{
          for (final MediaTrackingMappingRow row in snapshot.mappings)
            row.id: row,
        };
    int lastSyncAt = 0;
    final List<TrackingAttentionEntry> signIn = <TrackingAttentionEntry>[];
    final List<TrackingAttentionEntry> failed = <TrackingAttentionEntry>[];
    final Set<int> failedIds = <int>{};
    for (final MediaTrackingProviderStatus site in connected) {
      if (site.lastSyncAt > lastSyncAt) lastSyncAt = site.lastSyncAt;
      if (site.unauthorized) {
        signIn.add(
          TrackingAttentionEntry._(
            reason: TrackingAttentionReason.signIn,
            title: nameOf(site.providerId),
            siteId: site.providerId,
          ),
        );
      }
      for (final MediaTrackingFailure failure in site.failures) {
        if (!failedIds.add(failure.mappingId)) continue;
        final MediaTrackingMappingRow? mapping = mappingById[failure.mappingId];
        failed.add(
          mapping == null
              ? TrackingAttentionEntry._(
                  reason: TrackingAttentionReason.failed,
                  title: failure.mediaTitle,
                  siteId: site.providerId,
                  error: failure.error,
                )
              : ofMapping(
                  TrackingAttentionReason.failed,
                  mapping,
                  siteId: site.providerId,
                  error: failure.error,
                  rawTitle: failure.mediaTitle,
                ),
        );
      }
    }
    return TrackingPageData._(
      connectedSites: connected,
      siteNames: snapshot.siteNames,
      lastSyncAt: lastSyncAt,
      attention: <TrackingAttentionEntry>[
        ...signIn,
        ...failed,
        for (final MediaTrackingMappingRow mapping in snapshot.mappings)
          if (snapshot.inertMappingIds.contains(mapping.id))
            ofMapping(
              snapshot.mediaServerInertMappingIds.contains(mapping.id)
                  ? TrackingAttentionReason.inertMediaServer
                  : TrackingAttentionReason.inert,
              mapping,
              siteId: mapping.provider,
            ),
        if (connectedIds.isNotEmpty)
          for (final MediaTrackingUnlinkedItem item in snapshot.unlinked)
            ofUnlinked(item),
      ],
      linked: snapshot.mappings,
      linkGroups: groupTrackingLinks(<TrackingLinkedEntry>[
        for (final MediaTrackingMappingRow mapping in snapshot.mappings)
          linkedEntry(mapping),
      ]),
      failedMappingIds: failedIds,
      ignored: ignored,
      ignoreIndex: ignoreIndex,
      seriesIndex: seriesIndex,
      activity: activity,
      facts: facts,
    );
  }

  /// Sites that are on and signed in, in registry order.
  final List<MediaTrackingProviderStatus> connectedSites;
  final Map<String, String> siteNames;

  /// Latest sync attempt on a connected site (epoch ms; 0 = never).
  final int lastSyncAt;

  /// Sign-in problems first, then failed sends, then items to link.
  final List<TrackingAttentionEntry> attention;

  /// Every link on every site (chapter companions left out).
  final List<MediaTrackingMappingRow> linked;

  /// [linked] grouped by site entry ([groupTrackingLinks]), in [linked]'s
  /// order of each group's first link.
  final List<TrackingLinkGroup> linkGroups;

  /// Work names and video natures of local items (row titles and kinds).
  final TrackingRowFacts facts;

  /// Links whose last send failed.
  final Set<int> failedMappingIds;

  /// The do-not-track list, newest first.
  final List<MediaTrackingIgnoredRow> ignored;

  /// The do-not-track list as a lookup (collections resolved to members).
  final TrackingIgnoreIndex ignoreIndex;

  /// Which series each local item is in.
  final TrackingSeriesIndex seriesIndex;

  /// The local log of sends, newest first.
  final List<MediaTrackingActivityRow> activity;

  /// The series [mediaType] + [mediaKey] is in, when that series is not
  /// ignored already (null: no "Don't track the series").
  TrackingSeriesRef? seriesOf(String mediaType, String mediaKey) {
    final TrackingSeriesRef? series = seriesIndex.seriesOf(mediaType, mediaKey);
    if (series == null || ignoreIndex.isListed(series.type.value, series.key)) {
      return null;
    }
    return series;
  }

  /// The series of an attention row's item or link (sign-in rows: none).
  TrackingSeriesRef? seriesOfEntry(TrackingAttentionEntry entry) {
    if (entry.item case final MediaTrackingUnlinkedItem item) {
      return seriesOf(item.mediaType.value, item.mediaKey);
    }
    if (entry.mapping case final MediaTrackingMappingRow mapping) {
      return seriesOf(mapping.mediaType, mapping.mediaKey);
    }
    return null;
  }

  /// [mapping]'s item is not tracked: the link is kept but paused.
  bool isPaused(MediaTrackingMappingRow mapping) =>
      ignoreIndex.covers(mapping.mediaType, mapping.mediaKey);

  /// [mapping]'s item has a do-not-track row of its own ("Track again" on
  /// the link works; paused through a collection is undone on "Ignored").
  bool isIgnoredDirectly(MediaTrackingMappingRow mapping) =>
      ignoreIndex.isListed(mapping.mediaType, mapping.mediaKey);

  bool get hasConnectedSite => connectedSites.isNotEmpty;

  String siteName(String id) => siteNames[id] ?? id;

  /// The row title, raw name and kind of a do-not-track row.
  TrackingNamedRow ignoredNames(MediaTrackingIgnoredRow row) {
    final String raw = row.mediaTitle.trim().isEmpty
        ? row.mediaKey
        : row.mediaTitle;
    final TrackingItemFacts itemFacts = facts.of(row.mediaType, row.mediaKey);
    final String title = trackingRowTitle(raw, itemFacts);
    return (
      title: title,
      rawName: trackingRowRawName(raw, title),
      rowKind: trackingRowKindOf(
        trackingKindOfValue(row.kind ?? ''),
        nature: itemFacts.nature,
      ),
    );
  }

  /// The row title, raw name and kind of an Activity row (a send of a
  /// link: a video counts as linked).
  TrackingNamedRow activityNames(MediaTrackingActivityRow row) {
    final TrackingItemFacts itemFacts = facts.of(row.mediaType, row.mediaKey);
    final String title = trackingRowTitle(row.mediaTitle, itemFacts);
    return (
      title: title,
      rawName: trackingRowRawName(row.mediaTitle, title),
      rowKind: trackingRowKindOf(
        trackingKindOfValue(row.kind),
        nature: itemFacts.nature,
        linked: true,
      ),
    );
  }

  /// Row kinds that occur in [tab], in enum order (the filter offers only
  /// these).
  List<TrackingRowKind> kindsIn(TrackingPageTab tab) {
    final Set<TrackingRowKind> found = <TrackingRowKind>{
      if (tab == TrackingPageTab.attention)
        for (final TrackingAttentionEntry entry in attention) ?entry.rowKind,
      if (tab == TrackingPageTab.linked)
        for (final TrackingLinkGroup group in linkGroups)
          for (final TrackingLinkedEntry entry in group.members)
            ?entry.rowKind,
      if (tab == TrackingPageTab.ignored)
        for (final MediaTrackingIgnoredRow row in ignored)
          ?ignoredNames(row).rowKind,
      if (tab == TrackingPageTab.activity)
        for (final MediaTrackingActivityRow row in activity)
          ?activityNames(row).rowKind,
    };
    return <TrackingRowKind>[
      for (final TrackingRowKind kind in TrackingRowKind.values)
        if (found.contains(kind)) kind,
    ];
  }

  /// "Needs attention" under the filter. Sign-in rows are about a site, not
  /// a title, so they stay whatever the filter says.
  List<TrackingAttentionEntry> attentionFiltered(TrackingPageFilter filter) =>
      filter.isEmpty
      ? attention
      : <TrackingAttentionEntry>[
          for (final TrackingAttentionEntry entry in attention)
            if (entry.reason == TrackingAttentionReason.signIn ||
                filter.matches(entry.rowKind, <String>[
                  entry.title,
                  ?entry.rawName,
                ]))
              entry,
        ];

  /// Link groups under the filter: a group stays (whole) when any of its
  /// links matches; the site's title counts for the search too.
  /// A group keeps only the links whose local names match (searching "Ajin
  /// 02" lists Ajin 02, not its sibling Ajin 01, T2 G11); a match on the
  /// site entry's name keeps every link of the group that fits the kinds.
  List<TrackingLinkGroup> linkGroupsFiltered(TrackingPageFilter filter) {
    if (filter.isEmpty) return linkGroups;
    final List<TrackingLinkGroup> shown = <TrackingLinkGroup>[];
    for (final TrackingLinkGroup group in linkGroups) {
      List<TrackingLinkedEntry> members = <TrackingLinkedEntry>[
        for (final TrackingLinkedEntry entry in group.members)
          if (filter.matches(entry.rowKind, <String>[
            entry.title,
            ?entry.rawName,
          ]))
            entry,
      ];
      if (members.isEmpty) {
        members = <TrackingLinkedEntry>[
          for (final TrackingLinkedEntry entry in group.members)
            if (filter.matches(entry.rowKind, <String>[
              entry.mapping.subjectName,
            ]))
              entry,
        ];
      }
      if (members.isEmpty) continue;
      shown.add(
        members.length == group.members.length
            ? group
            : TrackingLinkGroup(
                siteId: group.siteId,
                subjectId: group.subjectId,
                subjectName: group.subjectName,
                members: members,
                parent: members.contains(group.parent) ? group.parent : null,
              ),
      );
    }
    return shown;
  }

  /// The do-not-track list under the filter.
  List<MediaTrackingIgnoredRow> ignoredFiltered(TrackingPageFilter filter) {
    if (filter.isEmpty) return ignored;
    return <MediaTrackingIgnoredRow>[
      for (final MediaTrackingIgnoredRow row in ignored)
        if (_matchesNamed(filter, ignoredNames(row))) row,
    ];
  }

  /// [rows] (the Activity log) under the filter; the site's name counts for
  /// the search too.
  List<MediaTrackingActivityRow> activityFiltered(
    List<MediaTrackingActivityRow> rows,
    TrackingPageFilter filter,
  ) {
    if (filter.isEmpty) return rows;
    return <MediaTrackingActivityRow>[
      for (final MediaTrackingActivityRow row in rows)
        if (_matchesNamed(
          filter,
          activityNames(row),
          extra: siteName(row.provider),
        ))
          row,
    ];
  }

  static bool _matchesNamed(
    TrackingPageFilter filter,
    TrackingNamedRow names, {
    String? extra,
  }) => filter.matches(names.rowKind, <String>[
    names.title,
    ?names.rawName,
    ?extra,
  ]);
}

/// A row's title, raw name (null = same as the title) and kind.
typedef TrackingNamedRow = ({
  String title,
  String? rawName,
  TrackingRowKind? rowKind,
});

/// One link as the Linked tab shows it.
final class TrackingLinkedEntry {
  const TrackingLinkedEntry({
    required this.mapping,
    required this.title,
    this.rawName,
    this.rowKind,
  });

  final MediaTrackingMappingRow mapping;

  /// The cleaned local title ([trackingRowTitle]).
  final String title;

  /// The raw local name when it says more than [title].
  final String? rawName;
  final TrackingRowKind? rowKind;
}

/// Links that point at the same entry of the same site (T1 F21): one row,
/// expandable to [members]. A single link is a group of one (a plain row).
final class TrackingLinkGroup {
  const TrackingLinkGroup({
    required this.siteId,
    required this.subjectId,
    required this.subjectName,
    required this.members,
    this.parent,
  });

  final String siteId;
  final int subjectId;

  /// The site entry's title (the first link's).
  final String subjectName;

  /// The links, in the page's order.
  final List<TrackingLinkedEntry> members;

  /// The link that covers the whole series when the group has exactly one
  /// (a collection or media server season link next to its episodes'
  /// links). A future series-level link is shown here as the group's
  /// parent. Null otherwise.
  final TrackingLinkedEntry? parent;

  /// Stable id of the group (expanded state, widget keys).
  String get key => '$siteId-$subjectId';

  bool get isSingle => members.length == 1;
}

/// [entries] grouped by site + site entry, in the order of each group's
/// first link (one pass; thousands of links stay cheap).
List<TrackingLinkGroup> groupTrackingLinks(List<TrackingLinkedEntry> entries) {
  final Map<(String, int), List<TrackingLinkedEntry>> byEntry =
      <(String, int), List<TrackingLinkedEntry>>{};
  for (final TrackingLinkedEntry entry in entries) {
    byEntry
        .putIfAbsent((
          entry.mapping.provider,
          entry.mapping.subjectId,
        ), () => <TrackingLinkedEntry>[])
        .add(entry);
  }
  final List<TrackingLinkGroup> groups = <TrackingLinkGroup>[];
  for (final List<TrackingLinkedEntry> members in byEntry.values) {
    final List<TrackingLinkedEntry> series = <TrackingLinkedEntry>[
      for (final TrackingLinkedEntry entry in members)
        if (isSeriesTrackingKey(entry.mapping.mediaType)) entry,
    ];
    final MediaTrackingMappingRow first = members.first.mapping;
    groups.add(
      TrackingLinkGroup(
        siteId: first.provider,
        subjectId: first.subjectId,
        subjectName: first.subjectName,
        members: members,
        parent: members.length > 1 && series.length == 1 ? series.single : null,
      ),
    );
  }
  return groups;
}

/// [type] is a whole-series key (a collection or a media server season).
bool isSeriesTrackingKey(String type) =>
    type == TrackingMediaType.videoCollection.value ||
    type == TrackingMediaType.bookCollection.value ||
    type == TrackingMediaType.remoteSeries.value;

/// Kind and title filter of the page. No kinds = every kind.
final class TrackingPageFilter {
  TrackingPageFilter({
    this.kinds = const <TrackingRowKind>{},
    String query = '',
  }) : _query = query.trim().toLowerCase();

  final Set<TrackingRowKind> kinds;
  final String _query;

  bool get isEmpty => kinds.isEmpty && _query.isEmpty;

  bool matches(TrackingRowKind? kind, List<String> titles) {
    if (kinds.isNotEmpty && (kind == null || !kinds.contains(kind))) {
      return false;
    }
    if (_query.isEmpty) return true;
    for (final String title in titles) {
      if (title.toLowerCase().contains(_query)) return true;
    }
    return false;
  }
}
