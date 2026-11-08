import 'dart:io';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:material_ui/material_ui.dart';

/// Building blocks shared by the companion's module panels (Now tab), sized
/// for a ~470 x 540 dp screen that may only be driven by a controller: every
/// control is a real focusable button with a >= 48 dp hit area, a tooltip and
/// a Semantics label.

/// Top line of a module panel: what is open ("Now reading · EPUB") and a
/// short position on the right ("Chapter 12 / 110").
class CompanionPanelHeader extends StatelessWidget {
  const CompanionPanelHeader({required this.label, this.trailing, super.key});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final String? end = trailing;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (end != null && end.isNotEmpty) ...<Widget>[
            const SizedBox(width: 8),
            Text(end, maxLines: 1, style: style),
          ],
        ],
      ),
    );
  }
}

/// Cover (file path, or an icon tile when there is none) + title + subtitle.
class CompanionTitleBlock extends StatelessWidget {
  const CompanionTitleBlock({
    required this.title,
    required this.fallbackIcon,
    this.subtitle,
    this.coverPath,
    super.key,
  });

  final String title;
  final String? subtitle;
  final String? coverPath;
  final IconData fallbackIcon;

  static const double coverWidth = 48;
  static const double coverHeight = 68;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String? sub = subtitle;
    final String? cover = coverPath;
    final Widget fallback = ColoredBox(
      color: colors.secondaryContainer,
      child: Center(
        child: FushiIcon(fallbackIcon, color: colors.onSecondaryContainer),
      ),
    );
    return Row(
      children: <Widget>[
        ClipRRect(
          borderRadius: FushiM3eShape.smallRadius,
          child: SizedBox(
            width: coverWidth,
            height: coverHeight,
            child: cover == null || cover.isEmpty
                ? fallback
                : Image.file(
                    File(cover),
                    fit: BoxFit.cover,
                    cacheWidth:
                        (coverWidth * MediaQuery.devicePixelRatioOf(context))
                            .round(),
                    errorBuilder:
                        (BuildContext context, Object error, StackTrace? s) =>
                            fallback,
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              if (sub != null && sub.isNotEmpty)
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A labelled progress bar ("Progress ........ 34%"). [fraction] null shows
/// an indeterminate-free empty bar with "--".
class CompanionProgressRow extends StatelessWidget {
  const CompanionProgressRow({
    required this.label,
    required this.fraction,
    this.valueText,
    super.key,
  });

  final String label;
  final double? fraction;

  /// Defaults to the percentage of [fraction].
  final String? valueText;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? f = fraction?.clamp(0.0, 1.0);
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, style: style)),
            Text(
              valueText ?? (f == null ? '--' : '${(f * 100).round()}%'),
              style: style,
            ),
          ],
        ),
        const SizedBox(height: 4),
        FushiLinearProgressIndicator(value: f ?? 0),
      ],
    );
  }
}

/// A big square-ish control button (prev / next / bookmark / contents ...):
/// icon only, label in the tooltip and Semantics, 52 dp tall.
class CompanionActionButton extends StatelessWidget {
  const CompanionActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Filled (the main action) instead of tonal.
  final bool primary;

  /// A toggle that is on (shown filled).
  final bool selected;

  static const double height = 52;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = FushiIcon(icon, size: 24);
    final ButtonStyle style = FilledButton.styleFrom(
      minimumSize: const Size(48, height),
      padding: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: FushiM3eShape.smallRadius,
      ),
    );
    final Widget button = primary || selected
        ? FushiFilledButton(onPressed: onPressed, style: style, child: glyph)
        : FushiFilledButton.tonal(
            onPressed: onPressed,
            style: style,
            child: glyph,
          );
    return FushiPressScale(
      child: FushiTooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          toggled: selected ? true : null,
          label: tooltip,
          excludeSemantics: true,
          child: SizedBox(height: height, child: button),
        ),
      ),
    );
  }
}

/// A row of [CompanionActionButton]s sharing the width equally.
class CompanionActionRow extends StatelessWidget {
  const CompanionActionRow({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      for (int i = 0; i < children.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(width: 8),
        Expanded(child: children[i]),
      ],
    ],
  );
}

/// A small number tile ("38 min / read today").
class CompanionStatTile extends StatelessWidget {
  const CompanionStatTile({
    required this.value,
    required this.label,
    super.key,
  });

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
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

/// Small section caption ("Bookmarks", "Subtitles · tap to jump ...").
class CompanionSectionLabel extends StatelessWidget {
  const CompanionSectionLabel(this.text, {this.trailing, super.key});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget? end = trailing;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ?end,
      ],
    );
  }
}

/// A tappable line (bookmark, transcript / subtitle line, OCR line): >= 48 dp
/// tall, optional trailing text, [selected] highlights the current one.
class CompanionLineTile extends StatelessWidget {
  const CompanionLineTile({
    required this.text,
    required this.onTap,
    this.onLongPress,
    this.leading,
    this.trailing,
    this.selected = false,
    this.maxLines = 2,
    this.semanticsHint,
    super.key,
  });

  final String text;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? leading;
  final String? trailing;
  final bool selected;
  final int maxLines;
  final String? semanticsHint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String? lead = leading;
    final String? end = trailing;
    final TextStyle? meta = theme.textTheme.labelSmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Semantics(
      button: onTap != null,
      selected: selected,
      hint: semanticsHint,
      child: FushiPressScale(
        child: Material(
          color: selected
              ? colors.secondaryContainer
              : colors.containerOf(FushiTone.neutral),
          shape: const RoundedRectangleBorder(
            borderRadius: FushiM3eShape.smallRadius,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: <Widget>[
                    if (lead != null) ...<Widget>[
                      Text(lead, style: meta),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        text,
                        maxLines: maxLines,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: selected
                              ? colors.onSecondaryContainer
                              : colors.onSurface,
                        ),
                      ),
                    ),
                    if (end != null) ...<Widget>[
                      const SizedBox(width: 10),
                      Text(end, style: meta),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "★ 8.4" / "★ 8.4 · 1234 votes" for a cached rating (0..10) and its vote
/// count (left out when unknown).
String companionRatingLabel(double rating, {int? votes}) {
  final String stars = '★ ${rating.toStringAsFixed(1)}';
  return votes == null || votes <= 0
      ? stars
      : '$stars · ${t.second_screen_video_votes(n: votes)}';
}

/// Display-only tag chips (rating, genres) in a wrapping row.
class CompanionTagChips extends StatelessWidget {
  const CompanionTagChips({required this.chips, super.key});

  final List<String> chips;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: <Widget>[
      for (final String chip in chips)
        FushiTagChip(label: chip, tone: FushiTagChipTone.surface),
    ],
  );
}

/// One "label · value" line of a [CompanionInfoCard].
@immutable
class CompanionInfoFact {
  const CompanionInfoFact({required this.label, required this.value});

  final String label;
  final String value;
}

/// Info card of a Now panel, built from cached data only: a caption, tag
/// chips (rating, genres), label / value facts and a description collapsed
/// to [collapsedLines] with "More" / "Less". Pass only what is known; the
/// card hides empty parts and [isEmpty] tells the caller to leave it out.
class CompanionInfoCard extends StatelessWidget {
  const CompanionInfoCard({
    this.title,
    this.chips = const <String>[],
    this.facts = const <CompanionInfoFact>[],
    this.description,
    this.collapsedLines = 3,
    super.key,
  });

  final String? title;
  final List<String> chips;
  final List<CompanionInfoFact> facts;
  final String? description;
  final int collapsedLines;

  bool get isEmpty =>
      chips.isEmpty &&
      facts.isEmpty &&
      (description == null || description!.trim().isEmpty);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? meta = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final String? caption = title;
    final String? about = description?.trim();
    final List<Widget> parts = <Widget>[
      if (caption != null) CompanionSectionLabel(caption),
      if (chips.isNotEmpty) CompanionTagChips(chips: chips),
      for (final CompanionInfoFact fact in facts)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 112,
              child: Text(
                fact.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: meta,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fact.value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      if (about != null && about.isNotEmpty)
        CompanionExpandableText(text: about, collapsedLines: collapsedLines),
    ];
    return FushiCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < parts.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 8),
            parts[i],
          ],
        ],
      ),
    );
  }
}

/// A text collapsed to [collapsedLines]; a focusable "More" / "Less" button
/// (>= 48 dp) appears only when it is longer than that.
class CompanionExpandableText extends StatefulWidget {
  const CompanionExpandableText({
    required this.text,
    this.collapsedLines = 3,
    super.key,
  });

  final String text;
  final int collapsedLines;

  @override
  State<CompanionExpandableText> createState() =>
      _CompanionExpandableTextState();
}

class _CompanionExpandableTextState extends State<CompanionExpandableText> {
  bool _expanded = false;

  @override
  void didUpdateWidget(CompanionExpandableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool long = painter.didExceedMaxLines;
        painter.dispose();
        final bool clipped = long && !_expanded;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              alignment: Alignment.topLeft,
              child: Text(
                widget.text,
                maxLines: clipped ? widget.collapsedLines : null,
                overflow: clipped ? TextOverflow.ellipsis : null,
                style: style,
              ),
            ),
            if (long)
              FushiPressScale(
                child: FushiTextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded
                        ? t.second_screen_info_less
                        : t.second_screen_info_more,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// `m:ss` / `h:mm:ss` for a position in milliseconds.
String companionFormatClock(int ms) {
  final int total = (ms < 0 ? 0 : ms) ~/ 1000;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final String s = (total % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
  return '$m:$s';
}
