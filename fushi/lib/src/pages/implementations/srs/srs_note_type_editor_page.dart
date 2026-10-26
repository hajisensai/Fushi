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
import 'package:fushi/src/pages/implementations/srs/srs_field_info_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_visual_template_panel.dart'
    show srsFieldKindIcon;
import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/srs/srs_visual_template.dart'
    show srsVisualTemplateWithoutField;
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
          FushiChoiceOption<String>(value: f.id, label: _fieldTitle(f)),
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

  /// 字段行标题：已知字段显示人话名字并带上真实字段名（模板 / Anki 里认的是后者）。
  static String _fieldTitle(SrsFieldDef f) {
    final String display = srsFieldDisplayName(f);
    return display == f.name ? f.name : '$display · ${f.name}';
  }

  /// 字段行副标题：说明（用户写的优先，其次内置说明）；内置 / 查词等标记另作标签。
  static String? _fieldSubtitle(SrsFieldDef f) {
    final String description = srsFieldDisplayDescription(f);
    return description.isEmpty ? null : description;
  }

  Future<void> _openField(SrsNoteTypeView type, SrsFieldDef field) async {
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) =>
            SrsFieldInfoPage(noteTypeId: type.id, fieldId: field.id),
      ),
    );
    if (mounted) await _reload();
  }

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
        // 可视化模板的块与字段删除在同一次写入里落库：删不掉时模板也不动。
        _run(
          'SrsNoteTypeEditor.deleteField',
          (SrsDbStore s) => s.deleteField(
            type.id,
            field.id,
            prepareTemplate: (SrsNoteTypeView fresh, SrsTemplateDef tpl) =>
                srsVisualTemplateWithoutField(fresh, tpl, field.id),
          ),
        );
    }
  }

  // ------------------------------------------------------------------ 模板

  Future<void> _openTemplate(
    SrsNoteTypeView type,
    String templateId, {
    SrsTemplateEditorTab tab = SrsTemplateEditorTab.visual,
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
    if (reg.key.startsWith(SrsFieldKeys.fieldDescriptionPrefix)) {
      final String id = reg.key.substring(
        SrsFieldKeys.fieldDescriptionPrefix.length,
      );
      final SrsFieldDef? f = type.fieldById(id);
      return f == null
          ? t.srs_field_info_description
          : '${t.srs_field_info_description} · ${f.name}';
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
    // 宽窗（手机横屏 / 桌面）：左栏「这是什么类型 + 它出哪几种卡、每种卡上放了什么」，
    // 右栏（通常最长的）字段列表，两栏各自滚动；窄窗同顺序单列。
    final List<SrsSection> sections = <SrsSection>[
      if (type.edits.conflicted.isNotEmpty)
        SrsSection(_buildConflicts(context, type)),
      SrsSection(_buildOverview(context, type)),
      SrsSection(_buildTemplates(context, type)),
      SrsSection(pane: SrsPane.secondary, _buildFields(context, type, store)),
    ];
    return SrsAdaptiveSections(sections: sections);
  }

  /// 概览：名字（点了改名）+ 类型 / 内置 / 查词字段三枚标签，内置类型多一行说明。
  Widget _buildOverview(BuildContext context, SrsNoteTypeView type) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFieldDef? term = type.fields
        .where((SrsFieldDef f) => f.id == type.termFieldId)
        .firstOrNull;
    return FushiCard(
      key: const ValueKey<String>('srs-note-type-overview'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiListItem(
            key: const ValueKey<String>('srs-note-type-name-row'),
            leading: const FushiListLeadingIcon(FushiIcons.ankiCard),
            title: Text(type.name, style: context.fushiType.titleLarge),
            subtitle: Text(
              t.srs_note_types_overview_counts(
                fields: type.fields.length,
                cards: type.templates.length,
              ),
            ),
            onTap: () =>
                srsRunLogged('SrsNoteTypeEditor.rename', () => _rename(type)),
            trailing: FushiIcon(
              FushiIcons.rename,
              semanticLabel: t.srs_note_types_rename,
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                Wrap(
                  spacing: tokens.spacing.gap / 2,
                  runSpacing: tokens.spacing.gap / 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    FushiTag(
                      text: type.isCloze
                          ? t.srs_note_types_kind_cloze
                          : t.srs_note_types_kind_standard,
                      tone: FushiTagTone.neutral,
                    ),
                    if (type.builtinKey != null)
                      FushiTag(
                        key: const ValueKey<String>(
                          'srs-note-type-builtin-tag',
                        ),
                        text: t.srs_note_types_builtin,
                        tone: FushiTagTone.accent,
                      ),
                    FushiActionChip(
                      key: const ValueKey<String>('srs-note-type-term-row'),
                      icon: FushiIcons.lookup,
                      label: t.srs_note_types_term_chip(
                        name: term == null
                            ? t.srs_note_types_term_field_none
                            : srsFieldDisplayName(term),
                      ),
                      onPressed: () => srsRunLogged(
                        'SrsNoteTypeEditor.termField',
                        () => _pickTermField(type),
                      ),
                    ),
                  ],
                ),
                if (type.builtinKey != null)
                  Text(
                    t.srs_note_types_builtin_hint,
                    key: const ValueKey<String>('srs-note-type-builtin-hint'),
                    style: context.fushiType.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片模板：每种卡一行，副标题直接列出正面 / 背面放了哪些字段（看一眼就知道这张卡
  /// 长什么样，不必点进去）；末尾是全部模板共用的样式入口。
  Widget _buildTemplates(BuildContext context, SrsNoteTypeView type) {
    String sideText(String body) {
      final List<String> names = <String>[
        for (final SrsFieldDef f in srsFieldsShownOnSide(type, body))
          srsFieldDisplayName(f),
      ];
      return names.isEmpty ? t.srs_note_types_side_none : names.join('、');
    }

    return _Section(
      title: t.srs_note_types_templates,
      hint: t.srs_note_types_templates_hint,
      addKey: const ValueKey<String>('srs-note-type-add-template'),
      addLabel: t.srs_note_types_template_add,
      onAdd: type.isCloze
          ? null
          : () => srsRunLogged(
              'SrsNoteTypeEditor.addTemplate',
              () => _addTemplate(type),
            ),
      footer: FushiListItem(
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
      children: <Widget>[
        for (int i = 0; i < type.templates.length; i++)
          _ItemRow(
            key: ValueKey<String>(
              'srs-note-type-template-${type.templates[i].name}',
            ),
            icon: FushiIcons.ankiCard,
            title: type.templates[i].name,
            subtitle: <String>[
              t.srs_note_types_template_front_fields(
                fields: sideText(type.templates[i].front),
              ),
              t.srs_note_types_template_back_fields(
                fields: sideText(type.templates[i].back),
              ),
            ].join('\n'),
            subtitleMaxLines: 4,
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
    );
  }

  /// 字段：内容字段按顺序平铺，每行标出「查词用」「没上卡面」；开关字段（填任意字符即
  /// 开启某种卡面样式，Lapis 有一串）收进末尾的折叠组，不再和内容字段混排成一长条。
  Widget _buildFields(
    BuildContext context,
    SrsNoteTypeView type,
    SrsDbStore store,
  ) {
    final Set<String> used = <String>{
      for (final SrsTemplateDef tpl in type.templates) ...<String>{
        for (final SrsFieldDef f in type.fields)
          if (srsTemplateReferencesField(tpl, f.id)) f.id,
      },
    };
    Widget row(int i) {
      final SrsFieldDef f = type.fields[i];
      final bool builtin = store.isBuiltinField(type, f.id);
      return _ItemRow(
        key: ValueKey<String>('srs-note-type-field-${f.name}'),
        icon: srsFieldKindIcon(srsFieldKind(f)),
        title: _fieldTitle(f),
        subtitle: _fieldSubtitle(f),
        tags: <Widget>[
          if (f.id == type.termFieldId)
            FushiTag(
              text: t.srs_note_types_field_term_tag,
              tone: FushiTagTone.accent,
            ),
          if (!used.contains(f.id))
            FushiTag(
              key: ValueKey<String>('srs-note-type-field-unused-${f.name}'),
              text: t.srs_note_types_field_unused,
              tone: FushiTagTone.neutral,
            ),
          if (builtin)
            FushiTag(
              text: t.srs_note_types_field_builtin,
              tone: FushiTagTone.neutral,
            ),
        ],
        renameLabel: t.srs_note_types_field_rename,
        deleteLabel: t.srs_note_types_field_delete,
        onTap: () => srsRunLogged(
          'SrsNoteTypeEditor.openField',
          () => _openField(type, f),
        ),
        canMoveUp: i > 0,
        canMoveDown: i < type.fields.length - 1,
        canDelete: type.fields.length > 1 && !builtin,
        onAction: (_ItemAction a) => srsRunLogged(
          'SrsNoteTypeEditor.field',
          () => _onFieldAction(type, f, a),
        ),
      );
    }

    final List<int> content = <int>[
      for (int i = 0; i < type.fields.length; i++)
        if (srsFieldKind(type.fields[i]) != SrsFieldKind.flag) i,
    ];
    final List<int> flags = <int>[
      for (int i = 0; i < type.fields.length; i++)
        if (srsFieldKind(type.fields[i]) == SrsFieldKind.flag) i,
    ];
    return _Section(
      title: t.srs_note_types_fields_count(n: type.fields.length),
      hint: t.srs_note_types_fields_hint,
      addKey: const ValueKey<String>('srs-note-type-add-field'),
      addLabel: t.srs_note_types_field_add,
      onAdd: () =>
          srsRunLogged('SrsNoteTypeEditor.addField', () => _addField(type)),
      footer: flags.isEmpty
          ? null
          : FushiExpansionTile(
              key: const ValueKey<String>('srs-note-type-flag-fields'),
              leading: const FushiListLeadingIcon(FushiIcons.flag),
              title: Text(t.srs_note_types_flag_fields(n: flags.length)),
              subtitle: Text(t.srs_note_types_flag_fields_hint),
              children: <Widget>[for (final int i in flags) row(i)],
            ),
      children: <Widget>[for (final int i in content) row(i)],
    );
  }
}

/// 模板里**显示出来**的字段（`{{字段}}` / `{{过滤器:字段}}`，不算 `{{#字段}}` 这类条件段），
/// 按在正文里第一次出现的位置排序。[body] 是 fieldId 形式的模板正文。
List<SrsFieldDef> srsFieldsShownOnSide(SrsNoteTypeView type, String body) {
  final List<(int, SrsFieldDef)> hits = <(int, SrsFieldDef)>[];
  for (final SrsFieldDef f in type.fields) {
    final RegExpMatch? m = RegExp(
      r'\{\{(?![#^/])[^{}]*?'
      '${RegExp.escape('fld:${f.id}')}'
      r'\}\}',
    ).firstMatch(body);
    if (m != null) hits.add((m.start, f));
  }
  hits.sort(
    ((int, SrsFieldDef) a, (int, SrsFieldDef) b) => a.$1.compareTo(b.$1),
  );
  return <SrsFieldDef>[for (final (int, SrsFieldDef) h in hits) h.$2];
}

/// 模板（任一面，含条件段）是否引用了这个字段。
bool srsTemplateReferencesField(SrsTemplateDef tpl, String fieldId) {
  final RegExp ref = RegExp(
    '${RegExp.escape('fld:$fieldId')}'
    r'\}\}',
  );
  return ref.hasMatch(tpl.front) || ref.hasMatch(tpl.back);
}

/// 一组（字段 / 卡片模板）：标题行（标题 + 一句说明 + 「添加」按钮）+ 行 + 可选的尾部。
/// 「添加」放在标题行而不是列表末尾：字段一长，末尾的按钮要滚到底才看得见。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.hint,
    required this.addKey,
    required this.addLabel,
    required this.onAdd,
    required this.children,
    this.footer,
  });

  final String title;
  final String hint;
  final Key addKey;
  final String addLabel;
  final VoidCallback? onAdd;
  final List<Widget> children;
  final Widget? footer;

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
              tokens.spacing.gap,
              tokens.spacing.gap / 2,
            ),
            child: Row(
              spacing: tokens.spacing.gap,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: context.fushiType.titleSmall),
                      Text(hint, style: context.fushiType.bodySmall),
                    ],
                  ),
                ),
                FushiFilledButton.tonalIcon(
                  key: addKey,
                  onPressed: onAdd,
                  icon: const FushiIcon(FushiIcons.add),
                  label: Text(addLabel),
                ),
              ],
            ),
          ),
          ...children,
          ?footer,
          SizedBox(height: tokens.spacing.gap / 2),
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
    this.subtitleMaxLines = 2,
    this.tags = const <Widget>[],
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
  final int subtitleMaxLines;

  /// 标题下的一排小标签（查词用 / 没上卡面 / 内置）。
  final List<Widget> tags;
  final VoidCallback? onTap;
  final bool canMoveUp;
  final bool canMoveDown;
  final bool canDelete;
  final void Function(_ItemAction action) onAction;

  @override
  Widget build(BuildContext context) => FushiListItem(
    leading: FushiListLeadingIcon(icon),
    title: tags.isEmpty
        ? Text(title)
        : Wrap(
            spacing: FushiDesignTokens.of(context).spacing.gap / 2,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[Text(title), ...tags],
          ),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle!,
            maxLines: subtitleMaxLines,
            overflow: TextOverflow.ellipsis,
          ),
    subtitleMaxLines: subtitleMaxLines,
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
