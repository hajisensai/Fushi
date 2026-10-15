/// 复习笔记编辑页（新建 / 编辑）。
///
/// - 新建：选笔记类型（默认 Lapis）与牌组，逐字段填写；添加后清空字段继续添加。
/// - 编辑：字段有同步冲突（两台设备同时改了同一字段）时，在该字段下列出各候选值，
///   点选即写入一条新修改记录，冲突随之消失。笔记处于「删除与并发修改」待裁决时
///   顶部给出「恢复 / 确认删除」。
/// - Lapis 字段多：常用的 Expression / ExpressionReading / MainDefinition / Sentence
///   放前面，其余折进「更多字段」。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class SrsNoteEditorPage extends ConsumerStatefulWidget {
  const SrsNoteEditorPage({super.key, this.noteId, this.initialDeckId});

  /// 非 null = 编辑已有笔记；null = 新建。
  final String? noteId;

  /// 新建时的初始牌组（null = 默认牌组）。
  final String? initialDeckId;

  @override
  ConsumerState<SrsNoteEditorPage> createState() => _SrsNoteEditorPageState();
}

class _SrsNoteEditorPageState extends ConsumerState<SrsNoteEditorPage> {
  SrsDbStore? _store;
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  List<SrsNoteTypeView> _types = const <SrsNoteTypeView>[];
  List<SrsDeckSummary> _decks = const <SrsDeckSummary>[];
  SrsNoteTypeView? _type;
  String? _deckId;
  SrsNoteView? _note;

  /// fieldId → 输入框。换笔记类型时按字段名搬值。
  final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{};
  final TextEditingController _tags = TextEditingController();

  bool get _editing => widget.noteId != null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final TextEditingController c in _fields.values) {
      c.dispose();
    }
    _tags.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final List<SrsNoteTypeView> types = await store.noteTypes();
      final List<SrsDeckSummary> decks = await store.deckSummaries();
      SrsNoteView? note;
      SrsNoteTypeView? type;
      String deckId = widget.initialDeckId ?? store.defaultDeckId;
      if (widget.noteId != null) {
        note = await store.note(widget.noteId!);
        if (note == null) throw StateError('note ${widget.noteId} not found');
        type = await store.noteType(note.noteTypeId);
        deckId = note.deckId ?? store.defaultDeckId;
      } else {
        type =
            types
                .where((SrsNoteTypeView v) => v.id == store.lapisNoteTypeId)
                .firstOrNull ??
            types.firstOrNull;
      }
      if (!mounted) return;
      setState(() {
        _store = store;
        _types = types;
        _decks = decks;
        _note = note;
        _deckId = deckId;
        _loading = false;
        _applyType(type, from: note);
        if (note != null) _tags.text = note.tags.join(' ');
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsNoteEditorPage.load', e, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  /// 换成 [type] 的字段集合；同名字段带着已填的值过去。
  void _applyType(SrsNoteTypeView? type, {SrsNoteView? from}) {
    final Map<String, String> byName = <String, String>{
      if (_type != null)
        for (final SrsFieldDef f in _type!.fields)
          f.name: _fields[f.id]?.text ?? '',
    };
    for (final TextEditingController c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
    _type = type;
    if (type == null) return;
    for (final SrsFieldDef f in type.fields) {
      _fields[f.id] = TextEditingController(
        text: from?.field(f.id) ?? byName[f.name] ?? '',
      );
    }
  }

  /// 常用字段在前（Lapis），其余进「更多字段」。
  (List<SrsFieldDef>, List<SrsFieldDef>) _splitFields(SrsNoteTypeView type) {
    if (type.builtinKey != kSrsBuiltinLapisKey) {
      return (type.fields, const <SrsFieldDef>[]);
    }
    final List<SrsFieldDef> primary = <SrsFieldDef>[
      for (final String name in kSrsLapisPrimaryFields)
        ...type.fields.where((SrsFieldDef f) => f.name == name),
    ];
    final List<SrsFieldDef> rest = type.fields
        .where((SrsFieldDef f) => !kSrsLapisPrimaryFields.contains(f.name))
        .toList();
    return (primary, rest);
  }

  List<String> _parseTags() => _tags.text
      .split(RegExp(r'\s+'))
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toSet()
      .toList();

  bool get _hasContent =>
      _fields.values.any((TextEditingController c) => c.text.trim().isNotEmpty);

  Future<void> _save() async {
    final SrsDbStore? store = _store;
    final SrsNoteTypeView? type = _type;
    if (store == null || type == null || _saving || !_hasContent) return;
    setState(() => _saving = true);
    try {
      final Map<String, String> values = <String, String>{
        for (final MapEntry<String, TextEditingController> e in _fields.entries)
          e.key: e.value.text,
      };
      if (_editing) {
        await store.updateNote(
          widget.noteId!,
          fieldsById: values,
          tags: _parseTags(),
        );
        // 笔记的首选牌组改了：只改「之后生成的卡」的初始牌组；已有卡片按卡移动。
        if (_deckId != null && _deckId != _note?.deckId) {
          await store.editField(
            SrsEntityKind.note,
            widget.noteId!,
            SrsFieldKeys.noteDeck,
            _deckId,
          );
          for (final SrsCardCacheRow card in await store.cardsOfNote(
            widget.noteId!,
          )) {
            await store.moveCard(card.id, _deckId!);
          }
        }
        if (!mounted) return;
        bumpSrsRevision(ref);
        await Navigator.of(context).maybePop();
        return;
      }
      await store.createNote(
        noteTypeId: type.id,
        fieldsById: values,
        deckId: _deckId,
        tags: _parseTags(),
      );
      if (!mounted) return;
      bumpSrsRevision(ref);
      FushiToast.show(msg: t.srs_note_added, severity: ToastSeverity.success);
      // 连续添加：清空字段，保留牌组 / 类型 / 标签。
      setState(() {
        for (final TextEditingController c in _fields.values) {
          c.clear();
        }
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsNoteEditorPage.save', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 冲突候选点选：写一条覆盖全部候选的新记录，然后重读笔记。
  Future<void> _pickCandidate(SrsFieldDef field, String value) async {
    final SrsDbStore? store = _store;
    final String? noteId = widget.noteId;
    if (store == null || noteId == null) return;
    await store.updateNote(
      noteId,
      fieldsById: <String, String>{field.id: value},
    );
    await _reloadNote();
  }

  Future<void> _reloadNote() async {
    final SrsDbStore? store = _store;
    final String? noteId = widget.noteId;
    if (store == null || noteId == null) return;
    final SrsNoteView? note = await store.note(noteId);
    if (!mounted || note == null) return;
    bumpSrsRevision(ref);
    setState(() {
      _note = note;
      for (final MapEntry<String, TextEditingController> e in _fields.entries) {
        e.value.text = note.field(e.key);
      }
    });
  }

  Future<void> _restore() async {
    await _store?.restoreNote(widget.noteId!);
    await _reloadNote();
  }

  Future<void> _confirmDelete() async {
    await _store?.deleteNote(widget.noteId!);
    if (!mounted) return;
    bumpSrsRevision(ref);
    await Navigator.of(context).maybePop();
  }

  Future<void> _pickType() async {
    final String? id = await showFushiChoiceDialog<String>(
      context: context,
      title: t.srs_note_type,
      icon: FushiIcons.ankiCard,
      selected: _type?.id,
      options: <FushiChoiceOption<String>>[
        for (final SrsNoteTypeView v in _types)
          FushiChoiceOption<String>(value: v.id, label: v.name),
      ],
    );
    if (id == null || id == _type?.id || !mounted) return;
    setState(
      () => _applyType(
        _types.where((SrsNoteTypeView v) => v.id == id).firstOrNull,
      ),
    );
  }

  Future<void> _pickDeck() async {
    final String? id = await pickSrsDeck(
      context,
      decks: _decks,
      selected: _deckId,
      title: t.srs_note_deck,
    );
    if (id == null || !mounted) return;
    setState(() => _deckId = id);
  }

  String get _title => _editing ? t.srs_note_edit : t.srs_note_add;

  FushiToolbarItem get _saveItem => FushiToolbarItem(
    key: const ValueKey<String>('srs_note_save'),
    icon: _editing ? FushiIcons.save : FushiIcons.add,
    label: _editing ? t.srs_note_save : t.srs_note_add_action,
    onPressed: _saving || _type == null ? null : () => unawaited(_save()),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: _title,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              FushiIconButton(
                key: _saveItem.key,
                icon: _saveItem.icon,
                tooltip: _saveItem.label,
                enabled: _saveItem.onPressed != null,
                onTap: _saveItem.onPressed,
              ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
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
        title: _title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[_saveItem],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final Object? error = _error;
    final SrsNoteTypeView? type = _type;
    if (error != null || type == null) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            detail: error == null ? null : '$error',
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final (List<SrsFieldDef> primary, List<SrsFieldDef> rest) = _splitFields(
      type,
    );
    final SrsNoteView? note = _note;
    final List<Widget> sections = <Widget>[
      if (note != null && note.deletedAt != null) _buildDeletedBanner(note),
      _buildPickers(context, type),
      FushiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap * 1.5,
          children: <Widget>[
            for (final SrsFieldDef f in primary) _buildField(context, f),
          ],
        ),
      ),
      if (rest.isNotEmpty)
        FushiCard(
          padding: EdgeInsets.zero,
          child: FushiExpansionTile(
            key: const ValueKey<String>('srs-note-more-fields'),
            leading: const FushiIcon(FushiIcons.expandMore),
            title: Text(t.srs_note_more_fields(n: rest.length)),
            // 折起来的字段也要保住输入框状态（光标 / 撤销栈）。
            maintainState: true,
            childrenPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            children: <Widget>[
              for (final SrsFieldDef f in rest)
                Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap * 1.5),
                  child: _buildField(context, f),
                ),
            ],
          ),
        ),
      FushiCard(
        child: FushiTextField(
          key: const ValueKey<String>('srs-note-tags'),
          controller: _tags,
          labelText: t.srs_note_tags,
          helperText: t.srs_note_tags_hint,
        ),
      ),
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: sections.length,
        separatorBuilder: (BuildContext context, int index) =>
            SizedBox(height: tokens.spacing.gap * 1.5),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => sections[index],
        ),
      ),
    );
  }

  Widget _buildDeletedBanner(SrsNoteView note) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool pending = note.hasPendingDecision;
    return FushiCard(
      key: const ValueKey<String>('srs-note-deleted-banner'),
      tone: FushiCardTone.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            pending ? t.srs_note_delete_conflict : t.srs_note_deleted,
            style: context.fushiType.bodyLargeEmphasized,
          ),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            alignment: WrapAlignment.end,
            children: <Widget>[
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('srs-note-restore'),
                onPressed: () =>
                    srsRunLogged('SrsNoteEditor.restore', _restore),
                icon: const FushiIcon(FushiIcons.restoreBackup),
                label: Text(t.srs_note_restore),
              ),
              if (pending)
                FushiOutlinedButton.icon(
                  key: const ValueKey<String>('srs-note-confirm-delete'),
                  onPressed: () =>
                      srsRunLogged('SrsNoteEditor.delete', _confirmDelete),
                  icon: const FushiIcon(FushiIcons.delete),
                  label: Text(t.srs_note_confirm_delete),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPickers(BuildContext context, SrsNoteTypeView type) {
    final String deckName =
        _decks
            .where((SrsDeckSummary d) => d.deck.id == _deckId)
            .firstOrNull
            ?.fullName ??
        '';
    return FushiCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          FushiListItem(
            key: const ValueKey<String>('srs-note-type-row'),
            leading: const FushiListLeadingIcon(FushiIcons.ankiCard),
            title: Text(t.srs_note_type),
            subtitle: Text(type.name),
            // 已有笔记的类型不可改（卡片由类型模板派生，换类型等于换一批卡）。
            onTap: _editing ? null : () => unawaited(_pickType()),
            trailing: _editing
                ? null
                : const FushiIcon(FushiIcons.chevronRight),
          ),
          FushiListItem(
            key: const ValueKey<String>('srs-note-deck-row'),
            leading: const FushiListLeadingIcon(FushiIcons.collection),
            title: Text(t.srs_note_deck),
            subtitle: Text(deckName),
            onTap: () => unawaited(_pickDeck()),
            trailing: const FushiIcon(FushiIcons.chevronRight),
          ),
        ],
      ),
    );
  }

  Widget _buildField(BuildContext context, SrsFieldDef field) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsRegister? reg = _note?.edits[SrsFieldKeys.noteField(field.id)];
    final List<String> candidates = reg == null || !reg.conflicted
        ? const <String>[]
        : <String>{
            for (final SrsFieldEdit e in reg.live)
              e.value is String ? e.value! as String : '',
          }.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        FushiTextField(
          key: ValueKey<String>('srs-field-${field.name}'),
          controller: _fields[field.id],
          labelText: field.name,
          minLines: 1,
          maxLines: 6,
          onChanged: (_) => setState(() {}),
        ),
        if (candidates.isNotEmpty) ...<Widget>[
          Text(
            t.srs_note_field_conflict,
            style: context.fushiType.labelMedium.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap / 2,
            children: <Widget>[
              for (final String value in candidates)
                FushiChoiceChip(
                  label: Text(
                    value.isEmpty ? '—' : value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: false,
                  tooltip: t.srs_note_use_candidate,
                  onSelected: (_) => srsRunLogged(
                    'SrsNoteEditor.candidate',
                    () => _pickCandidate(field, value),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
