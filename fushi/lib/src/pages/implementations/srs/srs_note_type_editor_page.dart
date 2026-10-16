/// 一个笔记类型的编辑页：名字 / 词条字段、字段（增删改名调序）、卡片模板（增删改名调序、
/// 点进模板编辑器）、共享样式入口；并发冲突（两台设备同时改了同一项定义）在顶部给出候选。
///
/// 每个操作即时写一条修改记录（铁律 H）。删字段会丢内容、删模板会删卡，都先确认并给出影响数。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_note_types_page.dart'
    show srsNameProblemText;
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

enum _ItemAction { rename, moveUp, moveDown, delete }

class SrsNoteTypeEditorPage extends ConsumerStatefulWidget {
  const SrsNoteTypeEditorPage({super.key, required this.noteTypeId});

  final String noteTypeId;

  @override
  ConsumerState<SrsNoteTypeEditorPage> createState() =>
      _SrsNoteTypeEditorPageState();
}

class _SrsNoteTypeEditorPageState extends ConsumerState<SrsNoteTypeEditorPage> {
  SrsDbStore? _store;
  SrsNoteTypeView? _type;
  List<SrsNoteTypeView> _all = const <SrsNoteTypeView>[];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final SrsNoteTypeView? type = await store.noteType(widget.noteTypeId);
      if (type == null) throw StateError('note type not found');
      final List<SrsNoteTypeView> all = await store.noteTypes();
      if (!mounted) return;
      setState(() {
        _store = store;
        _type = type;
        _all = all;
        _loading = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsNoteTypeEditor.load', e, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  /// 写操作统一入口：执行 → 刷新信号 → 重读；失败给提示并记日志。
  void _run(String where, Future<void> Function(SrsDbStore store) body) {
    final SrsDbStore? store = _store;
    if (store == null) return;
    unawaited(() async {
      try {
        await body(store);
        if (!mounted) return;
        bumpSrsRevision(ref);
        await _reload();
      } catch (e, stack) {
        ErrorLogService.instance.log(where, e, stack);
        FushiToast.show(
          msg: t.srs_action_failed,
          severity: ToastSeverity.error,
        );
      }
    }());
  }

  // ------------------------------------------------------------------ 名字 / 词条字段

  Future<void> _rename(SrsNoteTypeView type) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.srs_note_types_rename,
      labelText: t.srs_key_name,
      initialValue: type.name,
      icon: FushiIcons.rename,
      validator: (String v) => srsNameProblemText(
        srsValidatePlainName(v, <String>[
          for (final SrsNoteTypeView o in _all)
            if (o.id != type.id) o.name,
        ]),
      ),
    );
    if (name == null || name == type.name) return;
    _run(
      'SrsNoteTypeEditor.rename',
      (SrsDbStore s) => s.renameNoteType(type.id, name),
    );
  }

  Future<void> _pickTermField(SrsNoteTypeView type) async {
    const String none = '';
    final String? id = await showFushiChoiceDialog<String>(
      context: context,
      title: t.srs_note_types_term_field,
      message: t.srs_note_types_term_field_hint,
      icon: FushiIcons.lookup,
      selected: type.termFieldId ?? none,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: none,
          label: t.srs_note_types_term_field_none,
        ),
        for (final SrsFieldDef f in type.fields)
          FushiChoiceOption<String>(value: f.id, label: f.name),
      ],
    );
    if (id == null || id == (type.termFieldId ?? none)) return;
    _run(
      'SrsNoteTypeEditor.termField',
      (SrsDbStore s) => s.setTermField(type.id, id == none ? null : id),
    );
  }

  // ------------------------------------------------------------------ 字段

  String? _validateField(
    SrsNoteTypeView type,
    String value, {
    String? exceptId,
  }) => srsNameProblemText(
    srsValidateFieldName(value, <String>[
      for (final SrsFieldDef f in type.fields)
        if (f.id != exceptId) f.name,
    ]),
  );

  Future<void> _addField(SrsNoteTypeView type) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.srs_note_types_field_add,
      labelText: t.srs_note_types_field_name,
      icon: FushiIcons.textFields,
      validator: (String v) => _validateField(type, v),
    );
    if (name == null) return;
    _run(
      'SrsNoteTypeEditor.addField',
      (SrsDbStore s) => s.addField(type.id, name),
    );
  }

  Future<void> _onFieldAction(
    SrsNoteTypeView type,
    SrsFieldDef field,
    _ItemAction action,
  ) async {
    final List<String> order = <String>[
      for (final SrsFieldDef f in type.fields) f.id,
    ];
    final int i = order.indexOf(field.id);
    switch (action) {
      case _ItemAction.rename:
        final String? name = await showFushiTextInputDialog(
          context: context,
          title: t.srs_note_types_field_rename,
          labelText: t.srs_note_types_field_name,
          initialValue: field.name,
          icon: FushiIcons.rename,
          validator: (String v) => _validateField(type, v, exceptId: field.id),
        );
        if (name == null || name == field.name) return;
        _run(
          'SrsNoteTypeEditor.renameField',
          (SrsDbStore s) => s.renameField(type.id, field.id, name),
        );
      case _ItemAction.moveUp:
      case _ItemAction.moveDown:
        final int j = action == _ItemAction.moveUp ? i - 1 : i + 1;
        if (j < 0 || j >= order.length) return;
        order
          ..removeAt(i)
          ..insert(j, field.id);
        _run(
          'SrsNoteTypeEditor.reorderFields',
          (SrsDbStore s) => s.reorderFields(type.id, order),
        );
      case _ItemAction.delete:
        final SrsDbStore? store = _store;
        if (store == null) return;
        if (type.fields.length <= 1) {
          FushiToast.show(msg: t.srs_note_types_field_last);
          return;
        }
        final int n = await store.notesWithFieldContent(type.id, field.id);
        if (!mounted) return;
        final bool ok = await showFushiConfirmDialog(
          context: context,
          title: t.srs_note_types_field_delete,
          message: t.srs_note_types_field_delete_confirm(
            name: field.name,
            n: n,
          ),
          confirmLabel: t.srs_note_types_field_delete,
          cancelLabel: t.cancel,
          icon: FushiIcons.delete,
          destructive: true,
        );
        if (!ok) return;
        _run(
          'SrsNoteTypeEditor.deleteField',
          (SrsDbStore s) => s.deleteField(type.id, field.id),
        );
    }
  }

  // ------------------------------------------------------------------ 模板

  Future<void> _openTemplate(
    SrsNoteTypeView type,
    String templateId, {
    SrsTemplateEditorTab tab = SrsTemplateEditorTab.front,
  }) async {
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => SrsTemplateEditorPage(
          noteTypeId: type.id,
          templateId: templateId,
          initialTab: tab,
        ),
      ),
    );
    if (!mounted) return;
    bumpSrsRevision(ref);
    await _reload();
  }

  String? _validateTemplate(
    SrsNoteTypeView type,
    String value, {
    String? exceptId,
  }) => srsNameProblemText(
    srsValidatePlainName(value, <String>[
      for (final SrsTemplateDef x in type.templates)
        if (x.id != exceptId) x.name,
    ]),
  );

  Future<void> _addTemplate(SrsNoteTypeView type) async {
    if (type.isCloze) {
      FushiToast.show(msg: t.srs_note_types_template_cloze_single);
      return;
    }
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.srs_note_types_template_add,
      labelText: t.srs_note_types_template_name,
      initialValue: _nextCardName(type),
      icon: FushiIcons.ankiCard,
      validator: (String v) => _validateTemplate(type, v),
    );
    final SrsDbStore? store = _store;
    if (name == null || store == null) return;
    // 与 Anki 一样，新模板从第一个模板复制正文，再按需修改。
    final SrsTemplateDef? first = type.templates.firstOrNull;
    try {
      final String id = await store.addTemplate(
        type.id,
        name: name,
        front: first?.front ?? '',
        back: first?.back ?? '',
      );
      if (!mounted) return;
      bumpSrsRevision(ref);
      await _reload();
      if (mounted) await _openTemplate(_type ?? type, id);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsNoteTypeEditor.addTemplate', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    }
  }

  String _nextCardName(SrsNoteTypeView type) {
    for (int i = type.templates.length + 1; i < 100; i++) {
      final String n = 'Card $i';
      if (_validateTemplate(type, n) == null) return n;
    }
    return '';
  }

  Future<void> _onTemplateAction(
    SrsNoteTypeView type,
    SrsTemplateDef tpl,
    _ItemAction action,
  ) async {
    final List<String> order = <String>[
      for (final SrsTemplateDef x in type.templates) x.id,
    ];
    final int i = order.indexOf(tpl.id);
    switch (action) {
      case _ItemAction.rename:
        final String? name = await showFushiTextInputDialog(
          context: context,
          title: t.srs_note_types_template_rename,
          labelText: t.srs_note_types_template_name,
          initialValue: tpl.name,
          icon: FushiIcons.rename,
          validator: (String v) => _validateTemplate(type, v, exceptId: tpl.id),
        );
        if (name == null || name == tpl.name) return;
        _run(
          'SrsNoteTypeEditor.renameTemplate',
          (SrsDbStore s) => s.updateTemplate(type.id, tpl.id, name: name),
        );
      case _ItemAction.moveUp:
      case _ItemAction.moveDown:
        final int j = action == _ItemAction.moveUp ? i - 1 : i + 1;
        if (j < 0 || j >= order.length) return;
        order
          ..removeAt(i)
          ..insert(j, tpl.id);
        _run(
          'SrsNoteTypeEditor.reorderTemplates',
          (SrsDbStore s) => s.reorderTemplates(type.id, order),
        );
      case _ItemAction.delete:
        final SrsDbStore? store = _store;
        if (store == null) return;
        if (type.templates.length <= 1) {
          FushiToast.show(msg: t.srs_note_types_template_last);
          return;
        }
        final int n = await store.visibleCardsOfTemplate(tpl.id);
        if (!mounted) return;
        final bool ok = await showFushiConfirmDialog(
          context: context,
          title: t.srs_note_types_template_delete,
          message: t.srs_note_types_template_delete_confirm(
            name: tpl.name,
            n: n,
          ),
          confirmLabel: t.srs_note_types_template_delete,
          cancelLabel: t.cancel,
          icon: FushiIcons.delete,
          destructive: true,
        );
        if (!ok) return;
        _run(
          'SrsNoteTypeEditor.deleteTemplate',
          (SrsDbStore s) => s.deleteTemplate(type.id, tpl.id),
        );
    }
  }

  // ------------------------------------------------------------------ 冲突

  String _registerLabel(SrsNoteTypeView type, SrsRegister reg) {
    if (reg.key == SrsFieldKeys.css) return t.srs_note_types_styling;
    if (reg.key.startsWith('fieldDef/')) {
      final Object? v = reg.value;
      return v is Map && v['name'] is String
          ? '${t.srs_note_types_fields} · ${v['name']}'
          : t.srs_note_types_fields;
    }
    if (reg.key.startsWith('tmplDef/')) {
      final Object? v = reg.value;
      return v is Map && v['name'] is String
          ? '${t.srs_note_types_templates} · ${v['name']}'
          : t.srs_note_types_templates;
    }
    return srsFieldKeyLabel(SrsEntityKind.noteType, reg.key);
  }

  Widget _buildConflicts(BuildContext context, SrsNoteTypeView type) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsRegister> regs = type.edits.conflicted.toList();
    return FushiCard(
      key: const ValueKey<String>('srs-note-type-conflicts'),
      tone: FushiCardTone.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            t.srs_note_types_conflict,
            style: context.fushiType.bodyLargeEmphasized,
          ),
          for (final SrsRegister reg in regs) ...<Widget>[
            Text(
              _registerLabel(type, reg),
              style: context.fushiType.labelLarge,
            ),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap / 2,
              children: <Widget>[
                for (final SrsFieldEdit e in reg.live)
                  FushiChoiceChip(
                    label: Text(
                      t.srs_conflict_from(
                        device: srsShortDevice(e.dot.writerId),
                        time: srsFormatMoment(e.hlc.physical),
                      ),
                    ),
                    selected: identical(e, reg.winner),
                    tooltip: t.srs_note_use_candidate,
                    onSelected: (_) => _run(
                      'SrsNoteTypeEditor.resolve',
                      (SrsDbStore s) => s.resolveConflict(
                        SrsEntityKind.noteType,
                        type.id,
                        reg.key,
                        e.value,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final String title = _type?.name ?? t.srs_note_types_title;
    return FushiPageScaffold(
      title: title,
      header: apple ? null : _buildTopBar(context, title),
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context, String title) {
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
        title: title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final SrsNoteTypeView? type = _type;
    final SrsDbStore? store = _store;
    if (_error != null || type == null || store == null) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            detail: _error == null ? null : '$_error',
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String termName =
        type.fields
            .where((SrsFieldDef f) => f.id == type.termFieldId)
            .firstOrNull
            ?.name ??
        t.srs_note_types_term_field_none;
    // 宽窗（手机横屏 / 桌面）：左栏类型属性、卡片模板与样式，右栏（通常最长的）
    // 字段列表，两栏各自滚动；窄窗仍是原顺序单列。
    final List<SrsSection> sections = <SrsSection>[
      if (type.builtinKey != null)
        SrsSection(
          FushiCard(
            key: const ValueKey<String>('srs-note-type-builtin-hint'),
            tone: FushiCardTone.primary,
            child: Row(
              spacing: tokens.spacing.gap * 1.5,
              children: <Widget>[
                const FushiIcon(FushiIcons.info),
                Expanded(child: Text(t.srs_note_types_builtin_hint)),
              ],
            ),
          ),
        ),
      if (type.edits.conflicted.isNotEmpty)
        SrsSection(_buildConflicts(context, type)),
      SrsSection(
        FushiCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              FushiListItem(
                key: const ValueKey<String>('srs-note-type-name-row'),
                leading: const FushiListLeadingIcon(FushiIcons.ankiCard),
                title: Text(t.srs_key_name),
                subtitle: Text(type.name),
                onTap: () => srsRunLogged(
                  'SrsNoteTypeEditor.rename',
                  () => _rename(type),
                ),
                trailing: const FushiIcon(FushiIcons.rename),
              ),
              FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.info),
                title: Text(t.srs_note_types_kind),
                subtitle: Text(
                  type.isCloze
                      ? t.srs_note_types_kind_cloze
                      : t.srs_note_types_kind_standard,
                ),
              ),
              FushiListItem(
                key: const ValueKey<String>('srs-note-type-term-row'),
                leading: const FushiListLeadingIcon(FushiIcons.lookup),
                title: Text(t.srs_note_types_term_field),
                subtitle: Text(termName),
                onTap: () => srsRunLogged(
                  'SrsNoteTypeEditor.termField',
                  () => _pickTermField(type),
                ),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ],
          ),
        ),
      ),
      SrsSection(
        pane: SrsPane.secondary,
        _Section(
          title: t.srs_note_types_fields,
          addKey: const ValueKey<String>('srs-note-type-add-field'),
          addLabel: t.srs_note_types_field_add,
          onAdd: () =>
              srsRunLogged('SrsNoteTypeEditor.addField', () => _addField(type)),
          children: <Widget>[
            for (int i = 0; i < type.fields.length; i++)
              _ItemRow(
                key: ValueKey<String>(
                  'srs-note-type-field-${type.fields[i].name}',
                ),
                icon: FushiIcons.textFields,
                title: type.fields[i].name,
                renameLabel: t.srs_note_types_field_rename,
                deleteLabel: t.srs_note_types_field_delete,
                subtitle: store.isBuiltinField(type, type.fields[i].id)
                    ? t.srs_note_types_field_builtin
                    : null,
                canMoveUp: i > 0,
                canMoveDown: i < type.fields.length - 1,
                canDelete:
                    type.fields.length > 1 &&
                    !store.isBuiltinField(type, type.fields[i].id),
                onAction: (_ItemAction a) => srsRunLogged(
                  'SrsNoteTypeEditor.field',
                  () => _onFieldAction(type, type.fields[i], a),
                ),
              ),
          ],
        ),
      ),
      SrsSection(
        _Section(
          title: t.srs_note_types_templates,
          addKey: const ValueKey<String>('srs-note-type-add-template'),
          addLabel: t.srs_note_types_template_add,
          onAdd: type.isCloze
              ? null
              : () => srsRunLogged(
                  'SrsNoteTypeEditor.addTemplate',
                  () => _addTemplate(type),
                ),
          children: <Widget>[
            for (int i = 0; i < type.templates.length; i++)
              _ItemRow(
                key: ValueKey<String>(
                  'srs-note-type-template-${type.templates[i].name}',
                ),
                icon: FushiIcons.ankiCard,
                title: type.templates[i].name,
                renameLabel: t.srs_note_types_template_rename,
                deleteLabel: t.srs_note_types_template_delete,
                onTap: () => srsRunLogged(
                  'SrsNoteTypeEditor.openTemplate',
                  () => _openTemplate(type, type.templates[i].id),
                ),
                canMoveUp: i > 0,
                canMoveDown: i < type.templates.length - 1,
                canDelete: type.templates.length > 1,
                onAction: (_ItemAction a) => srsRunLogged(
                  'SrsNoteTypeEditor.template',
                  () => _onTemplateAction(type, type.templates[i], a),
                ),
              ),
          ],
        ),
      ),
      SrsSection(
        FushiCard(
          padding: EdgeInsets.zero,
          child: FushiListItem(
            key: const ValueKey<String>('srs-note-type-styling-row'),
            leading: const FushiListLeadingIcon(FushiIcons.code),
            title: Text(t.srs_note_types_styling),
            subtitle: Text(t.srs_note_types_styling_hint),
            onTap: type.templates.isEmpty
                ? null
                : () => srsRunLogged(
                    'SrsNoteTypeEditor.styling',
                    () => _openTemplate(
                      type,
                      type.templates.first.id,
                      tab: SrsTemplateEditorTab.styling,
                    ),
                  ),
            trailing: const FushiIcon(FushiIcons.chevronRight),
          ),
        ),
      ),
    ];
    return SrsAdaptiveSections(sections: sections);
  }
}

/// 一组（字段 / 卡片模板）：标题 + 行 + 「添加」按钮。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.addKey,
    required this.addLabel,
    required this.onAdd,
    required this.children,
  });

  final String title;
  final Key addKey;
  final String addLabel;
  final VoidCallback? onAdd;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card,
              tokens.spacing.card,
              tokens.spacing.gap / 2,
            ),
            child: Text(title, style: context.fushiType.titleSmall),
          ),
          ...children,
          Padding(
            padding: EdgeInsets.all(tokens.spacing.gap),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FushiFilledButton.tonalIcon(
                key: addKey,
                onPressed: onAdd,
                icon: const FushiIcon(FushiIcons.add),
                label: Text(addLabel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.icon,
    required this.title,
    required this.renameLabel,
    required this.deleteLabel,
    this.subtitle,
    this.onTap,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.canDelete,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String renameLabel;
  final String deleteLabel;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool canMoveUp;
  final bool canMoveDown;
  final bool canDelete;
  final void Function(_ItemAction action) onAction;

  @override
  Widget build(BuildContext context) => FushiListItem(
    leading: FushiListLeadingIcon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    onTap: onTap,
    trailing: FushiPopupMenuButton<_ItemAction>(
      tooltip: t.srs_deck_menu,
      icon: const FushiIcon(FushiIcons.more),
      onSelected: onAction,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_ItemAction>>[
        PopupMenuItem<_ItemAction>(
          value: _ItemAction.rename,
          child: Text(renameLabel),
        ),
        if (canMoveUp)
          PopupMenuItem<_ItemAction>(
            value: _ItemAction.moveUp,
            child: Text(t.srs_note_types_move_up),
          ),
        if (canMoveDown)
          PopupMenuItem<_ItemAction>(
            value: _ItemAction.moveDown,
            child: Text(t.srs_note_types_move_down),
          ),
        if (canDelete)
          PopupMenuItem<_ItemAction>(
            value: _ItemAction.delete,
            child: Text(deleteLabel),
          ),
      ],
    ),
  );
}
