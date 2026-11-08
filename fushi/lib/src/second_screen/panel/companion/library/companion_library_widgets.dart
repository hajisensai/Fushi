import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_feed.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Building blocks of Browse mode (Library tab, S5), sized for the ~470 x
/// 540 dp bottom screen and drivable by controller (every card / button is a
/// focusable control with a >= 48 dp hit area).

/// Height of a cover card (cover + title + one meta line + progress).
const double kCompanionLibraryCardHeight = 176;

/// Width of a card in a horizontal Home row.
const double kCompanionLibraryCardWidth = 102;

/// The fallback icon of an item without a cover.
IconData companionLibraryKindIcon(CompanionLibraryItemKind kind) =>
    switch (kind) {
      CompanionLibraryItemKind.book => FushiIcons.books,
      CompanionLibraryItemKind.manga => FushiIcons.manga,
      CompanionLibraryItemKind.video => FushiIcons.video,
      CompanionLibraryItemKind.audiobook => FushiIcons.audiobook,
      CompanionLibraryItemKind.musicAlbum ||
      CompanionLibraryItemKind.musicTrack => FushiIcons.music,
      CompanionLibraryItemKind.musicArtist => FushiIcons.person,
      CompanionLibraryItemKind.musicPlaylist => FushiIcons.playlist,
      CompanionLibraryItemKind.collection => FushiIcons.collections,
      CompanionLibraryItemKind.server => FushiIcons.server,
      CompanionLibraryItemKind.serverLibrary => FushiIcons.folder,
      CompanionLibraryItemKind.serverFolder => FushiIcons.folderOpen,
      CompanionLibraryItemKind.serverItem => FushiIcons.playCircle,
      CompanionLibraryItemKind.mainOnly => FushiIcons.openInNew,
    };

/// The chip label of [section].
String companionLibrarySectionLabel(
  CompanionLibrarySection section,
) => switch (section) {
  CompanionLibrarySection.home => t.second_screen_library_browse_section_home,
  CompanionLibrarySection.books => t.second_screen_library_browse_section_books,
  CompanionLibrarySection.manga => t.second_screen_library_browse_section_manga,
  CompanionLibrarySection.video => t.second_screen_library_browse_section_video,
  CompanionLibrarySection.audiobooks =>
    t.second_screen_library_browse_section_audiobooks,
  CompanionLibrarySection.music => t.second_screen_library_browse_section_music,
  CompanionLibrarySection.servers =>
    t.second_screen_library_browse_section_servers,
};

/// The card's meta line: subtitle and progress label, or the child count of
/// a container; null when the item has none of them.
String? companionLibraryItemMeta(CompanionLibraryItem item) {
  final List<String> parts = <String>[
    if (item.subtitle case final String s when s.isNotEmpty) s,
    if (item.progressLabel case final String p when p.isNotEmpty) p,
  ];
  if (parts.isEmpty && item.count != null) {
    parts.add(t.second_screen_library_browse_item_count(n: item.count!));
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

/// An item's cover: its local file, the main engine's cached remote cover
/// (asked once, lazily), or an icon tile.
class CompanionLibraryCover extends ConsumerWidget {
  const CompanionLibraryCover({
    required this.item,
    this.width,
    this.height,
    super.key,
  });

  final CompanionLibraryItem item;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? path = ref
        .watch(companionLibraryCoversProvider)
        .coverOf(item);
    final Widget fallback = ColoredBox(
      color: colors.secondaryContainer,
      child: Center(
        child: FushiIcon(
          companionLibraryKindIcon(item.kind),
          color: colors.onSecondaryContainer,
        ),
      ),
    );
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: FushiM3eShape.smallRadius,
      child: SizedBox(
        width: width ?? double.infinity,
        height: height ?? double.infinity,
        child: path == null
            ? fallback
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                cacheWidth: ((width ?? kCompanionLibraryCardWidth) * dpr)
                    .round(),
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        fallback,
              ),
      ),
    );
  }
}

/// A cover card: cover (finished badge), title, meta line, progress bar.
/// [onTap] is the card's action; [onDetails] adds a small "Details" button
/// on the cover (Continue rows, whose card opens the item on top).
class CompanionLibraryCard extends StatelessWidget {
  const CompanionLibraryCard({
    required this.item,
    required this.onTap,
    this.onDetails,
    super.key,
  });

  final CompanionLibraryItem item;
  final VoidCallback onTap;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String? meta = companionLibraryItemMeta(item);
    final double? progress = item.finished
        ? null
        : item.progress?.clamp(0.0, 1.0);
    final String semantics = <String>[
      item.title,
      ?meta,
      if (item.finished) t.second_screen_library_browse_finished,
    ].join(', ');
    final VoidCallback? details = onDetails;
    return FushiPressScale(
      child: Semantics(
        button: true,
        label: semantics,
        excludeSemantics: details == null,
        child: FushiCard(
          key: ValueKey<String>('companion-library-card-${item.ref}'),
          pressScale: false,
          stateLayer: false,
          color: Colors.transparent,
          padding: EdgeInsets.zero,
          borderRadius: FushiM3eShape.smallRadius,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    CompanionLibraryCover(item: item),
                    if (item.finished)
                      PositionedDirectional(
                        top: 4,
                        end: 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: FushiIcon(
                              FushiIcons.check,
                              size: 16,
                              color: colors.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    if (details != null)
                      PositionedDirectional(
                        bottom: 0,
                        end: 0,
                        child: FushiIconButton(
                          key: ValueKey<String>(
                            'companion-library-details-${item.ref}',
                          ),
                          icon: FushiIcons.info,
                          tooltip: t.second_screen_library_browse_details,
                          onTap: details,
                          size: 20,
                          backgroundColor: colors.surfaceContainerHigh
                              .withValues(alpha: 0.85),
                          padTouchTarget: true,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                meta ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 4,
                child: progress == null
                    ? null
                    : FushiLinearProgressIndicator(value: progress),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small caption above a row / list ("Continue", "Episodes · ...").
class CompanionLibraryCaption extends StatelessWidget {
  const CompanionLibraryCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A static skeleton of cover cards while the first page loads (no endless
/// animation, so the panel stays idle while it waits).
class CompanionLibrarySkeleton extends StatelessWidget {
  const CompanionLibrarySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final Color tone = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget card() => SizedBox(
      width: kCompanionLibraryCardWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tone,
                borderRadius: FushiM3eShape.smallRadius,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 12,
            decoration: BoxDecoration(
              color: tone,
              borderRadius: FushiM3eShape.smallRadius,
            ),
          ),
          const SizedBox(height: 26),
        ],
      ),
    );
    return ExcludeSemantics(
      key: const ValueKey<String>('companion-library-loading'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            height: kCompanionLibraryCardHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < 4; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: 10),
                  card(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty / error message filling a page; [onRetry] shows the error tone and
/// a Retry button, [detail] the main engine's error text.
class CompanionLibraryMessage extends StatelessWidget {
  const CompanionLibraryMessage({
    required this.icon,
    required this.message,
    this.detail,
    this.onRetry,
    super.key,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? retry = onRetry;
    return FushiEntranceScope(
      child: FushiStaggeredEntrance(
        index: 0,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: FushiPlaceholderMessage(
              icon: icon,
              message: message,
              detail: detail,
              tone: retry == null
                  ? FushiPlaceholderTone.neutral
                  : FushiPlaceholderTone.error,
              action: retry == null
                  ? null
                  : FushiFilledButton.tonal(
                      key: const ValueKey<String>('companion-library-retry'),
                      onPressed: retry,
                      child: Text(t.retry),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The load failure of [feed] with Retry.
Widget companionLibraryError(
  CompanionLibraryFeedBase feed, {
  String? message,
}) => CompanionLibraryMessage(
  key: const ValueKey<String>('companion-library-error'),
  icon: FushiIcons.cloudOff,
  message: message ?? t.second_screen_library_browse_load_failed,
  detail: feed.error,
  onRetry: () => unawaited(feed.retry()),
);

/// Back + title on top of a pushed Browse page.
class CompanionLibraryPageHeader extends StatelessWidget {
  const CompanionLibraryPageHeader({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 16, 0),
    child: Row(
      children: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('companion-library-back'),
          icon: FushiIcons.back,
          tooltip: t.back,
          onTap: () => unawaited(Navigator.of(context).maybePop()),
          padTouchTarget: true,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ],
    ),
  );
}
