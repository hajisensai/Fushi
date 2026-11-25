import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_labels.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_playing_bar.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_actions.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Main-screen link that starts the built-in review (`WidgetSrsLink`).
const String kCompanionReviewLink = 'fushi://widget/srs';

/// Builds the Now tab's panel for one media context (S3 registers the
/// reader, video, manga, audiobook, music, review and game stream panels).
typedef CompanionContextPanelBuilder =
    Widget Function(BuildContext context, CompanionPanelSession session);

/// The Now tab: the top context's panel while media is open there, the daily
/// summary otherwise. A new context swaps the content in place (the tab and
/// its back history stay).
class CompanionNowTab extends ConsumerWidget {
  const CompanionNowTab({
    this.contextPanels =
        const <CompanionContextKind, CompanionContextPanelBuilder>{},
    super.key,
  });

  final Map<CompanionContextKind, CompanionContextPanelBuilder> contextPanels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CompanionPanelSession session = ref.watch(
      companionPanelSessionProvider,
    );
    final CompanionContext top = session.context;
    final CompanionContextPanelBuilder? panel = top.kind.isMedia
        ? contextPanels[top.kind]
        : null;
    final Widget child;
    final Key key;
    if (top.kind.isMedia) {
      key = ValueKey<CompanionContextKind>(top.kind);
      child =
          panel?.call(context, session) ??
          CompanionContextCard(companionContext: top);
    } else {
      key = const ValueKey<String>('summary');
      child = CompanionDailySummaryView(session: session);
    }
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // "Back to <previous>" after an open from the Library tab.
            const CompanionBackToPreviousBar(),
            Expanded(
              child: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                child: KeyedSubtree(key: key, child: child),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A media context with no panel of its own yet: what is open on top.
class CompanionContextCard extends StatelessWidget {
  const CompanionContextCard({required this.companionContext, super.key});

  final CompanionContext companionContext;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? title = companionContext.title;
    return FushiEntranceScope(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: Text(
              t.second_screen_now_on_top,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          FushiStaggeredEntrance(
            index: 1,
            child: FushiCard(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  FushiIcon(
                    companionContextIcon(companionContext.kind),
                    size: 32,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          companionContextLabel(companionContext),
                          style: theme.textTheme.titleMedium,
                        ),
                        if (title != null && title.isNotEmpty)
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Today's study time, due reviews and one item to continue (all from the
/// main engine's data, see `collectCompanionDailySummary`).
class CompanionDailySummaryView extends StatelessWidget {
  const CompanionDailySummaryView({required this.session, super.key});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget body = switch (session.summaryStatus) {
      CompanionSummaryStatus.loading => const Center(
        key: ValueKey<String>('companion-summary-loading'),
        child: FushiCircularProgressIndicator(),
      ),
      CompanionSummaryStatus.failed => Center(
        key: const ValueKey<String>('companion-summary-error'),
        child: FushiPlaceholderMessage(
          icon: FushiIcons.error,
          tone: FushiPlaceholderTone.error,
          message: t.second_screen_summary_error,
          action: FushiFilledButton.tonal(
            onPressed: session.retrySummary,
            child: Text(t.retry),
          ),
        ),
      ),
      CompanionSummaryStatus.ready => _SummaryContent(
        key: const ValueKey<String>('companion-summary-ready'),
        summary: session.summary!,
        session: session,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const CompanionNowPlayingBar(),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(
                child: Text(
                  t.second_screen_summary_title,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Flexible(
                child: Text(
                  companionContextLabel(session.context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            child: body,
          ),
        ),
      ],
    );
  }
}

class _SummaryContent extends StatelessWidget {
  const _SummaryContent({
    required this.summary,
    required this.session,
    super.key,
  });

  final CompanionDailySummary summary;
  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) {
    final bool anyTime =
        summary.readingMs > 0 ||
        summary.watchingMs > 0 ||
        summary.listeningMs > 0 ||
        summary.gamesMs > 0;
    final CompanionSrsDue? srs = summary.srsDue;
    final CompanionContinueItem? next = summary.continueItem;
    if (!anyTime && srs == null && next == null) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.calendar,
          message: t.second_screen_summary_empty,
        ),
      );
    }
    final List<Widget> sections = <Widget>[
      if (anyTime) _TimeTiles(summary: summary) else const _NoTimeYet(),
      if (srs != null)
        _ReviewCard(
          due: srs,
          onReview: () => session.openOnMain(kCompanionReviewLink),
        ),
      if (next != null)
        _ContinueSection(
          item: next,
          onContinue: () => session.openOnMain(next.link),
        ),
    ];
    return FushiEntranceScope(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: <Widget>[
          for (int i = 0; i < sections.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: FushiStaggeredEntrance(index: i, child: sections[i]),
            ),
        ],
      ),
    );
  }
}

class _NoTimeYet extends StatelessWidget {
  const _NoTimeYet();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Text(
      t.second_screen_summary_empty,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _TimeTiles extends StatelessWidget {
  const _TimeTiles({required this.summary});

  final CompanionDailySummary summary;

  @override
  Widget build(BuildContext context) {
    final List<(int, String)> tiles = <(int, String)>[
      (summary.readingMs, t.widget_label_reading),
      (summary.watchingMs, t.widget_label_watching),
      (summary.listeningMs, t.widget_label_listening),
      if (summary.gamesMs > 0) (summary.gamesMs, t.widget_label_games),
    ];
    return Row(
      children: <Widget>[
        for (int i = 0; i < tiles.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _TimeTile(ms: tiles[i].$1, label: tiles[i].$2),
          ),
        ],
      ],
    );
  }
}

class _TimeTile extends StatelessWidget {
  const _TimeTile({required this.ms, required this.label});

  final int ms;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            formatStatTime(ms),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge,
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.due, required this.onReview});

  final CompanionSrsDue due;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool anyDue = due.total > 0;
    return FushiCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  anyDue
                      ? t.second_screen_summary_cards_due(n: due.total)
                      : t.widget_label_all_caught_up,
                  style: theme.textTheme.titleMedium,
                ),
                if (anyDue)
                  Text(
                    t.second_screen_summary_due_breakdown(
                      newCount: due.newCount,
                      learnCount: due.learnCount,
                      reviewCount: due.reviewCount,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (anyDue) ...<Widget>[
            const SizedBox(width: 12),
            FushiPressScale(
              child: FushiFilledButton(
                onPressed: onReview,
                child: Text(t.second_screen_summary_review_on_top),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ContinueSection extends StatelessWidget {
  const _ContinueSection({required this.item, required this.onContinue});

  final CompanionContinueItem item;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final double? progress = item.progress?.clamp(0.0, 1.0);
    final String continueLabel = t.second_screen_continue_on_top(
      title: item.title,
    );
    final String meta = <String>[
      companionContinueKindLabel(item.kind),
      if (progress != null && progress > 0) '${(progress * 100).round()}%',
      if (item.subtitle.isNotEmpty) item.subtitle,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.second_screen_summary_continue,
          style: theme.textTheme.labelLarge?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          button: true,
          label: continueLabel,
          excludeSemantics: true,
          child: FushiCard(
            onTap: onContinue,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                _Cover(item: item),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (progress != null) ...<Widget>[
                        const SizedBox(height: 6),
                        FushiLinearProgressIndicator(value: progress),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FushiIconButton(
                  icon: FushiIcons.play,
                  tooltip: continueLabel,
                  onTap: onContinue,
                  padTouchTarget: true,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.item});

  final CompanionContinueItem item;

  static const double _width = 48;
  static const double _height = 68;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget fallback = ColoredBox(
      color: colors.secondaryContainer,
      child: Center(
        child: FushiIcon(
          companionContinueKindIcon(item.kind),
          color: colors.onSecondaryContainer,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: FushiM3eShape.smallRadius,
      child: SizedBox(
        width: _width,
        height: _height,
        child: item.coverPath.isEmpty
            ? fallback
            : Image.file(
                File(item.coverPath),
                fit: BoxFit.cover,
                cacheWidth: (_width * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        fallback,
              ),
      ),
    );
  }
}
