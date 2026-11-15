/// Rows of the Tracking page: the state header, a "Needs attention" row and
/// a link row. Plain stateless widgets over values (no per-row async work).
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show formatActivityRelativeTime;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        MediaTrackingActivityRow,
        MediaTrackingIgnoredRow,
        MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

/// The "Last sync" text of the header.
String trackingPageLastSync(int lastSyncAt, DateTime now) => lastSyncAt <= 0
    ? t.media_tracking_never_synced
    : formatActivityRelativeTime(lastSyncAt, now);

/// The progress unit of [mapping] in words.
String trackingLinkUnitLabel(MediaTrackingMappingRow mapping) =>
    switch (TrackingProgressMode.tryParse(mapping.progressMode)) {
      TrackingProgressMode.volume => t.media_tracking_track_by_volume(
        volume: '${mapping.progressOffset}',
      ),
      TrackingProgressMode.chapter => t.media_tracking_track_by_chapter,
      // One video / episode sends its own number; a collection or season
      // sends its episodes from the starting number on (T2 G11).
      TrackingProgressMode.episode =>
        isSeriesTrackingKey(mapping.mediaType)
            ? mapping.progressOffset == 1
                  ? t.media_tracking_episode
                  : t.media_tracking_link_unit_episodes_from(
                      n: '${mapping.progressOffset}',
                    )
            : t.media_tracking_link_unit_episode_n(
                n: '${mapping.progressOffset}',
              ),
      _ => trackingProgressModeLabel(mapping.progressMode),
    };

/// Connected sites and their state, last sync, "Sync now" and the way to the
/// settings page.
class TrackingStatusHeader extends StatelessWidget {
  const TrackingStatusHeader({
    required this.data,
    required this.syncing,
    required this.onSyncNow,
    required this.onOpenSettings,
    this.onLinkItem,
    super.key,
  });

  final TrackingPageData data;
  final bool syncing;
  final VoidCallback onSyncNow;
  final VoidCallback onOpenSettings;

  /// Links any library item by hand (also one without progress yet); null
  /// = no such action.
  final VoidCallback? onLinkItem;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<MediaTrackingProviderStatus> sites = data.connectedSites;
    return Padding(
      key: const ValueKey<String>('tracking-page-header'),
      padding: const EdgeInsets.only(bottom: 12),
      child: FushiGroupedListItem(
        index: 0,
        count: 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: <Widget>[
              if (sites.isEmpty)
                Text(
                  t.home_tracking_panel_not_connected,
                  style: type.bodyLargeEmphasized,
                )
              else
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final MediaTrackingProviderStatus site in sites)
                      Row(
                        key: ValueKey<String>(
                          'tracking-page-site-${site.providerId}',
                        ),
                        mainAxisSize: MainAxisSize.min,
                        spacing: 6,
                        children: <Widget>[
                          FushiIcon(
                            site.unauthorized
                                ? FushiIcons.syncProblem
                                : FushiIcons.check,
                            size: 18,
                            color: site.unauthorized ? cs.error : cs.primary,
                          ),
                          Text(
                            site.unauthorized
                                ? t.media_tracking_page_site_sign_in_needed(
                                    site: data.siteName(site.providerId),
                                  )
                                : t.media_tracking_page_site_signed_in(
                                    site: data.siteName(site.providerId),
                                  ),
                            style: type.bodyMedium.copyWith(
                              color: site.unauthorized ? cs.error : null,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              Text(
                '${t.media_tracking_last_sync}: '
                '${trackingPageLastSync(data.lastSyncAt, DateTime.now())}',
                key: const ValueKey<String>('tracking-page-last-sync'),
                style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  FushiPressScale(
                    child: FushiTextButton.icon(
                      key: const ValueKey<String>('tracking-page-settings'),
                      onPressed: onOpenSettings,
                      icon: const FushiIcon(FushiIcons.settings),
                      label: Text(t.settings),
                    ),
                  ),
                  if (sites.isNotEmpty && onLinkItem != null)
                    FushiPressScale(
                      child: FushiTextButton.icon(
                        key: const ValueKey<String>('tracking-page-link-item'),
                        onPressed: onLinkItem,
                        icon: const FushiIcon(FushiIcons.link),
                        label: Text(t.media_tracking_page_link_item),
                      ),
                    ),
                  if (sites.isNotEmpty)
                    FushiPressScale(
                      enabled: !syncing,
                      child: FushiFilledButton.tonalIcon(
                        key: const ValueKey<String>('tracking-page-sync-now'),
                        onPressed: syncing ? null : onSyncNow,
                        icon: syncing
                            ? const SizedBox.square(
                                dimension: 18,
                                child: FushiCircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const FushiIcon(FushiIcons.sync),
                        label: Text(t.media_tracking_sync_now),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One "Needs attention" entry: a site to sign in to again, a failed send
/// (with the error and a retry), or an item to link.
class TrackingAttentionRow extends StatelessWidget {
  const TrackingAttentionRow({
    required this.entry,
    required this.index,
    required this.count,
    required this.siteName,
    required this.busy,
    required this.onTap,
    required this.onRetry,
    this.onIgnore,
    this.onIgnoreSeries,
    super.key,
  });

  final TrackingAttentionEntry entry;
  final int index;
  final int count;
  final String? siteName;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onRetry;

  /// "Don't track" in the row menu; null = no menu (sign-in rows).
  final VoidCallback? onIgnore;

  /// "Don't track the series" in the row menu (null = the item is in no
  /// series).
  final VoidCallback? onIgnoreSeries;

  @override
  Widget build(BuildContext context) {
    final String site = siteName ?? '';
    final (
      IconData icon,
      String title,
      String subtitle,
      Widget trailing,
    ) = switch (entry.reason) {
      TrackingAttentionReason.signIn => (
        FushiIcons.login,
        t.media_tracking_page_sign_in_row(site: site),
        t.media_tracking_page_sign_in_hint(site: site),
        const FushiIcon(FushiIcons.chevronRight),
      ),
      TrackingAttentionReason.failed => (
        FushiIcons.syncProblem,
        entry.title,
        <String>[
          if (entry.rowKind case final TrackingRowKind kind)
            trackingRowKindLabel(kind),
          site,
          t.media_tracking_reason_send_failed(error: entry.error ?? ''),
        ].where((String part) => part.isNotEmpty).join(' · '),
        FushiIconButtonControl(
          key: ValueKey<String>('tracking-attention-retry-$index'),
          tooltip: t.retry,
          onPressed: busy ? null : onRetry,
          icon: const FushiIcon(FushiIcons.refresh),
        ),
      ),
      // Apple has no "link off" glyph (it maps to the plain link, the same as
      // the link button next to it): a question mark says "which entry?"
      // (T1 F19).
      TrackingAttentionReason.unlinked => (
        isGlassDesign(context) ? FushiIcons.help : FushiIcons.linkOff,
        entry.title,
        <String>[
          if (entry.rowKind case final TrackingRowKind kind)
            trackingRowKindLabel(kind),
          trackingUnlinkedDetailLabel(entry.detail),
          // A media server season: how many episodes the link covers, and
          // where they were played.
          if ((entry.item?.itemCount ?? 1) > 1)
            t.media_tracking_remote_episodes_watched(
              n: '${entry.item!.itemCount}',
            ),
          if (entry.item?.source case final String source
              when source.trim().isNotEmpty)
            source.trim(),
        ].join(' · '),
        FushiIconButtonControl(
          tooltip: t.media_tracking_track_approve,
          onPressed: onTap,
          icon: const FushiIcon(FushiIcons.link),
        ),
      ),
      TrackingAttentionReason.inert ||
      TrackingAttentionReason.inertMediaServer => (
        FushiIcons.syncProblem,
        entry.title,
        <String>[
          if (entry.rowKind case final TrackingRowKind kind)
            trackingRowKindLabel(kind),
          site,
          entry.reason == TrackingAttentionReason.inertMediaServer
              ? t.media_tracking_page_inert_server_link
              : t.media_tracking_page_inert_link,
        ].where((String part) => part.isNotEmpty).join(' · '),
        FushiIconButtonControl(
          key: ValueKey<String>('tracking-attention-remove-$index'),
          tooltip: t.media_tracking_page_remove_link,
          onPressed: onTap,
          icon: const FushiIcon(FushiIcons.linkOff),
        ),
      ),
    };
    final bool problem = entry.reason != TrackingAttentionReason.unlinked;
    final VoidCallback? onIgnore = this.onIgnore;
    return _RowShell(
      index: index,
      count: count,
      child: FushiListItem(
        leading: FushiListLeadingIcon(
          icon,
          shape: FushiLeadingShape.square,
          tone: problem ? FushiCardTone.error : FushiCardTone.secondary,
        ),
        title: entry.reason == TrackingAttentionReason.signIn
            ? Text(title)
            : TrackingRowTitle(title: title, rawName: entry.rawName),
        titleMaxLines: 2,
        subtitle: Text(subtitle),
        subtitleMaxLines: 3,
        trailing: onIgnore == null
            ? trailing
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  trailing,
                  TrackingRowMenu(
                    key: ValueKey<String>('tracking-attention-menu-$index'),
                    actions: <TrackingRowAction>[
                      TrackingRowAction(
                        id: 'ignore',
                        label: t.media_tracking_ignore_action,
                        icon: FushiIcons.block,
                        onSelected: onIgnore,
                      ),
                      if (onIgnoreSeries case final VoidCallback series)
                        TrackingRowAction(
                          id: 'ignore-series',
                          label: t.media_tracking_ignore_series_action,
                          icon: FushiIcons.block,
                          onSelected: series,
                        ),
                    ],
                  ),
                ],
              ),
        onTap: onTap,
      ),
    );
  }
}

/// One link: local title, kind, site, the site's title, progress unit; tap
/// changes the link, the buttons open it on the site or remove it.
class TrackingLinkedRow extends StatelessWidget {
  const TrackingLinkedRow({
    required this.entry,
    required this.index,
    required this.count,
    required this.siteName,
    required this.failed,
    required this.onTap,
    required this.onOpen,
    required this.onRemove,
    this.paused = false,
    this.inGroup = false,
    this.onIgnore,
    this.onIgnoreSeries,
    this.onTrackAgain,
    super.key,
  });

  final TrackingLinkedEntry entry;
  final int index;
  final int count;
  final String siteName;
  final bool failed;

  /// A link shown inside an expanded group: the group row names the site
  /// entry, so this row leads with the local title and its unit.
  final bool inGroup;
  final VoidCallback onTap;

  /// Null when the site's page address is not known.
  final VoidCallback? onOpen;
  final VoidCallback onRemove;

  /// The item is not tracked: the link is kept but nothing is sent.
  final bool paused;

  /// "Don't track" in the row menu (null = not offered).
  final VoidCallback? onIgnore;

  /// "Don't track the series" in the row menu (null = not offered).
  final VoidCallback? onIgnoreSeries;

  /// "Track again" in the row menu (null = not offered).
  final VoidCallback? onTrackAgain;

  MediaTrackingMappingRow get mapping => entry.mapping;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? onOpen = this.onOpen;
    final List<TrackingRowAction> menu = <TrackingRowAction>[
      if (onTrackAgain case final VoidCallback onTrackAgain)
        TrackingRowAction(
          id: 'track-again',
          label: t.media_tracking_ignore_undo_action,
          icon: FushiIcons.undo,
          onSelected: onTrackAgain,
        ),
      if (onIgnore case final VoidCallback onIgnore)
        TrackingRowAction(
          id: 'ignore',
          label: t.media_tracking_ignore_action,
          icon: FushiIcons.block,
          onSelected: onIgnore,
        ),
      if (onIgnoreSeries case final VoidCallback onIgnoreSeries)
        TrackingRowAction(
          id: 'ignore-series',
          label: t.media_tracking_ignore_series_action,
          icon: FushiIcons.block,
          onSelected: onIgnoreSeries,
        ),
    ];
    return _RowShell(
      index: index,
      count: count,
      child: FushiListItem(
        leading: FushiListLeadingIcon(
          paused
              ? FushiIcons.pause
              : failed
              ? FushiIcons.syncProblem
              : FushiIcons.link,
          shape: FushiLeadingShape.square,
          tone: failed && !paused
              ? FushiCardTone.error
              : FushiCardTone.secondary,
        ),
        // Inside a group every link shares the cleaned title: the raw local
        // name tells them apart (T2 G11).
        title: inGroup
            ? TrackingRowTitle(title: entry.rawName ?? entry.title)
            : TrackingRowTitle(title: entry.title, rawName: entry.rawName),
        titleMaxLines: 2,
        subtitle: Text(
          <String>[
            if (!inGroup)
              <String>[
                if (entry.rowKind case final TrackingRowKind kind)
                  trackingRowKindLabel(kind),
                siteName,
                mapping.subjectName,
              ].join(' · '),
            trackingLinkUnitLabel(mapping),
            if (paused) t.media_tracking_ignore_paused,
          ].join('\n'),
        ),
        subtitleMaxLines: 3,
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (onOpen != null)
              FushiIconButtonControl(
                key: ValueKey<String>('tracking-linked-open-${mapping.id}'),
                tooltip: t.media_tracking_page_open_on_site(site: siteName),
                onPressed: onOpen,
                icon: const FushiIcon(FushiIcons.openInNew),
              ),
            FushiIconButtonControl(
              key: ValueKey<String>('tracking-linked-remove-${mapping.id}'),
              tooltip: t.media_tracking_page_remove_link,
              onPressed: onRemove,
              icon: const FushiIcon(FushiIcons.linkOff),
            ),
            if (menu.isNotEmpty)
              TrackingRowMenu(
                key: ValueKey<String>('tracking-linked-menu-${mapping.id}'),
                actions: menu,
              ),
          ],
        ),
      ),
    );
  }
}

/// One do-not-track entry: the local title, its kind (or "Whole series"),
/// when it was ignored, and "Track again".
class TrackingIgnoredRow extends StatelessWidget {
  const TrackingIgnoredRow({
    required this.row,
    required this.names,
    required this.index,
    required this.count,
    required this.onTrackAgain,
    super.key,
  });

  final MediaTrackingIgnoredRow row;

  /// Title, raw name and kind ([TrackingPageData.ignoredNames]).
  final TrackingNamedRow names;
  final int index;
  final int count;
  final VoidCallback onTrackAgain;

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      index: index,
      count: count,
      child: FushiListItem(
        leading: const FushiListLeadingIcon(
          FushiIcons.block,
          shape: FushiLeadingShape.square,
          tone: FushiCardTone.secondary,
        ),
        title: TrackingRowTitle(title: names.title, rawName: names.rawName),
        titleMaxLines: 2,
        subtitle: Text(
          <String>[
            if (names.rowKind case final TrackingRowKind kind)
              trackingRowKindLabel(kind),
            if (row.mediaType == TrackingMediaType.remoteSeries.value)
              t.media_tracking_ignore_whole_season
            else if (isSeriesTrackingKey(row.mediaType))
              t.media_tracking_ignore_whole_series,
            formatActivityRelativeTime(row.createdAt, DateTime.now()),
          ].join(' · '),
        ),
        subtitleMaxLines: 2,
        trailing: FushiIconButtonControl(
          key: ValueKey<String>('tracking-ignored-undo-${row.id}'),
          tooltip: t.media_tracking_ignore_undo_action,
          onPressed: onTrackAgain,
          icon: const FushiIcon(FushiIcons.undo),
        ),
      ),
    );
  }
}

/// What one Activity row sent, in words: "Episode 5", "Volume 3 ·
/// finished", or a game's collection status.
String trackingActivitySentLabel(MediaTrackingActivityRow row) {
  final String what = switch (TrackingProgressMode.tryParse(row.progressMode)) {
    TrackingProgressMode.status => switch (row.progress) {
      1 => t.game_status_want_to_play,
      2 => t.game_status_played,
      3 => t.game_status_playing,
      4 => t.game_status_on_hold,
      5 => t.game_status_dropped,
      _ => '${t.media_tracking_status} ${row.progress}',
    },
    _ => '${trackingProgressModeLabel(row.progressMode)} ${row.progress}',
  };
  return row.completed && row.progressMode != TrackingProgressMode.status.value
      ? '$what · ${t.media_tracking_activity_finished}'
      : what;
}

/// One send: the local title, the site, what was sent, when, and the error
/// when it failed.
class TrackingActivityRow extends StatelessWidget {
  const TrackingActivityRow({
    required this.row,
    required this.names,
    required this.index,
    required this.count,
    required this.siteName,
    super.key,
  });

  final MediaTrackingActivityRow row;

  /// Title, raw name and kind ([TrackingPageData.activityNames]).
  final TrackingNamedRow names;
  final int index;
  final int count;
  final String siteName;

  @override
  Widget build(BuildContext context) {
    final String? error = row.error;
    return _RowShell(
      index: index,
      count: count,
      child: FushiListItem(
        leading: FushiListLeadingIcon(
          row.ok ? FushiIcons.check : FushiIcons.syncProblem,
          shape: FushiLeadingShape.square,
          tone: row.ok ? FushiCardTone.secondary : FushiCardTone.error,
        ),
        title: TrackingRowTitle(title: names.title, rawName: names.rawName),
        titleMaxLines: 2,
        subtitle: Text(
          '${row.ok ? t.media_tracking_activity_sent : t.media_tracking_activity_failed}'
          ' · $siteName · ${trackingActivitySentLabel(row)} · '
          '${formatActivityRelativeTime(row.createdAt, DateTime.now())}'
          '${!row.ok && error != null ? '\n$error' : ''}',
        ),
        subtitleMaxLines: 4,
      ),
    );
  }
}

/// Why an unlinked item waits for the user, in words.
String trackingUnlinkedDetailLabel(TrackingUnlinkedDetail? detail) =>
    switch (detail) {
      TrackingUnlinkedDetail.multiSeason =>
        t.media_tracking_multi_season_reason,
      TrackingUnlinkedDetail.suggestions => t.media_tracking_reason_suggestions,
      TrackingUnlinkedDetail.serverNoMatch =>
        t.media_tracking_reason_server_no_match,
      TrackingUnlinkedDetail.notScraped => t.media_tracking_reason_not_scraped,
      TrackingUnlinkedDetail.removedByUser =>
        t.media_tracking_reason_removed_by_you,
      TrackingUnlinkedDetail.noMatch ||
      null => t.media_tracking_reason_no_match,
    };

/// A row's title: the cleaned title, and under it the raw local name in a
/// smaller line when that differs (whole name in a tooltip and for screen
/// readers).
class TrackingRowTitle extends StatelessWidget {
  const TrackingRowTitle({required this.title, this.rawName, super.key});

  final String title;
  final String? rawName;

  @override
  Widget build(BuildContext context) {
    final String? raw = rawName;
    if (raw == null) return Text(title);
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        FushiTooltip(
          message: raw,
          child: Text(
            raw,
            key: const ValueKey<String>('tracking-row-raw-name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            semanticsLabel: raw,
            style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// Several links to one site entry (T1 F21): the entry's title, how many
/// links and which site; tap (or the chevron) shows or hides the links.
class TrackingLinkGroupRow extends StatelessWidget {
  const TrackingLinkGroupRow({
    required this.group,
    required this.index,
    required this.count,
    required this.siteName,
    required this.expanded,
    required this.onToggle,
    this.failed = false,
    this.onOpen,
    super.key,
  });

  final TrackingLinkGroup group;
  final int index;
  final int count;
  final String siteName;
  final bool expanded;
  final VoidCallback onToggle;

  /// A member's last send failed.
  final bool failed;

  /// Opens the entry on the site; null when its address is not known.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? onOpen = this.onOpen;
    final Set<TrackingRowKind> kinds = <TrackingRowKind>{
      for (final TrackingLinkedEntry entry in group.members) ?entry.rowKind,
    };
    final String toggle = expanded
        ? t.media_tracking_group_collapse
        : t.media_tracking_group_expand;
    return _RowShell(
      index: index,
      count: count,
      child: Semantics(
        expanded: expanded,
        child: FushiListItem(
          leading: FushiListLeadingIcon(
            failed ? FushiIcons.syncProblem : FushiIcons.link,
            shape: FushiLeadingShape.square,
            tone: failed ? FushiCardTone.error : FushiCardTone.secondary,
          ),
          title: Text(group.subjectName),
          titleMaxLines: 2,
          subtitle: Text(
            <String>[
              for (final TrackingRowKind kind in kinds)
                trackingRowKindLabel(kind),
              t.media_tracking_group_links(n: '${group.members.length}'),
              siteName,
            ].join(' · '),
          ),
          subtitleMaxLines: 2,
          onTap: onToggle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (onOpen != null)
                FushiIconButtonControl(
                  key: ValueKey<String>('tracking-group-open-${group.key}'),
                  tooltip: t.media_tracking_page_open_on_site(site: siteName),
                  onPressed: onOpen,
                  icon: const FushiIcon(FushiIcons.openInNew),
                ),
              FushiIconButtonControl(
                key: ValueKey<String>('tracking-group-toggle-${group.key}'),
                tooltip: toggle,
                onPressed: onToggle,
                icon: AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  child: const FushiIcon(FushiIcons.expandMore),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Indents a link shown inside an expanded group.
class TrackingGroupMember extends StatelessWidget {
  const TrackingGroupMember({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 24),
    child: child,
  );
}

/// One entry of a row's "More actions" menu.
final class TrackingRowAction {
  const TrackingRowAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.onSelected,
  });

  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

/// The "⋯" menu of a Tracking page row (Material and Apple menus alike).
class TrackingRowMenu extends StatelessWidget {
  const TrackingRowMenu({required this.actions, super.key});

  final List<TrackingRowAction> actions;

  @override
  Widget build(BuildContext context) => FushiOverflowMenu<String>(
    tooltip: t.media_tracking_page_more_actions,
    // Apple's overflow glyph is the horizontal ellipsis (T1 F19).
    icon: isGlassDesign(context) ? FushiIcons.moreHoriz : FushiIcons.more,
    items: <PopupMenuEntry<String>>[
      for (final TrackingRowAction action in actions)
        FushiPopupMenuItem<String>(
          key: ValueKey<String>('tracking-row-action-${action.id}'),
          value: action.id,
          label: action.label,
          icon: action.icon,
        ),
    ],
    onSelected: (String id) {
      for (final TrackingRowAction action in actions) {
        if (action.id == id) action.onSelected();
      }
    },
  );
}

/// Grouped list cell with hover lift and press feedback.
class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.index,
    required this.count,
    required this.child,
  });

  final int index;
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: 1.005,
    builder: (BuildContext context, bool hovering) => FushiPressScale(
      child: FushiGroupedListItem(index: index, count: count, child: child),
    ),
  );
}
