/// Media tracking on the home page ([HomeWidgetKind.tracking]).
///
/// Two parts, both read from one [MediaTrackingHomeSnapshot]:
/// - [HomeTrackingPanel]: the 2×1 home widget. It stays on the home page once
///   placed; with nothing to do it says so in one line. Users who never edited
///   their home page get it in the first layout only while something needs
///   them ([HomeTrackingSummary.needsAttention], the old automatic rule).
/// - [homeTrackingMark]: the state of one Continue entry (sent / not linked /
///   last send failed), drawn by the Continue component on the entry itself.
///
/// The detail (which titles, which errors, sync now, linking) lives on the
/// Tracking page (`media/tracking/page/tracking_page.dart`); the strip only
/// leads there.
library;

import 'package:fushi_core/fushi_core.dart' show MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show formatActivityRelativeTime;
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// The numbers the strip shows, counted over the sites the user is signed in
/// to (enabled and with credentials). A site that is off or was never set up
/// contributes nothing.
class HomeTrackingSummary {
  const HomeTrackingSummary({
    required this.connected,
    required this.signInNeeded,
    required this.unlinked,
    required this.failed,
    required this.pending,
    required this.lastSyncAt,
  });

  factory HomeTrackingSummary.of(MediaTrackingHomeSnapshot snapshot) {
    int connected = 0;
    int signInNeeded = 0;
    int failed = 0;
    int pending = 0;
    int lastSyncAt = 0;
    for (final MediaTrackingProviderStatus site in snapshot.sites) {
      if (!site.enabled || !site.configured) continue;
      connected++;
      if (site.unauthorized) signInNeeded++;
      failed += site.failures.length;
      pending += site.pending;
      if (site.lastSyncAt > lastSyncAt) lastSyncAt = site.lastSyncAt;
    }
    return HomeTrackingSummary(
      connected: connected,
      signInNeeded: signInNeeded,
      // Without a site to link to, "not linked" is not something to act on.
      unlinked: connected == 0 ? 0 : snapshot.unlinked.length,
      failed: failed,
      pending: pending,
      lastSyncAt: lastSyncAt,
    );
  }

  static const HomeTrackingSummary none = HomeTrackingSummary(
    connected: 0,
    signInNeeded: 0,
    unlinked: 0,
    failed: 0,
    pending: 0,
    lastSyncAt: 0,
  );

  /// Sites that are on and signed in.
  final int connected;

  /// Of those, sites that rejected the stored sign-in on the last sync.
  final int signInNeeded;

  /// Local items with progress that no site is linked to.
  final int unlinked;

  /// Updates whose last send failed (still queued, will be retried).
  final int failed;

  /// Updates waiting to be sent, failed ones included.
  final int pending;

  /// Latest sync attempt on any connected site (epoch ms; 0 = never).
  final int lastSyncAt;

  /// Something the user has to do: sign in again, link a title, or look at a
  /// send that keeps failing.
  bool get needsAttention => signInNeeded > 0 || unlinked > 0 || failed > 0;
}

/// The strip's state text; the problems first, most blocking first.
String homeTrackingPanelText(HomeTrackingSummary summary, DateTime now) {
  if (summary.connected == 0) return t.home_tracking_panel_not_connected;
  final List<String> problems = <String>[
    if (summary.signInNeeded > 0) t.home_tracking_panel_sign_in,
    if (summary.unlinked > 0)
      t.home_tracking_panel_to_link(n: summary.unlinked),
    if (summary.failed > 0) t.home_tracking_panel_failed(n: summary.failed),
  ];
  if (problems.isNotEmpty) return problems.join(' · ');
  if (summary.pending > 0) {
    return t.media_tracking_pending_count(n: summary.pending);
  }
  if (summary.lastSyncAt <= 0) return t.media_tracking_all_synced;
  final String when = formatActivityRelativeTime(summary.lastSyncAt, now);
  return '${t.media_tracking_all_synced} · $when';
}

/// The short state for a half-width (one column) widget: a count instead of
/// the whole sentence ("3 to handle", "2 pending", "All sent").
String homeTrackingPanelShortText(HomeTrackingSummary summary) {
  if (summary.connected == 0) return t.home_tracking_panel_not_connected;
  final int problems = summary.signInNeeded + summary.unlinked + summary.failed;
  if (problems > 0) return t.home_tracking_panel_attention(n: problems);
  if (summary.pending > 0) {
    return t.media_tracking_pending_count(n: summary.pending);
  }
  return t.media_tracking_all_synced;
}

/// A tracking key a Continue entry can be linked under (a video is linked
/// either as itself or through its collection).
typedef HomeTrackingKey = ({TrackingMediaType type, String key});

/// The tracking state of one Continue entry, or null when there is nothing to
/// say: no site is connected, or the entry was never a candidate for tracking
/// (no link and not in the "not linked" list).
FushiContinueMark? homeTrackingMark({
  required MediaTrackingHomeSnapshot snapshot,
  required Iterable<HomeTrackingKey> keys,
}) {
  final Set<String> connected = <String>{
    for (final MediaTrackingProviderStatus site in snapshot.sites)
      if (site.enabled && site.configured) site.providerId,
  };
  if (connected.isEmpty) return null;
  final Set<String> wanted = <String>{
    for (final HomeTrackingKey k in keys)
      if (k.key.isNotEmpty) ...<String>{
        '${k.type.value}|${k.key}',
        // A row added from a media server is tracked by its server identity.
        for (final ({TrackingMediaType type, String key}) server
            in snapshot.mediaServerCoverage.keysOf(k.type.value, k.key))
          '${server.type.value}|${server.key}',
      },
  };
  if (wanted.isEmpty) return null;

  final Set<int> failedMappings = <int>{
    for (final MediaTrackingProviderStatus site in snapshot.sites)
      if (connected.contains(site.providerId))
        for (final MediaTrackingFailure failure in site.failures)
          failure.mappingId,
  };
  String nameOf(String siteId) => snapshot.siteNames[siteId] ?? siteId;

  final List<String> linkedSites = <String>[];
  String? failedSite;
  for (final MediaTrackingMappingRow mapping in snapshot.mappings) {
    if (!connected.contains(mapping.provider) ||
        !wanted.contains('${mapping.mediaType}|${mapping.mediaKey}')) {
      continue;
    }
    final String name = nameOf(mapping.provider);
    if (failedMappings.contains(mapping.id)) failedSite ??= name;
    if (!linkedSites.contains(name)) linkedSites.add(name);
  }
  if (failedSite != null) {
    return FushiContinueMark(
      icon: FushiIcons.syncProblem,
      label: t.home_tracking_mark_failed(site: failedSite),
      problem: true,
    );
  }
  if (linkedSites.isNotEmpty) {
    return FushiContinueMark(
      icon: FushiIcons.check,
      label: t.home_tracking_mark_linked(site: linkedSites.join(', ')),
    );
  }
  for (final MediaTrackingUnlinkedItem item in snapshot.unlinked) {
    if (wanted.contains('${item.mediaType.value}|${item.mediaKey}')) {
      return FushiContinueMark(
        icon: FushiIcons.linkOff,
        label: t.media_tracking_manual_required,
        problem: true,
      );
    }
  }
  return null;
}

/// The home Tracking widget ([HomeWidgetKind.tracking], 2×1). Whether it is
/// mounted is the dashboard's call (the Media tracking module); once on the
/// home page it stays, and with nothing to do it shrinks to one line ("All
/// sent").
class HomeTrackingPanel extends StatelessWidget {
  const HomeTrackingPanel({
    super.key,
    required this.summary,
    required this.onOpen,
    this.poster = false,
  });

  final HomeTrackingSummary summary;

  /// Opens the Tracking page (widget and button alike).
  final VoidCallback onOpen;

  /// Poster block look instead of the section card.
  final bool poster;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool attention = summary.needsAttention;
    final bool action = attention || summary.connected == 0;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // Laid out from the real cell size: a short cell is one dense line, a
        // taller one gives the status text more lines; a half-width (one
        // column) cell shows a count and an icon button, not the sentence.
        final bool dense = homeWidgetIsDense(c.maxHeight);
        final bool narrow = !homeWidgetIsWide(c.maxWidth);
        final String text = narrow
            ? homeTrackingPanelShortText(summary)
            : homeTrackingPanelText(summary, DateTime.now());
        final String actionLabel = summary.connected == 0
            ? t.home_tracking_panel_connect
            : t.home_tracking_panel_review;
        return HomeWidgetFrame(
          key: const ValueKey<String>('home-tracking-panel'),
          tapKey: const ValueKey<String>('home-tracking-panel-open'),
          title: t.home_tracking_panel_title,
          icon: attention ? FushiIcons.syncProblem : FushiIcons.sync,
          hueKey: HomeWidgetKind.tracking.id,
          poster: poster,
          dense: dense,
          attention: attention,
          onTap: onOpen,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final HomeWidgetStyle style = HomeWidgetStyle.of(context);
              final TextStyle base =
                  Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
              final int lines = dense
                  ? 1
                  : homeWidgetLinesFor(
                      box.maxHeight,
                      MediaQuery.textScalerOf(context).scale(13) * 1.45,
                      max: 6,
                    );
              return AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                switchInCurve: FushiMotion.enter,
                switchOutCurve: FushiMotion.exit,
                layoutBuilder: (Widget? current, List<Widget> previous) =>
                    Stack(
                      alignment: AlignmentDirectional.centerStart,
                      children: <Widget>[...previous, ?current],
                    ),
                child: Row(
                  // Keyed by the text: a change of state cross-fades instead of
                  // jumping.
                  key: ValueKey<String>(text),
                  spacing: 8,
                  children: <Widget>[
                    if (!action && summary.pending == 0)
                      FushiIcon(
                        FushiIcons.check,
                        size: 18,
                        color: style.accent,
                      ),
                    Expanded(
                      child: Text(
                        text,
                        key: const ValueKey<String>('home-tracking-panel-text'),
                        maxLines: lines,
                        overflow: TextOverflow.ellipsis,
                        style: base.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: attention && !poster
                              ? scheme.error
                              : style.foreground,
                        ),
                      ),
                    ),
                    if (action && narrow)
                      FushiIconButton(
                        key: const ValueKey<String>(
                          'home-tracking-panel-action',
                        ),
                        icon: FushiIcons.forward,
                        tooltip: actionLabel,
                        size: 20,
                        // 28 高：窄网格一行高的格子里内容区只有 ~30。
                        padding: const EdgeInsets.all(4),
                        enabledColor: style.accent,
                        onTap: onOpen,
                      )
                    else if (action)
                      FushiFilledButton.tonal(
                        key: const ValueKey<String>(
                          'home-tracking-panel-action',
                        ),
                        size: FushiButtonSize.xs,
                        onPressed: onOpen,
                        child: Text(
                          actionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
