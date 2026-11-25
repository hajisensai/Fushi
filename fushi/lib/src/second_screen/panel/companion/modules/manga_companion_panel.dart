import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/manga_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show adaptiveAppBar;
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// The companion's Now panel while a manga is open on top: where the reader
/// is, page / chapter controls, the current page's text ("OCR this page",
/// tap a word to look it up on the panel) and the chapter list.
class MangaCompanionPanel extends StatelessWidget {
  const MangaCompanionPanel({required this.session, super.key});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (BuildContext context, Widget? child) => _MangaPanelBody(
      session: session,
      data: session.snapshot ?? const <String, Object?>{},
    ),
  );
}

class _MangaPanelBody extends StatelessWidget {
  const _MangaPanelBody({required this.session, required this.data});

  final CompanionPanelSession session;
  final Map<String, Object?> data;

  void _send(String action, [Map<String, Object?>? args]) =>
      unawaited(session.command(action, args ?? const <String, Object?>{}));

  @override
  Widget build(BuildContext context) {
    final int pageCount = data.integer(MangaCompanionKeys.pageCount);
    final int page = data.integer(MangaCompanionKeys.page);
    final bool rtl = data.flag(MangaCompanionKeys.rtl);
    final String title =
        data.strOrNull(MangaCompanionKeys.title) ?? session.context.title ?? '';
    final String? chapter = data.strOrNull(MangaCompanionKeys.chapter);
    final String? author = data.strOrNull(MangaCompanionKeys.author);
    final List<String> genres = data.strings(MangaCompanionKeys.genres);
    final String? description = data.strOrNull(MangaCompanionKeys.description);
    final int chapterCount = data.integer(MangaCompanionKeys.chapterCount);
    final int? chapterPosition = data.intOrNull(
      MangaCompanionKeys.chapterPosition,
    );
    final double? rating = data.doubleOrNull(MangaCompanionKeys.rating);
    // Rating first, then the source's genres: tag chips under the title.
    final List<String> chips = <String>[
      if (rating != null)
        companionRatingLabel(
          rating,
          votes: data.intOrNull(MangaCompanionKeys.votes),
        ),
      ...genres,
    ];
    final List<Widget> items = <Widget>[
      CompanionPanelHeader(
        label: t.second_screen_manga_header,
        trailing: pageCount > 0
            ? t.second_screen_manga_page(current: page + 1, total: pageCount)
            : null,
      ),
      _padded(
        CompanionTitleBlock(
          title: chapter == null ? title : '$title · $chapter',
          subtitle: author,
          coverPath: data.strOrNull(MangaCompanionKeys.cover),
          fallbackIcon: FushiIcons.manga,
        ),
      ),
      if (chips.isNotEmpty)
        _padded(
          CompanionTagChips(
            key: const ValueKey<String>('manga-info-chips'),
            chips: chips,
          ),
        ),
      _padded(
        Row(
          children: <Widget>[
            SizedBox(
              width: 64,
              child: CompanionActionButton(
                icon: rtl ? FushiIcons.chevronRight : FushiIcons.chevronLeft,
                tooltip: t.manga_previous_page,
                onPressed: () => _send(MangaCompanionActions.previousPage),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FushiLinearProgressIndicator(
                  value: pageCount > 0 ? (page + 1) / pageCount : 0,
                  wavy: false,
                ),
              ),
            ),
            SizedBox(
              width: 64,
              child: CompanionActionButton(
                icon: rtl ? FushiIcons.chevronLeft : FushiIcons.chevronRight,
                tooltip: t.manga_next_page,
                primary: true,
                onPressed: () => _send(MangaCompanionActions.nextPage),
              ),
            ),
          ],
        ),
      ),
      _padded(_MangaPageTextCard(session: session, data: data)),
      if (chapterCount > 0)
        _padded(
          Row(
            children: <Widget>[
              SizedBox(
                width: 64,
                child: CompanionActionButton(
                  icon: FushiIcons.skipPrevious,
                  tooltip: t.manga_series_previous_chapter,
                  onPressed: () => _send(MangaCompanionActions.previousChapter),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: CompanionLineTile(
                  text: t.mihon_chapters_title,
                  maxLines: 1,
                  trailing: chapterPosition == null
                      ? '$chapterCount ›'
                      : '${t.second_screen_manga_chapter_position(current: chapterPosition, total: chapterCount)} ›',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          _MangaChapterListPage(session: session),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: CompanionActionButton(
                  icon: FushiIcons.skipNext,
                  tooltip: t.manga_series_next_chapter,
                  onPressed: () => _send(MangaCompanionActions.nextChapter),
                ),
              ),
            ],
          ),
        ),
      if (description != null) ...<Widget>[
        _padded(CompanionSectionLabel(t.second_screen_manga_about)),
        _padded(
          CompanionLineTile(
            text: description,
            maxLines: 3,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => _MangaDescriptionPage(
                  title: title,
                  description: description,
                ),
              ),
            ),
          ),
        ),
      ],
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: items.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 10),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }

  static Widget _padded(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: child,
  );
}

/// "Text on this page": the OCR button, its state and the page's text
/// blocks (tap a word → panel-side lookup).
class _MangaPageTextCard extends ConsumerWidget {
  const _MangaPageTextCard({required this.session, required this.data});

  final CompanionPanelSession session;
  final Map<String, Object?> data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final MangaCompanionOcrState state = MangaCompanionOcrState.fromWire(
      data.strOrNull(MangaCompanionKeys.ocr),
    );
    final List<String> lines = data.strings(MangaCompanionKeys.lines);
    final bool canRun =
        session.snapshot != null &&
        lines.isEmpty &&
        state != MangaCompanionOcrState.running;
    final TextStyle? note = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final Widget body;
    if (lines.isNotEmpty) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < lines.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 6),
            _TapWordLine(
              text: lines[i],
              onLookUp: (int charIndex) => ref
                  .read(companionLookupControllerProvider)
                  .lookUp(
                    text: lines[i],
                    charIndex: charIndex,
                    sentence: lines[i],
                  ),
            ),
          ],
        ],
      );
    } else {
      body = switch (state) {
        MangaCompanionOcrState.running => Row(
          children: <Widget>[
            const SizedBox(
              width: 20,
              height: 20,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(t.second_screen_manga_ocr_running, style: note),
            ),
          ],
        ),
        MangaCompanionOcrState.empty => Text(
          t.second_screen_manga_ocr_empty,
          style: note,
        ),
        MangaCompanionOcrState.failed => Text(
          <String>[
            t.second_screen_manga_ocr_failed,
            ?data.strOrNull(MangaCompanionKeys.ocrError),
          ].join('\n'),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
        ),
        MangaCompanionOcrState.noEngine => Text(
          t.manga_reader_ocr_unavailable,
          style: note,
        ),
        MangaCompanionOcrState.unsupported => Text(
          t.second_screen_manga_ocr_unsupported,
          style: note,
        ),
        MangaCompanionOcrState.idle || MangaCompanionOcrState.done => Text(
          t.second_screen_manga_ocr_hint,
          style: note,
        ),
      };
    }
    return FushiCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.second_screen_manga_text_label,
                  maxLines: 2,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FushiPressScale(
                child: FushiTooltip(
                  message: t.second_screen_manga_ocr_action,
                  child: SizedBox(
                    height: 48,
                    child: FushiFilledButton.tonalIcon(
                      onPressed: canRun
                          ? () => unawaited(
                              session.command(MangaCompanionActions.ocrPage),
                            )
                          : null,
                      icon: const FushiIcon(FushiIcons.ocr, size: 20),
                      label: Text(t.second_screen_manga_ocr_action),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          body,
        ],
      ),
    );
  }
}

/// One text block: a focusable button; a touch looks up the tapped word
/// (its character index), a controller press looks up from the start.
class _TapWordLine extends StatefulWidget {
  const _TapWordLine({required this.text, required this.onLookUp});

  final String text;
  final ValueChanged<int> onLookUp;

  @override
  State<_TapWordLine> createState() => _TapWordLineState();
}

class _TapWordLineState extends State<_TapWordLine> {
  final GlobalKey _textKey = GlobalKey();
  int? _tapped;

  int? _indexAt(Offset global) =>
      companionTextIndexAt(_textKey, widget.text, global);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Semantics(
      button: true,
      hint: t.second_screen_manga_line_hint,
      child: FushiPressScale(
        child: Material(
          color: colors.containerOf(FushiTone.neutral),
          shape: const RoundedRectangleBorder(
            borderRadius: FushiM3eShape.smallRadius,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTapUp: (TapUpDetails details) =>
                _tapped = _indexAt(details.globalPosition),
            onTap: () {
              final int index = _tapped ?? 0;
              _tapped = null;
              widget.onLookUp(index);
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    widget.text,
                    key: _textKey,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chapter list (pushed on the Now tab): tap = open that chapter on top.
class _MangaChapterListPage extends StatefulWidget {
  const _MangaChapterListPage({required this.session});

  final CompanionPanelSession session;

  @override
  State<_MangaChapterListPage> createState() => _MangaChapterListPageState();
}

class _MangaChapterListPageState extends State<_MangaChapterListPage> {
  static const double _rowExtent = 56;

  /// Opens with the current chapter in view.
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: _initialOffset(),
  );

  CompanionPanelSession get session => widget.session;

  double _initialOffset() {
    final Map<String, Object?> data =
        session.snapshot ?? const <String, Object?>{};
    final int? current = data.intOrNull(MangaCompanionKeys.currentChapter);
    final int at = data
        .maps(MangaCompanionKeys.chapters)
        .indexWhere(
          (Map<String, Object?> c) =>
              c.intOrNull(MangaCompanionKeys.chapterIndex) == current,
        );
    return at > 2 ? (at - 2) * _rowExtent : 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: adaptiveAppBar(
        context: context,
        title: Text(t.mihon_chapters_title),
      ),
      body: ListenableBuilder(
        listenable: session,
        builder: (BuildContext context, Widget? child) {
          final Map<String, Object?> live =
              session.snapshot ?? const <String, Object?>{};
          final List<Map<String, Object?>> chapters = live.maps(
            MangaCompanionKeys.chapters,
          );
          final int? now = live.intOrNull(MangaCompanionKeys.currentChapter);
          return FushiEntranceScope(
            child: ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: chapters.length,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int i,
              ) {
                final Map<String, Object?> c = chapters[i];
                final int index = c.integer(MangaCompanionKeys.chapterIndex);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: CompanionLineTile(
                    text: c.str(MangaCompanionKeys.chapterName),
                    maxLines: 1,
                    selected: index == now,
                    onTap: () {
                      if (index != now) {
                        unawaited(
                          session.command(
                            MangaCompanionActions.goToChapter,
                            <String, Object?>{
                              MangaCompanionActions.argIndex: index,
                            },
                          ),
                        );
                      }
                      unawaited(Navigator.of(context).maybePop());
                    },
                  ),
                );
              }),
            ),
          );
        },
      ),
    );
  }
}

/// The series description in full (pushed on the Now tab).
class _MangaDescriptionPage extends StatelessWidget {
  const _MangaDescriptionPage({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: adaptiveAppBar(
        context: context,
        title: Text(t.second_screen_manga_about),
      ),
      body: FushiEntranceScope(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: <Widget>[
            FushiStaggeredEntrance(
              index: 0,
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            FushiStaggeredEntrance(
              index: 1,
              child: Text(description, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}
