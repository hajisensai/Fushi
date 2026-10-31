/// 复习笔记编辑页（新建 / 编辑）。
///
/// - 新建：选笔记类型（默认 Lapis）与牌组，逐字段填写；添加后清空字段继续添加。
/// - 编辑：类型行进入「更改笔记类型」（[showSrsChangeNoteTypeFlow]）。字段有同步冲突（两台设备同时改了同一字段）时，在该字段下列出各候选值，
///   点选即写入一条新修改记录，冲突随之消失。笔记处于「删除与并发修改」待裁决时
///   顶部给出「恢复 / 确认删除」。
/// - 字段按内容类型可视化编辑（富文本 / 结构化预览 / 振假名 / 图片 / 音频 / 开关，见
///   srs_field_editors.dart），每个字段可切 HTML 源码（Ctrl+Shift+X）。
/// - Lapis 字段多：常用的 Expression / ExpressionReading / MainDefinition / Sentence
///   放前面，其余折进「更多字段」。Fushi 卡片按卡面区块（[FushiCardBlock]）分组，
///   常用字段在前，其余进「更多字段」（同样按区块分组）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show
        FushiCardBlock,
        FushiCardFields,
        kFushiCardBackBlocks,
        kFushiCardSwitchFields;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi/src/srs/srs_app_host.dart' show srsInheritProviderScope;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/srs/srs_edit_history_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_label.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';
import 'package:fushi/src/srs/srs_field_catalog.dart' as catalog;
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
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
  List<SrsDeckChoice> _decks = const <SrsDeckChoice>[];
  SrsNoteTypeView? _type;
  String? _deckId;
  SrsNoteView? _note;

  /// fieldId → 字段值。换笔记类型时按字段名搬值。
  final Map<String, SrsFieldModel> _fields = <String, SrsFieldModel>{};
  final TextEditingController _tags = TextEditingController();

  bool get _editing => widget.noteId != null;

  /// fieldId → 制卡映射（ⓘ 里的「制卡时自动填入」）；按笔记类型缓存，换类型清空。
  Map<String, String>? _miningSlots;

  /// 预览常驻在宽窗右栏、且一屏看得到（不是横屏手机那种矮窗）；否则顶栏多一个「预览」
  /// 打开底部抽屉。
  bool _inlinePreview = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final SrsFieldModel m in _fields.values) {
      m.dispose();
    }
    _tags.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final List<SrsNoteTypeView> types = await store.noteTypes();
      // 只取牌组名：deckSummaries 会对 RWKV 牌组全量推理，编辑页打开会很慢。
      final List<SrsDeckChoice> decks = await srsDeckChoices(store);
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
          f.name: _fields[f.id]?.value ?? '',
    };
    final List<SrsFieldModel> old = _fields.values.toList();
    // 旧字段的编辑器本帧还在树上（换下来时要摘监听）：下一帧再释放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final SrsFieldModel m in old) {
        m.dispose();
      }
    });
    _fields.clear();
    _type = type;
    _miningSlots = null;
    if (type == null) return;
    for (final SrsFieldDef f in type.fields) {
      _fields[f.id] = SrsFieldModel(from?.field(f.id) ?? byName[f.name] ?? '');
    }
  }

  /// 常用字段在前，其余进「更多字段」。返回两组（各自按小标题分组；标题 null = 不分组）。
  ///
  /// - Fushi 卡片：按卡面区块（[FushiCardBlock]，与复习页 / 导出模板同一真相源）分组，
  ///   [kSrsFushiCardPrimaryFields] 在前；卡型开关与其余字段放「更多字段」末尾。
  /// - Lapis：[kSrsLapisPrimaryFields] 在前，其余按字段顺序。
  /// - 其它类型：全部按字段顺序，不折叠。
  (List<_FieldGroup>, List<_FieldGroup>) _splitFields(SrsNoteTypeView type) {
    if (type.builtinKey == kSrsBuiltinFushiCardKey) {
      final List<_FieldGroup> groups = <_FieldGroup>[];
      final Set<String> placed = <String>{};
      // 按改名后的字段键分组：字段定义修改记录（调序 / 改名）里存的还是旧名（Expression /
      // Picture …）时也落到同一组，不被甩进「更多字段」。
      String key(SrsFieldDef f) => FushiCardFields.canonical(f.name);
      List<SrsFieldDef> named(Iterable<String> names) => <SrsFieldDef>[
        for (final String name in names)
          ...type.fields.where((SrsFieldDef f) => key(f) == name),
      ];
      for (final FushiCardBlock b in kFushiCardBackBlocks) {
        final List<SrsFieldDef> fields = named(b.fields);
        placed.addAll(b.fields);
        if (fields.isNotEmpty) groups.add((_blockLabel(b), fields));
      }
      final List<SrsFieldDef> switches = named(kFushiCardSwitchFields);
      placed.addAll(kFushiCardSwitchFields);
      final List<SrsFieldDef> others = type.fields
          .where((SrsFieldDef f) => !placed.contains(key(f)))
          .toList();
      final List<_FieldGroup> primary = <_FieldGroup>[];
      final List<_FieldGroup> rest = <_FieldGroup>[];
      for (final _FieldGroup g in groups) {
        final List<SrsFieldDef> head = g.$2
            .where(
              (SrsFieldDef f) => kSrsFushiCardPrimaryFields.contains(key(f)),
            )
            .toList();
        final List<SrsFieldDef> tail = g.$2
            .where(
              (SrsFieldDef f) => !kSrsFushiCardPrimaryFields.contains(key(f)),
            )
            .toList();
        if (head.isNotEmpty) primary.add((g.$1, head));
        if (tail.isNotEmpty) rest.add((g.$1, tail));
      }
      if (switches.isNotEmpty) {
        rest.add((t.srs_note_block_card_type, switches));
      }
      if (others.isNotEmpty) rest.add((t.srs_note_block_other, others));
      return (primary, rest);
    }
    if (type.builtinKey != kSrsBuiltinLapisKey) {
      return (<_FieldGroup>[(null, type.fields)], const <_FieldGroup>[]);
    }
    final List<SrsFieldDef> primary = <SrsFieldDef>[
      for (final String name in kSrsLapisPrimaryFields)
        ...type.fields.where((SrsFieldDef f) => f.name == name),
    ];
    final List<SrsFieldDef> rest = type.fields
        .where((SrsFieldDef f) => !kSrsLapisPrimaryFields.contains(f.name))
        .toList();
    return (
      <_FieldGroup>[(null, primary)],
      <_FieldGroup>[if (rest.isNotEmpty) (null, rest)],
    );
  }

  static String _blockLabel(FushiCardBlock b) => switch (b) {
    FushiCardBlock.term => t.srs_note_block_term,
    FushiCardBlock.reading => t.srs_note_block_reading,
    FushiCardBlock.picture => t.srs_note_block_picture,
    FushiCardBlock.sentence => t.srs_note_block_sentence,
    FushiCardBlock.definitions => t.srs_note_block_definitions,
    FushiCardBlock.frequency => t.srs_note_block_frequency,
    FushiCardBlock.source => t.srs_note_block_source,
  };

  /// 一列分组字段：组标题（有的话）+ 字段，组与组之间多空一点。
  List<Widget> _groupedFields(
    BuildContext context,
    SrsNoteTypeView type,
    List<_FieldGroup> groups,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return <Widget>[
      for (int g = 0; g < groups.length; g++) ...<Widget>[
        if (groups[g].$1 != null)
          Padding(
            padding: EdgeInsets.only(top: g == 0 ? 0 : tokens.spacing.gap),
            child: Text(
              groups[g].$1!,
              key: ValueKey<String>('srs-note-group-${groups[g].$1}'),
              style: context.fushiType.titleSmall.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        for (final SrsFieldDef f in groups[g].$2) _buildField(context, type, f),
      ],
    ];
  }

  List<String> _parseTags() => _tags.text
      .split(RegExp(r'\s+'))
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toSet()
      .toList();

  bool get _hasContent =>
      _fields.values.any((SrsFieldModel m) => m.value.trim().isNotEmpty);

  Future<void> _save() async {
    final SrsDbStore? store = _store;
    final SrsNoteTypeView? type = _type;
    if (store == null || type == null || _saving || !_hasContent) return;
    setState(() => _saving = true);
    try {
      final Map<String, String> values = <String, String>{
        for (final MapEntry<String, SrsFieldModel> e in _fields.entries)
          e.key: e.value.value,
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
      for (final SrsFieldModel m in _fields.values) {
        m.reset('');
      }
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
    setState(() => _note = note);
    for (final MapEntry<String, SrsFieldModel> e in _fields.entries) {
      e.value.reset(note.field(e.key));
    }
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

  /// 已有笔记换类型：先保存未保存的字段修改（换类型按已存的值搬字段），再走映射流程，完成后重读。
  Future<void> _changeType() async {
    final String? noteId = widget.noteId;
    final SrsDbStore? store = _store;
    if (noteId == null || store == null) return;
    // 只存真改过的字段：没动过的字段若有并发冲突，照原样留给用户裁决，不被这次保存顺手覆盖。
    final SrsNoteView? note = _note;
    final Map<String, String> values = <String, String>{
      for (final MapEntry<String, SrsFieldModel> e in _fields.entries)
        if (e.value.value != (note?.field(e.key) ?? '')) e.key: e.value.value,
    };
    final List<String> tags = _parseTags();
    final bool tagsChanged = tags.join(' ') != (note?.tags.join(' ') ?? '');
    if (values.isNotEmpty || tagsChanged) {
      await store.updateNote(
        noteId,
        fieldsById: values,
        tags: tagsChanged ? tags : null,
      );
    }
    if (!mounted) return;
    final bool changed = await showSrsChangeNoteTypeFlow(context, <String>[
      noteId,
    ]);
    if (!changed || !mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _pickDeck() async {
    final String? id = await pickSrsDeckChoice(
      context,
      decks: _decks,
      selected: _deckId,
      title: t.srs_note_deck,
    );
    if (id == null || !mounted) return;
    setState(() => _deckId = id);
  }

  String get _title => _editing ? t.srs_note_edit : t.srs_note_add;

  Future<Map<String, String>> _expandForPreview(
    Map<String, String> values,
  ) async {
    final SrsDbStore? store = _store;
    if (store == null) return values;
    return store.expandFields(values, dropMissing: true);
  }

  Future<void> _openPreview() async {
    final SrsNoteTypeView? type = _type;
    if (type == null) return;
    await showSrsNotePreviewSheet(
      context,
      type: type,
      fields: Map<String, SrsFieldModel>.of(_fields),
      expand: _expandForPreview,
      tags: _parseTags(),
    );
  }

  /// 窄窗 / 矮窗顶栏的「预览」（宽窗预览常驻右栏，不需要）。
  FushiToolbarItem? get _previewItem => _inlinePreview || _type == null
      ? null
      : FushiToolbarItem(
          key: const ValueKey<String>('srs_note_preview'),
          icon: FushiIcons.visibility,
          label: t.srs_note_types_preview,
          onPressed: () => srsRunLogged('SrsNoteEditor.preview', _openPreview),
        );

  /// 已有的笔记：顶栏「修改历史」（每个字段的每次修改，哪台设备、何时）。
  FushiToolbarItem? get _historyItem => !_editing || _note == null
      ? null
      : FushiToolbarItem(
          key: const ValueKey<String>('srs_note_history'),
          icon: FushiIcons.history,
          label: t.srs_note_history,
          onPressed: () => srsRunLogged(
            'SrsNoteEditor.history',
            () => Navigator.of(context).push<void>(
              adaptivePageRoute<void>(
                context: context,
                builder: (_) => srsInheritProviderScope(
                  context,
                  SrsEditHistoryPage(noteId: _note!.id),
                ),
              ),
            ),
          ),
        );

  /// 已有、且没在待删除状态的笔记可以从顶栏删除。
  bool get _canDelete => _editing && _note != null && _note!.deletedAt == null;

  Future<void> _deleteWithConfirm() async {
    if (!await confirmSrsNoteDelete(context)) return;
    await _confirmDelete();
  }

  FushiToolbarItem? get _deleteItem => !_canDelete
      ? null
      : FushiToolbarItem(
          key: const ValueKey<String>('srs_note_delete'),
          icon: FushiIcons.delete,
          label: t.srs_note_delete,
          onPressed: _saving || _store == null
              ? null
              : () => srsRunLogged(
                  'SrsNoteEditor.deleteFromTopBar',
                  _deleteWithConfirm,
                ),
        );

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
              for (final FushiToolbarItem item in <FushiToolbarItem>[
                ?_previewItem,
                ?_historyItem,
                ?_deleteItem,
                _saveItem,
              ])
                FushiIconButton(
                  key: item.key,
                  icon: item.icon,
                  tooltip: item.label,
                  enabled: item.onPressed != null,
                  onTap: item.onPressed,
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
          <FushiToolbarItem>[
            ?_previewItem,
            ?_historyItem,
            ?_deleteItem,
            _saveItem,
          ],
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
    final (List<_FieldGroup> primary, List<_FieldGroup> rest) = _splitFields(
      type,
    );
    final int restCount = rest.fold(
      0,
      (int n, _FieldGroup g) => n + g.$2.length,
    );
    final SrsNoteView? note = _note;
    // 宽窗（手机横屏 / 桌面）：左栏字段（正文），右栏实时预览、删除提示、类型 / 牌组与标签；
    // 窄窗仍按 删除提示 → 类型 / 牌组 → 字段 → 更多字段 → 标签 单列，预览走顶栏抽屉。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = srsUsesTwoPane(constraints);
        final bool inline = wide && !srsIsShortLandscape(constraints);
        if (inline != _inlinePreview) {
          // 顶栏的「预览」按钮跟着变：下一帧再改，不在 build 里 setState。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _inlinePreview != inline) {
              setState(() => _inlinePreview = inline);
            }
          });
        }
        return _buildSections(
          context,
          type,
          note,
          primary,
          rest,
          restCount,
          wide,
        );
      },
    );
  }

  Widget _buildSections(
    BuildContext context,
    SrsNoteTypeView type,
    SrsNoteView? note,
    List<_FieldGroup> primary,
    List<_FieldGroup> rest,
    int restCount,
    bool wide,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsSection> sections = <SrsSection>[
      if (note != null && note.deletedAt != null)
        SrsSection(pane: SrsPane.secondary, _buildDeletedBanner(note)),
      SrsSection(pane: SrsPane.secondary, _buildPickers(context, type)),
      SrsSection(
        FushiCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spacing.gap * 1.5,
            children: _groupedFields(context, type, primary),
          ),
        ),
      ),
      if (restCount > 0)
        SrsSection(
          FushiCard(
            padding: EdgeInsets.zero,
            child: FushiExpansionTile(
              key: const ValueKey<String>('srs-note-more-fields'),
              leading: const FushiIcon(FushiIcons.expandMore),
              title: Text(t.srs_note_more_fields(n: restCount)),
              // 折起来的字段也要保住输入框状态（光标 / 撤销栈）。
              maintainState: true,
              childrenPadding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.card,
              ),
              children: <Widget>[
                for (final Widget w in _groupedFields(context, type, rest))
                  Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.gap * 1.5),
                    child: w,
                  ),
              ],
            ),
          ),
        ),
      SrsSection(
        pane: SrsPane.secondary,
        FushiCard(
          child: FushiTextField(
            key: const ValueKey<String>('srs-note-tags'),
            controller: _tags,
            labelText: t.srs_note_tags,
            helperText: t.srs_note_tags_hint,
          ),
        ),
      ),
      // 宽窗：右栏末尾常驻实时预览（类型 / 牌组 / 标签在上，横屏手机一屏仍看得到），
      // 左栏改字段右栏立即反映。
      if (wide)
        SrsSection(
          pane: SrsPane.secondary,
          FushiCard(
            child: SrsNotePreview(
              key: ValueKey<String>('srs-note-preview-${type.id}'),
              type: type,
              fields: _fields,
              expand: _expandForPreview,
              tags: _parseTags(),
              // 背面常含词典释义，固定 360 只露出头一段；随窗口高度放长。
              height: (MediaQuery.sizeOf(context).height * 0.72).clamp(
                360.0,
                780.0,
              ),
            ),
          ),
        ),
    ];
    return SrsAdaptiveSections(
      sections: sections,
      primaryFlex: 3,
      secondaryFlex: 2,
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
            .where((SrsDeckChoice d) => d.id == _deckId)
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
            // 已有笔记：走「更改笔记类型」（字段 / 卡片映射，卡片带着复习历史过去）。
            onTap: _editing
                ? () => srsRunLogged('SrsNoteEditor.changeType', _changeType)
                : () => unawaited(_pickType()),
            trailing: const FushiIcon(FushiIcons.chevronRight),
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

  /// 字段「AI 改写 / 补全」：先确认有指派的提供商（没有就一个请求都不发），结果只回草稿。
  Future<void> _fieldAi(SrsNoteTypeView type, SrsFieldDef field) async {
    final SrsFieldModel? model = _fields[field.id];
    if (model == null) return;
    final AiProviderConfig? provider = ref
        .read(appProvider)
        .prefsRepo
        .resolveAiFeatureProvider(AiFeature.srsNoteField);
    if (provider == null) {
      FushiToast.show(msg: t.ai_assist_no_provider);
      return;
    }
    final String? value = await showSrsFieldAiSheet(
      context,
      fieldLabel: catalog.srsFieldDisplayName(field),
      fieldName: field.name,
      current: model.value,
      run: (AiSrsFieldTask task, String instruction) async {
        final AiChatClient client = AiChatClient();
        try {
          return await requestAiSrsField(
            client: client,
            provider: provider,
            noteType: type,
            valuesById: <String, String>{
              for (final MapEntry<String, SrsFieldModel> e in _fields.entries)
                e.key: e.value.value,
            },
            targetFieldId: field.id,
            task: task,
            instruction: instruction,
            outputLanguage: LocaleSettings.currentLocale.languageTag,
          );
        } finally {
          client.close();
        }
      },
    );
    if (value == null || !mounted) return;
    // 整体换值：编辑器按新内容重新判类型（AI 可能写出列表等结构化内容）。
    _fields[field.id]?.reset(value);
  }

  /// 字段标题行的「AI」按钮：AI 模块开着、且字段装的是文字（不是图片 / 音频 / 开关 / 数据）。
  List<Widget> _fieldActions(SrsNoteTypeView type, SrsFieldDef field) {
    if (!isAiModuleEnabled(ref.watch(appProvider).moduleVisibility)) {
      return const <Widget>[];
    }
    final catalog.SrsFieldKind kind = catalog.srsFieldKind(field);
    if (kind != catalog.SrsFieldKind.text &&
        kind != catalog.SrsFieldKind.rich) {
      return const <Widget>[];
    }
    return <Widget>[
      FushiIconButton(
        key: ValueKey<String>('srs-field-ai-${field.name}'),
        icon: FushiIcons.aiAssistant,
        size: 20,
        tooltip: t.srs_note_field_ai,
        onTap: () =>
            srsRunLogged('SrsNoteEditor.fieldAi', () => _fieldAi(type, field)),
      ),
    ];
  }

  Map<String, String> _miningSlotsOf(SrsNoteTypeView type) {
    final SrsDbStore? store = _store;
    if (store == null) return const <String, String>{};
    return _miningSlots ??= srsMiningFieldMappingsFor(
      type: type,
      builtinKey: type.builtinKey,
      profileUid: store.profileUid,
      stored: ref
          .read(appProvider)
          .srsMiningDestination
          .fieldMappingsByType[type.id],
    );
  }

  Widget _buildField(
    BuildContext context,
    SrsNoteTypeView type,
    SrsFieldDef field,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsRegister? reg = _note?.edits[SrsFieldKeys.noteField(field.id)];
    final List<String> candidates = reg == null || !reg.conflicted
        ? const <String>[]
        : <String>{
            for (final SrsFieldEdit e in reg.live)
              e.value is String ? e.value! as String : '',
          }.toList();
    final bool builtin = srsBuiltinNoteTypeSpec(type.builtinKey) != null;
    final Widget? conflicts = candidates.isEmpty
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spacing.gap / 2,
            children: <Widget>[
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
          );
    return SrsFieldEditor(
      key: ValueKey<String>('srs-field-${field.name}'),
      name: field.name,
      help: SrsFieldHelp.of(field, miningSlot: _miningSlotsOf(type)[field.id]),
      headerActions: _fieldActions(type, field),
      model: _fields[field.id]!,
      toggle: builtin && kFushiCardSwitchFields.contains(field.name),
      css: type.css,
      fushiCard: type.builtinKey == kSrsBuiltinFushiCardKey,
      footer: conflicts,
    );
  }
}

/// 编辑页的一组字段：组标题（null = 不显示）+ 字段。
typedef _FieldGroup = (String?, List<SrsFieldDef>);
