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
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show formatActivityRelativeTime;
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, FushiCoverBlockSize, fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;
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
    this.linked = 0,
  });

  factory HomeTrackingSummary.of(MediaTrackingHomeSnapshot snapshot) {
    int connected = 0;
    int signInNeeded = 0;
    int failed = 0;
    int pending = 0;
    int lastSyncAt = 0;
    final Set<String> connectedIds = <String>{};
    for (final MediaTrackingProviderStatus site in snapshot.sites) {
      if (!site.enabled || !site.configured) continue;
      connected++;
      connectedIds.add(site.providerId);
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
      linked: <String>{
        for (final MediaTrackingMappingRow m in snapshot.mappings)
          if (connectedIds.contains(m.provider)) '${m.mediaType}|${m.mediaKey}',
      }.length,
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

  /// Local titles linked on at least one connected site (the "N synced" the
  /// collage block shows when nothing needs the user).
  final int linked;

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
              // Apple：要处理的状态只把小标题染成 destructive（Health 摘要卡口径），
              // 正文仍是 label；行尾是 tertiaryLabel 的 chevron，不是强调色箭头。
              final FushiAppleColors? apple = !poster && isGlassDesign(context)
                  ? appleColorsOf(context)
                  : null;
              final TextStyle textStyle = context.fushiType.bodyMedium.copyWith(
                fontWeight: FontWeight.w600,
                color: apple != null
                    ? apple.label
                    : attention && !poster
                    ? scheme.error
                    : style.foreground,
              );
              final int lines = dense
                  ? 1
                  : homeWidgetLinesFor(
                      box.maxHeight,
                      homeWidgetLineHeight(context, textStyle),
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
                        style: textStyle,
                      ),
                    ),
                    if (action && narrow)
                      FushiIconButton(
                        key: const ValueKey<String>(
                          'home-tracking-panel-action',
                        ),
                        icon: apple != null
                            ? CupertinoIcons.chevron_forward
                            : FushiIcons.forward,
                        tooltip: actionLabel,
                        size: apple != null
                            ? FushiAppleMetrics.of(context).chevronSize
                            : 20,
                        // 28 高：窄网格一行高的格子里内容区只有 ~30。
                        padding: const EdgeInsets.all(4),
                        enabledColor: apple?.tertiaryLabel ?? style.accent,
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

/// Hue of the collage Tracking block: red-ish while something needs the user,
/// green-ish when everything is fine (design H6).
double homeTrackingPosterHue(HomeTrackingSummary summary) =>
    summary.needsAttention || summary.connected == 0 ? 350 : 140;

/// The big figure of the collage block: the titles waiting to be linked while
/// there are any, otherwise the linked titles.
int homeTrackingPosterFigure(HomeTrackingSummary summary) =>
    summary.unlinked > 0 ? summary.unlinked : summary.linked;

/// The chips under the figure of the collage block: the problems other than
/// "to link" (that one is the figure), or, when nothing needs the user, what
/// is still queued and when the last sync ran.
List<String> homeTrackingPosterChips(
  HomeTrackingSummary summary,
  DateTime now,
) {
  if (summary.connected == 0) return const <String>[];
  if (summary.needsAttention) {
    return <String>[
      if (summary.signInNeeded > 0) t.home_tracking_panel_sign_in,
      if (summary.failed > 0) t.home_tracking_panel_failed(n: summary.failed),
    ];
  }
  return <String>[
    if (summary.pending > 0) t.media_tracking_pending_count(n: summary.pending),
    if (summary.lastSyncAt > 0)
      formatActivityRelativeTime(summary.lastSyncAt, now),
  ];
}

/// The home Tracking block in the collage layout (design H6): one whole block
/// coloured by state. While titles wait to be linked the figure is that count
/// (also the watermark), the other problems are chips, the covers of the
/// waiting titles fan out on the end side and "Fix ›" sits bottom-end. When
/// nothing needs the user it says how many titles are synced and when the
/// last sync ran. Tapping anywhere opens the Tracking page (same as [onOpen]).
class HomeTrackingPoster extends StatelessWidget {
  const HomeTrackingPoster({
    super.key,
    required this.summary,
    required this.covers,
    required this.onOpen,
    required this.height,
  });

  final HomeTrackingSummary summary;

  /// Covers of the titles waiting to be linked (at most three are drawn).
  final List<Widget> covers;
  final VoidCallback onOpen;
  final double height;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors = FushiCoverBlockColors.fromHue(
      theme,
      homeTrackingPosterHue(summary),
    );
    final TextStyle base = theme.textTheme.bodyMedium ?? const TextStyle();
    final Color muted = colors.onContainer.withValues(alpha: 0.8);
    final bool attention = summary.needsAttention;
    final bool action = attention || summary.connected == 0;
    final int figure = homeTrackingPosterFigure(summary);
    final String counted = summary.unlinked > 0
        ? t.home_tracking_panel_to_link(n: figure)
        : t.home_tracking_panel_synced(n: figure);
    // The counted phrase split around the figure, so the number is big and
    // the words stay small on whichever side the language puts them
    // ("12 to link", "已同步 12 项", "Карт: 12").
    final int at = counted.indexOf('$figure');
    final String before = at < 0 ? '' : counted.substring(0, at).trim();
    final String after = at < 0
        ? counted
        : counted.substring(at + '$figure'.length).trim();
    final DateTime now = DateTime.now();
    final List<String> chips = homeTrackingPosterChips(summary, now);
    final List<Widget> shown = covers.take(3).toList();
    final String text = homeTrackingPanelText(summary, now);

    final Widget figureText = summary.connected == 0
        ? Text(
            t.home_tracking_panel_not_connected,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: FushiPosterText.name.on(base).copyWith(color: colors.accent),
          )
        : Text.rich(
            TextSpan(
              children: <InlineSpan>[
                if (before.isNotEmpty)
                  TextSpan(
                    text: '$before ',
                    style: FushiPosterText.meta.on(base).copyWith(color: muted),
                  ),
                TextSpan(
                  text: '$figure',
                  style: FushiPosterText.headline
                      .on(base)
                      .copyWith(color: colors.accent),
                ),
                if (after.isNotEmpty)
                  TextSpan(
                    text: ' $after',
                    style: FushiPosterText.meta.on(base).copyWith(color: muted),
                  ),
              ],
            ),
            key: const ValueKey<String>('home-tracking-panel-figure'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Row(
          spacing: 6,
          children: <Widget>[
            FushiIcon(
              attention ? FushiIcons.syncProblem : FushiIcons.sync,
              size: 14,
              color: muted,
            ),
            Flexible(
              child: Text(
                t.home_tracking_panel_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FushiPosterText.meta.on(base).copyWith(color: muted),
              ),
            ),
          ],
        ),
        figureText,
        if (chips.isNotEmpty)
          SizedBox(
            height: 26,
            child: ClipRect(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String chip in chips)
                    FushiPosterChip(colors: colors, label: chip),
                ],
              ),
            ),
          )
        else
          const SizedBox.shrink(),
      ],
    );

    final Widget end = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        if (shown.isNotEmpty)
          _HomeTrackingCoverFan(covers: shown)
        else
          const SizedBox.shrink(),
        if (action)
          FushiPosterChip(
            key: const ValueKey<String>('home-tracking-panel-action'),
            colors: colors,
            solid: true,
            label:
                '${summary.connected == 0 ? t.home_tracking_panel_connect : t.home_tracking_panel_resolve} ›',
          )
        else
          const SizedBox.shrink(),
      ],
    );

    final Widget poster = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => FushiPosterBlock(
        // The figure doubles as the watermark, boxed into the end half.
        watermark: summary.unlinked > 0 ? '$figure' : '',
        watermarkEdge: FushiPosterWatermarkEdge.bottom,
        watermarkStart: box.maxWidth.isFinite ? box.maxWidth * 0.5 : 0,
        watermarkFontSize: 90,
        colors: colors,
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          height: height - 32,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: <Widget>[
              Expanded(child: info),
              end,
            ],
          ),
        ),
      ),
    );

    return Semantics(
      key: const ValueKey<String>('home-tracking-panel'),
      container: true,
      label: '${t.home_tracking_panel_title} · $text',
      child: SizedBox(
        height: height,
        child: shelfCoverCard(
          key: const ValueKey<String>('home-tracking-panel-open'),
          shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
          onTap: onOpen,
          child: poster,
        ),
      ),
    );
  }
}

/// Up to three covers fanned out (the outer ones tilted), the collage "stack".
class _HomeTrackingCoverFan extends StatelessWidget {
  const _HomeTrackingCoverFan({required this.covers});

  final List<Widget> covers;

  static const double _width = 30;
  static const double _height = 44;
  static const double _overlap = 14;

  /// Tilt of cover [i] of [n]: the outer two lean out, the middle stays up.
  static double _angle(int i, int n) {
    if (n == 1) return 0;
    if (n == 2) return i == 0 ? -0.14 : 0.14;
    return (i - 1) * 0.14;
  }

  @override
  Widget build(BuildContext context) {
    final int n = covers.length;
    return ExcludeSemantics(
      child: SizedBox(
        width: _width + (n - 1) * (_width - _overlap) + 8,
        height: _height + 6,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            for (int i = 0; i < n; i++)
              PositionedDirectional(
                start: 4 + i * (_width - _overlap),
                top: 3,
                child: Transform.rotate(
                  angle: _angle(i, n),
                  child: ClipRRect(
                    borderRadius: FushiBorderRadius.chip,
                    child: SizedBox(
                      width: _width,
                      height: _height,
                      child: covers[i],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
