import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_actions.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_feed.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_widgets.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// The details line under the title: child count · ★ rating · year, each
/// part only when known; null when none is.
String? companionLibraryDetailsLine(CompanionLibraryDetails details) {
  final int? count = details.item.count;
  final double? rating = details.rating;
  final List<String> parts = <String>[
    if (count != null) t.second_screen_library_browse_item_count(n: count),
    if (rating != null) '★ ${_formatRating(rating)}',
    if (details.year case final int year) '$year',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _formatRating(double rating) {
  final String text = rating.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// [details] with [item] in place of its item (after `library.markFinished`).
CompanionLibraryDetails _withItem(
  CompanionLibraryDetails details,
  CompanionLibraryItem item,
) => CompanionLibraryDetails(
  item: item,
  author: details.author,
  description: details.description,
  genres: details.genres,
  rating: details.rating,
  ratingVotes: details.ratingVotes,
  year: details.year,
  facts: details.facts,
  entries: details.entries,
  entriesLabel: details.entriesLabel,
  continueLabel: details.continueLabel,
  canOpen: details.canOpen,
  canMarkFinished: details.canMarkFinished,
);

/// Details of one library item (`library.details {ref}`): info, chapters /
/// episodes, Continue on top, Mark finished. Pushed on the Library tab's
/// current mode navigator by Browse lists and by Main mode's "Details".
class CompanionLibraryDetailsPage extends ConsumerStatefulWidget {
  const CompanionLibraryDetailsPage({
    required this.itemRef,
    this.title,
    super.key,
  });

  /// `CompanionLibraryItem.ref`.
  final String itemRef;

  /// Shown while the details load.
  final String? title;

  @override
  ConsumerState<CompanionLibraryDetailsPage> createState() =>
      _CompanionLibraryDetailsPageState();
}

class _CompanionLibraryDetailsPageState
    extends ConsumerState<CompanionLibraryDetailsPage>
    with CompanionLibraryLive<CompanionLibraryDetailsPage> {
  late final CompanionPanelSession _session;
  late final CompanionLibraryValueFeed<CompanionLibraryDetails> _feed;
  bool _marking = false;

  @override
  void initState() {
    super.initState();
    _session = ref.read(companionPanelSessionProvider);
    _feed = CompanionLibraryValueFeed.details(_session, widget.itemRef);
    startLive(_session);
  }

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  @override
  List<CompanionLibraryFeedBase> get liveFeeds => <CompanionLibraryFeedBase>[
    _feed,
  ];

  @override
  CompanionLibraryFeedBase get shownFeed => _feed;

  Future<void> _markFinished(CompanionLibraryDetails details) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    setState(() => _marking = true);
    try {
      final Object? reply = await _session.request(
        CompanionRequestMethods.libraryMarkFinished,
        <String, Object?>{
          CompanionLibraryArgs.ref: details.item.ref,
          CompanionLibraryArgs.finished: !details.item.finished,
        },
      );
      if (!mounted) return;
      if (reply is Map) {
        final CompanionLibraryDetails? shown = _feed.value;
        if (shown != null) {
          _feed.replace(
            _withItem(
              shown,
              CompanionLibraryItem.fromJson(companionLibraryReplyObject(reply)),
            ),
          );
        }
      }
      // Entries / progress change with it: read the details again.
      unawaited(_feed.refresh());
    } on CompanionRequestException {
      messenger?.showSnackBar(
        FushiSnackBar(
          content: Text(t.second_screen_library_browse_mark_failed),
        ),
      );
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListenableBuilder(
      listenable: _feed,
      builder: (BuildContext context, Widget? _) {
        final CompanionLibraryDetails? details = _feed.value;
        final Widget body;
        if (details == null && _feed.failed) {
          body = Column(
            key: const ValueKey<String>('companion-library-details-error'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              CompanionLibraryPageHeader(title: widget.title ?? ''),
              Expanded(
                child: companionLibraryError(
                  _feed,
                  message: t.second_screen_library_browse_details_failed,
                ),
              ),
            ],
          );
        } else if (details == null) {
          body = Column(
            key: const ValueKey<String>('companion-library-details-loading'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              CompanionLibraryPageHeader(title: widget.title ?? ''),
              const Expanded(child: CompanionLibrarySkeleton()),
            ],
          );
        } else {
          body = _DetailsBody(
            key: const ValueKey<String>('companion-library-details'),
            details: details,
            marking: _marking,
            onMarkFinished: () => unawaited(_markFinished(details)),
          );
        }
        return AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          child: body,
        );
      },
    ),
  );
}

class _DetailsBody extends ConsumerWidget {
  const _DetailsBody({
    required this.details,
    required this.marking,
    required this.onMarkFinished,
    super.key,
  });

  final CompanionLibraryDetails details;
  final bool marking;
  final VoidCallback onMarkFinished;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final CompanionLibraryItem item = details.item;
    final String? line = companionLibraryDetailsLine(details);
    final String? author = details.author ?? item.subtitle;
    final String? description = details.description;
    final TextStyle? meta = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final String continueLabel =
        details.continueLabel ?? t.second_screen_library_browse_open_on_top;
    final List<Widget> items = <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FushiIconButton(
            key: const ValueKey<String>('companion-library-back'),
            icon: FushiIcons.back,
            tooltip: t.back,
            onTap: () => unawaited(Navigator.of(context).maybePop()),
            padTouchTarget: true,
          ),
          const SizedBox(width: 4),
          CompanionLibraryCover(item: item, width: 70, height: 98),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                if (line != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    line,
                    key: const ValueKey<String>(
                      'companion-library-details-line',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
                ],
                if (author != null && author.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
                ],
                if (item.finished) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    t.second_screen_library_browse_finished,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      if (description != null && description.trim().isNotEmpty)
        _Description(text: description.trim()),
      Row(
        children: <Widget>[
          Expanded(
            flex: 8,
            child: FushiPressScale(
              enabled: details.canOpen,
              child: FushiFilledButton(
                key: const ValueKey<String>('companion-library-continue'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: details.canOpen
                    ? () => unawaited(
                        companionLibraryOpen(context, ref, itemRef: item.ref),
                      )
                    : null,
                child: Text(
                  continueLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (details.canMarkFinished) ...<Widget>[
            const SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: FushiPressScale(
                enabled: !marking,
                child: FushiOutlinedButton(
                  key: const ValueKey<String>('companion-library-mark'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: marking ? null : onMarkFinished,
                  child: Text(
                    item.finished
                        ? t.second_screen_library_browse_mark_unfinished
                        : t.second_screen_library_browse_mark_finished,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      if (details.genres.isNotEmpty)
        Wrap(
          key: const ValueKey<String>('companion-library-genres'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final String genre in details.genres)
              FushiTagChip(label: genre, tone: FushiTagChipTone.surface),
          ],
        ),
      for (final CompanionLibraryFact fact in details.facts)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 96,
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
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      if (details.entries.isNotEmpty) ...<Widget>[
        CompanionLibraryCaption(
          details.entriesLabel == null
              ? t.second_screen_library_browse_open_on_top
              : t.second_screen_library_browse_entries_hint(
                  label: details.entriesLabel!,
                ),
        ),
        for (final CompanionLibraryEntry entry in details.entries)
          CompanionLineTile(
            key: ValueKey<String>('companion-library-entry-${entry.id}'),
            text: entry.title,
            trailing: entry.subtitle,
            selected: entry.current,
            maxLines: 1,
            onTap: details.canOpen
                ? () => unawaited(
                    companionLibraryOpen(
                      context,
                      ref,
                      itemRef: item.ref,
                      entry: entry.id,
                    ),
                  )
                : null,
          ),
      ],
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(
          12,
          4,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: items.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => Padding(
            padding: EdgeInsetsDirectional.only(
              top: index == 0 ? 0 : 8,
              start: index == 0 ? 0 : 4,
            ),
            child: items[index],
          ),
        ),
      ),
    );
  }
}

/// The description: two lines, "More" shows all of it (only when it is
/// longer than two lines).
class _Description extends StatefulWidget {
  const _Description({required this.text});

  final String text;

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.45,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 2,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool long = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: fushiMd3StateCurve,
              alignment: Alignment.topLeft,
              child: Text(
                widget.text,
                key: const ValueKey<String>('companion-library-description'),
                maxLines: _expanded || !long ? null : 2,
                overflow: _expanded || !long ? null : TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (long)
              FushiTextButton(
                key: const ValueKey<String>(
                  'companion-library-description-more',
                ),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded
                      ? t.second_screen_library_browse_less
                      : t.second_screen_library_browse_more,
                ),
              ),
          ],
        );
      },
    );
  }
}
