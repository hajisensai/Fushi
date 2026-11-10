import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart'
    show SrsRatingTone, srsRatingColors;
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/srs_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_tab.dart'
    show kCompanionReviewLink;
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
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

/// The companion's Now panel while the top screen is in SRS review
/// (`CompanionContextKind.srs`): deck + Undo, the remaining counts, and the
/// next step for the card on top (Show answer, or the four answer buttons
/// with the intervals the top screen shows). The card itself stays on top.
///
/// Without a snapshot (the home shell's review tab is on top, no review page
/// open) it shows today's due counts from the daily summary and "Review on
/// top", like the summary's review card.
class SrsCompanionPanel extends StatelessWidget {
  const SrsCompanionPanel({required this.session, super.key});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (BuildContext context, Widget? _) {
      final Map<String, Object?>? snapshot = session.snapshot;
      if (snapshot == null) return _SrsNotReviewing(session: session);
      return _SrsReviewing(session: session, snapshot: snapshot);
    },
  );
}

class _SrsReviewing extends StatelessWidget {
  const _SrsReviewing({required this.session, required this.snapshot});

  final CompanionPanelSession session;
  final Map<String, Object?> snapshot;

  void _send(String action, [Map<String, Object?> args = const {}]) =>
      unawaited(session.command(action, args));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<String, Object?> s = snapshot;
    final String phase = s.str(
      SrsCompanionKeys.phase,
      SrsCompanionPhases.loading,
    );
    final bool busy = s.flag(SrsCompanionKeys.busy);
    final bool canUndo = s.flag(SrsCompanionKeys.canUndo);
    final String deck = s.str(SrsCompanionKeys.deck);
    final TextStyle? hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final Widget step = switch (phase) {
      SrsCompanionPhases.question => Column(
        key: const ValueKey<String>('srs-companion-question'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.second_screen_srs_question_hint, style: hintStyle),
          const SizedBox(height: 12),
          Expanded(
            child: Center(
              child: _ShowAnswerButton(
                onPressed: busy
                    ? null
                    : () => _send(SrsCompanionActions.showAnswer),
              ),
            ),
          ),
        ],
      ),
      SrsCompanionPhases.answer => Column(
        key: const ValueKey<String>('srs-companion-answer'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.second_screen_srs_answer_hint, style: hintStyle),
          const SizedBox(height: 12),
          Expanded(
            child: _AnswerGrid(
              intervals: s.strings(SrsCompanionKeys.intervals),
              twoButtons: s.flag(SrsCompanionKeys.twoButtons),
              enabled: !busy,
              onAnswer: (int rating) => _send(
                SrsCompanionActions.answer,
                <String, Object?>{SrsCompanionKeys.rating: rating},
              ),
            ),
          ),
        ],
      ),
      SrsCompanionPhases.done => Center(
        key: const ValueKey<String>('srs-companion-done'),
        child: FushiPlaceholderMessage(
          icon: FushiIcons.ankiCard,
          message: t.srs_review_done,
        ),
      ),
      SrsCompanionPhases.unavailable => Center(
        key: const ValueKey<String>('srs-companion-unavailable'),
        child: FushiPlaceholderMessage(
          icon: FushiIcons.ankiCard,
          message: t.second_screen_now_on_top,
        ),
      ),
      _ => const Center(
        key: ValueKey<String>('srs-companion-loading'),
        child: FushiCircularProgressIndicator(),
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  deck.isEmpty
                      ? t.second_screen_context_srs
                      : t.second_screen_srs_reviewing(deck: deck),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FushiPressScale(
                enabled: canUndo && !busy,
                child: FushiTooltip(
                  message: t.undo,
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('srs-companion-undo'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: canUndo && !busy
                        ? () => _send(SrsCompanionActions.undo)
                        : null,
                    icon: const FushiIcon(FushiIcons.undo, size: 18),
                    label: Text(t.undo),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              4,
              16,
              12 + MediaQuery.paddingOf(context).bottom,
            ),
            child: FushiEntranceScope(
              replayKey: phase,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  FushiStaggeredEntrance(
                    index: 0,
                    child: _CountsRow(
                      newCount: s.integer(SrsCompanionKeys.newCount),
                      learnCount: s.integer(SrsCompanionKeys.learnCount),
                      reviewCount: s.integer(SrsCompanionKeys.reviewCount),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: FushiStaggeredEntrance(
                      index: 1,
                      child: AnimatedSwitcher(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        child: step,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CountsRow extends StatelessWidget {
  const _CountsRow({
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
  });

  final int newCount;
  final int learnCount;
  final int reviewCount;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: CompanionStatTile(value: '$newCount', label: t.srs_count_new),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: CompanionStatTile(
          value: '$learnCount',
          label: t.srs_count_learn,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: CompanionStatTile(
          value: '$reviewCount',
          label: t.srs_count_review,
        ),
      ),
    ],
  );
}

class _ShowAnswerButton extends StatelessWidget {
  const _ShowAnswerButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FushiPressScale(
    enabled: onPressed != null,
    child: SizedBox(
      width: double.infinity,
      child: FushiFilledButton.icon(
        key: const ValueKey<String>('srs-companion-show-answer'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(72)),
        onPressed: onPressed,
        icon: const FushiIcon(FushiIcons.visibility),
        label: Text(t.srs_review_show_answer),
      ),
    ),
  );
}

/// Again / Hard / Good / Easy (or Again / Good when the page hides Hard and
/// Easy), two per row, each with the interval label the top screen shows.
class _AnswerGrid extends StatelessWidget {
  const _AnswerGrid({
    required this.intervals,
    required this.twoButtons,
    required this.enabled,
    required this.onAnswer,
  });

  final List<String> intervals;
  final bool twoButtons;
  final bool enabled;
  final ValueChanged<int> onAnswer;

  String _intervalOf(int rating) =>
      rating - 1 < intervals.length ? intervals[rating - 1] : '';

  @override
  Widget build(BuildContext context) {
    final List<(int, String, SrsRatingTone)> ratings =
        <(int, String, SrsRatingTone)>[
          (1, t.srs_rating_again, SrsRatingTone.again),
          if (!twoButtons) (2, t.srs_rating_hard, SrsRatingTone.hard),
          (3, t.srs_rating_good, SrsRatingTone.good),
          if (!twoButtons) (4, t.srs_rating_easy, SrsRatingTone.easy),
        ];
    Widget cell((int, String, SrsRatingTone) r) => _AnswerButton(
      rating: r.$1,
      label: r.$2,
      tone: r.$3,
      interval: _intervalOf(r.$1),
      onPressed: enabled ? () => onAnswer(r.$1) : null,
    );
    final List<Widget> rows = <Widget>[
      for (int i = 0; i < ratings.length; i += 2)
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: cell(ratings[i])),
              const SizedBox(width: 10),
              Expanded(child: cell(ratings[i + 1])),
            ],
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 10),
          rows[i],
        ],
      ],
    );
  }
}

class _AnswerButton extends StatelessWidget {
  const _AnswerButton({
    required this.rating,
    required this.label,
    required this.tone,
    required this.interval,
    required this.onPressed,
  });

  final int rating;
  final String label;
  final SrsRatingTone tone;
  final String interval;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ({Color background, Color foreground}) c = srsRatingColors(
      tone,
      theme.colorScheme,
      apple: isGlassDesign(context),
    );
    final String semantics = interval.isEmpty ? label : '$label, $interval';
    return FushiPressScale(
      enabled: onPressed != null,
      child: FushiTooltip(
        message: semantics,
        child: Semantics(
          button: true,
          enabled: onPressed != null,
          label: semantics,
          excludeSemantics: true,
          child: FushiFilledButton(
            key: ValueKey<String>('srs-companion-answer-$rating'),
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: c.background,
              foregroundColor: c.foreground,
              minimumSize: const Size(48, 56),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              shape: const RoundedRectangleBorder(
                borderRadius: FushiM3eShape.cardRadius,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: onPressed == null ? null : c.foreground,
                  ),
                ),
                if (interval.isNotEmpty)
                  Text(
                    interval,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: onPressed == null
                          ? null
                          : c.foreground.withValues(alpha: 0.85),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The review tab is on top but no review is open: today's due counts (from
/// the daily summary, when it has them) and "Review on top".
class _SrsNotReviewing extends StatelessWidget {
  const _SrsNotReviewing({required this.session});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CompanionSrsDue? due = session.summary?.srsDue;
    final bool caughtUp = due != null && due.total == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CompanionPanelHeader(label: t.second_screen_context_srs),
        Expanded(
          child: FushiEntranceScope(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 0,
                  child: FushiCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (due != null) ...<Widget>[
                          Text(
                            caughtUp
                                ? t.widget_label_all_caught_up
                                : t.second_screen_summary_cards_due(
                                    n: due.total,
                                  ),
                            style: theme.textTheme.titleMedium,
                          ),
                          if (!caughtUp)
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
                          const SizedBox(height: 12),
                        ],
                        if (!caughtUp)
                          FushiPressScale(
                            child: FushiFilledButton(
                              key: const ValueKey<String>(
                                'srs-companion-review-on-top',
                              ),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: () => unawaited(
                                session.openOnMain(kCompanionReviewLink),
                              ),
                              child: Text(
                                t.second_screen_summary_review_on_top,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
