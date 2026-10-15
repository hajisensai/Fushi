/// 复习笔记浏览：按排序字段搜索，点进编辑页；行内菜单删除 / 移动卡片 / 暂停。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show SrsCardCacheRow, SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

enum _NoteAction { edit, move, suspend, delete }

class SrsBrowsePage extends ConsumerStatefulWidget {
  const SrsBrowsePage({super.key});

  @override
  ConsumerState<SrsBrowsePage> createState() => _SrsBrowsePageState();
}

class _SrsBrowsePageState extends ConsumerState<SrsBrowsePage> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'srs-browse-search');
  Timer? _debounce;
  bool _loading = true;
  List<SrsNoteCacheRow> _notes = const <SrsNoteCacheRow>[];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final List<SrsNoteCacheRow> rows = await store.listNotes(
      textQuery: _query.text,
    );
    if (!mounted) return;
    setState(() {
      _notes = rows;
      _loading = false;
    });
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) unawaited(_reload());
    });
  }

  Future<void> _open(SrsNoteCacheRow row) async {
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => SrsNoteEditorPage(noteId: row.id),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _onAction(SrsNoteCacheRow row, _NoteAction action) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return;
    switch (action) {
      case _NoteAction.edit:
        await _open(row);
        return;
      case _NoteAction.move:
        final List<SrsDeckSummary> decks = await store.deckSummaries();
        if (!mounted) return;
        final String? target = await pickSrsDeck(
          context,
          decks: decks,
          selected: row.deckId,
          title: t.srs_card_move,
        );
        if (target == null) return;
        for (final SrsCardCacheRow c in await store.cardsOfNote(row.id)) {
          await store.moveCard(c.id, target);
        }
      case _NoteAction.suspend:
        final List<SrsCardCacheRow> cards = await store.cardsOfNote(row.id);
        // 全部已暂停 → 取消暂停；否则全部暂停。
        final bool suspend = !cards.every((SrsCardCacheRow c) => c.suspended);
        for (final SrsCardCacheRow c in cards) {
          await store.setSuspended(c.id, suspend);
        }
        FushiToast.show(
          msg: suspend ? t.srs_browse_suspended : t.srs_browse_unsuspended,
        );
      case _NoteAction.delete:
        final bool ok = await showFushiConfirmDialog(
          context: context,
          title: t.srs_note_delete,
          message: t.srs_note_delete_confirm,
          confirmLabel: t.srs_note_delete,
          cancelLabel: t.cancel,
          icon: FushiIcons.delete,
          destructive: true,
        );
        if (!ok) return;
        await store.deleteNote(row.id);
    }
    if (!mounted) return;
    bumpSrsRevision(ref);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final Widget search = FushiSearchField(
      key: const ValueKey<String>('srs-browse-search'),
      controller: _query,
      focusNode: _queryFocus,
      hintText: t.srs_browse_search_hint,
      onChanged: _onQueryChanged,
      onSubmitted: (_) => unawaited(_reload()),
      onClear: () => unawaited(_reload()),
    );
    return FushiPageScaffold(
      title: t.srs_browse_title,
      header: apple ? null : _buildTopBar(context),
      headerBottom: apple ? search : null,
      body: Builder(
        builder: (BuildContext context) =>
            _buildList(context, apple ? null : search),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: t.srs_browse_title,
        subtitle: t.srs_browse_count(n: _notes.length),
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[
            FushiToolbarItem(
              icon: FushiIcons.refresh,
              label: t.refresh,
              onPressed: () => unawaited(_reload()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, Widget? search) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets padding = withBottomSafeInset(
      context,
      EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap + MediaQuery.paddingOf(context).top,
        tokens.spacing.page,
        tokens.spacing.section,
      ),
    );
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final int offset = search == null ? 0 : 1;
    if (_notes.isEmpty) {
      return ListView(
        padding: padding,
        children: <Widget>[
          if (search != null) search,
          SizedBox(height: tokens.spacing.section),
          FushiPlaceholderMessage(
            icon: FushiIcons.searchOff,
            message: t.srs_browse_empty,
          ),
        ],
      );
    }
    return FushiEntranceScope(
      replayKey: _query.text,
      child: ListView.builder(
        padding: padding,
        itemCount: _notes.length + offset,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          if (search != null && i == 0) {
            return Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
              child: search,
            );
          }
          final int index = i - offset;
          final SrsNoteCacheRow row = _notes[index];
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('srs-note-${row.id}'),
              index: index,
              count: _notes.length,
              onTap: () => unawaited(_open(row)),
              child: FushiListItem(
                leading: FushiListLeadingIcon(
                  row.pendingDecision
                      ? FushiIcons.warning
                      : FushiIcons.ankiCard,
                  tone: row.pendingDecision
                      ? FushiCardTone.error
                      : FushiCardTone.neutral,
                ),
                title: Text(row.sortField.isEmpty ? '—' : row.sortField),
                subtitle: Text(srsFormatMoment(row.createdAt), maxLines: 1),
                trailing: FushiPopupMenuButton<_NoteAction>(
                  tooltip: t.srs_deck_menu,
                  icon: const FushiIcon(FushiIcons.more),
                  onSelected: (_NoteAction a) =>
                      srsRunLogged('SrsBrowse.action', () => _onAction(row, a)),
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<_NoteAction>>[
                        PopupMenuItem<_NoteAction>(
                          value: _NoteAction.edit,
                          child: Text(t.srs_note_edit),
                        ),
                        PopupMenuItem<_NoteAction>(
                          value: _NoteAction.move,
                          child: Text(t.srs_card_move),
                        ),
                        PopupMenuItem<_NoteAction>(
                          value: _NoteAction.suspend,
                          child: Text(t.srs_browse_toggle_suspend),
                        ),
                        PopupMenuItem<_NoteAction>(
                          value: _NoteAction.delete,
                          child: Text(t.srs_note_delete),
                        ),
                      ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
