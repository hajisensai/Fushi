/// 更改笔记类型（Anki 的 Change Note Type）：选目标类型 → 新字段 ← 旧字段映射（默认按名字）
/// → 新卡片模板 ← 旧卡片映射（决定复习历史与排程跟到哪张卡）→ 确认。
///
/// 入口见 `fushi/lib/src/srs/srs_change_note_type.dart` 的 [showSrsChangeNoteTypeFlow]。
/// 写入经 [SrsNoteTypeStoreOps.changeNoteType]：一个事务里写笔记的类型键、字段值与新卡的前身链接，
/// 复习日志一条不改（见 fushi_srs note_type_ops.dart）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class SrsChangeNoteTypePage extends ConsumerStatefulWidget {
  const SrsChangeNoteTypePage({
    super.key,
    required this.noteIds,
    required this.from,
    required this.targets,
    this.initialTargetId,
    this.initialFieldMap,
    this.initialTemplateMap,
  });

  /// 要换类型的笔记（同一个源类型）。
  final List<String> noteIds;
  final SrsNoteTypeView from;

  /// 可选的目标类型（不含源类型），非空。
  final List<SrsNoteTypeView> targets;

  /// 预选的目标类型（不在 [targets] 里时取第一个）。
  final String? initialTargetId;

  /// 预设映射（新 id → 旧 id），只对 [initialTargetId] 生效；换了目标类型回到默认映射。
  /// 「迁移到 Fushi 卡片」用它预填按字段键直映的结果。
  final Map<String, String?>? initialFieldMap;
  final Map<String, String?>? initialTemplateMap;

  @override
  ConsumerState<SrsChangeNoteTypePage> createState() =>
      _SrsChangeNoteTypePageState();
}

class _SrsChangeNoteTypePageState extends ConsumerState<SrsChangeNoteTypePage> {
  late SrsNoteTypeView _to =
      widget.targets
          .where((SrsNoteTypeView v) => v.id == widget.initialTargetId)
          .firstOrNull ??
      widget.targets.first;
  late final bool _presetApplies = _to.id == widget.initialTargetId;
  late Map<String, String?> _fieldMap =
      (_presetApplies ? widget.initialFieldMap : null) ??
      srsDefaultFieldMap(widget.from, _to);
  late Map<String, String?> _templateMap =
      (_presetApplies ? widget.initialTemplateMap : null) ??
      srsDefaultTemplateMap(widget.from, _to);
  SrsNoteTypeChangePreview? _preview;
  bool _applying = false;
  int _previewSeq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPreview());
  }

  bool get _standardPair => !widget.from.isCloze && !_to.isCloze;

  Future<void> _refreshPreview() async {
    final int seq = ++_previewSeq;
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) return;
      final SrsNoteTypeChangePreview p = await store.previewNoteTypeChange(
        noteIds: widget.noteIds,
        targetTypeId: _to.id,
        fieldMap: _fieldMap,
        templateMap: _templateMap,
      );
      if (mounted && seq == _previewSeq) setState(() => _preview = p);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsChangeNoteType.preview', e, stack);
    }
  }

  void _update(VoidCallback change) {
    setState(change);
    unawaited(_refreshPreview());
  }

  String _nameOfOldField(String? id) =>
      widget.from.fields
          .where((SrsFieldDef f) => f.id == id)
          .firstOrNull
          ?.name ??
      t.srs_change_type_nothing;

  String _nameOfOldTemplate(String? id) =>
      widget.from.templates
          .where((SrsTemplateDef x) => x.id == id)
          .firstOrNull
          ?.name ??
      t.srs_change_type_nothing;

  Future<void> _pickTarget() async {
    final String? id = await showFushiChoiceDialog<String>(
      context: context,
      title: t.srs_change_type_target,
      icon: FushiIcons.ankiCard,
      selected: _to.id,
      options: <FushiChoiceOption<String>>[
        for (final SrsNoteTypeView v in widget.targets)
          FushiChoiceOption<String>(value: v.id, label: v.name),
      ],
    );
    if (id == null || id == _to.id || !mounted) return;
    final SrsNoteTypeView to = widget.targets.firstWhere(
      (SrsNoteTypeView v) => v.id == id,
    );
    _update(() {
      _to = to;
      _fieldMap = srsDefaultFieldMap(widget.from, to);
      _templateMap = srsDefaultTemplateMap(widget.from, to);
    });
  }

  static const String _none = '';

  Future<void> _pickField(SrsFieldDef target) async {
    final String? id = await showFushiChoiceDialog<String>(
      context: context,
      title: target.name,
      message: t.srs_change_type_fields_hint,
      icon: FushiIcons.textFields,
      selected: _fieldMap[target.id] ?? _none,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: _none,
          label: t.srs_change_type_nothing,
        ),
        // 一个旧字段可以填进多个新字段（与 Anki 一致）。
        for (final SrsFieldDef f in widget.from.fields)
          FushiChoiceOption<String>(value: f.id, label: f.name),
      ],
    );
    if (id == null || !mounted) return;
    _update(() => _fieldMap[target.id] = id == _none ? null : id);
  }

  Future<void> _pickTemplate(SrsTemplateDef target) async {
    final String? id = await showFushiChoiceDialog<String>(
      context: context,
      title: target.name,
      message: t.srs_change_type_templates_hint,
      icon: FushiIcons.ankiCard,
      selected: _templateMap[target.id] ?? _none,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: _none,
          label: t.srs_change_type_nothing,
        ),
        for (final SrsTemplateDef x in widget.from.templates)
          FushiChoiceOption<String>(value: x.id, label: x.name),
      ],
    );
    if (id == null || !mounted) return;
    _update(() {
      // 一张旧卡只能被一个新模板接手：选中的旧模板从别的新模板上摘掉。
      if (id != _none) {
        for (final String k in _templateMap.keys.toList()) {
          if (_templateMap[k] == id) _templateMap[k] = null;
        }
      }
      _templateMap[target.id] = id == _none ? null : id;
    });
  }

  /// 不会被带到新类型的旧字段。
  List<String> get _unusedFields {
    final Set<String?> used = _fieldMap.values.toSet();
    return <String>[
      for (final SrsFieldDef f in widget.from.fields)
        if (!used.contains(f.id)) f.name,
    ];
  }

  Future<void> _apply() async {
    if (_applying) return;
    final SrsNoteTypeChangePreview? preview = _preview;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_change_type_title,
      message: t.srs_change_type_confirm(
        n: widget.noteIds.length,
        dropped: preview?.droppedCards ?? 0,
      ),
      confirmLabel: t.srs_change_type_apply,
      cancelLabel: t.cancel,
      icon: FushiIcons.swap,
      destructive: (preview?.droppedCards ?? 0) > 0,
    );
    if (!ok || !mounted) return;
    setState(() => _applying = true);
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      await store.changeNoteType(
        noteIds: widget.noteIds,
        targetTypeId: _to.id,
        fieldMap: _fieldMap,
        templateMap: _templateMap,
      );
      if (!mounted) return;
      bumpSrsRevision(ref);
      FushiToast.show(
        msg: t.srs_change_type_done,
        severity: ToastSeverity.success,
      );
      Navigator.of(context).pop(true);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsChangeNoteType.apply', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
      if (mounted) setState(() => _applying = false);
    }
  }

  FushiToolbarItem get _applyItem => FushiToolbarItem(
    key: const ValueKey<String>('srs_change_type_apply'),
    icon: FushiIcons.check,
    label: t.srs_change_type_apply,
    onPressed: _applying
        ? null
        : () => srsRunLogged('SrsChangeNoteType', _apply),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_change_type_title,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              FushiIconButton(
                key: _applyItem.key,
                icon: _applyItem.icon,
                tooltip: _applyItem.label,
                enabled: _applyItem.onPressed != null,
                onTap: _applyItem.onPressed,
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
        title: t.srs_change_type_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[_applyItem],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) =>
        _buildSections(context, wide: srsUsesTwoPane(constraints)),
  );

  /// [wide]：宽窗两栏，映射行收成单行（「新 ← 旧」同一行），字段多时少滚一半。
  Widget _buildSections(BuildContext context, {required bool wide}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsNoteTypeChangePreview? preview = _preview;
    final List<String> unused = _unusedFields;
    // 窄窗按 概要 → 字段 → 模板 → 警告 单列；宽窗（手机横屏 / 桌面）左栏放目标类型、
    // 卡片模板映射与警告，右栏放（通常最长的）字段映射，两栏各自滚动。
    final List<SrsSection> sections = <SrsSection>[
      SrsSection(
        FushiCard(
          key: const ValueKey<String>('srs-change-type-summary'),
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.ankiCard),
                title: Text(t.srs_change_type_current(name: widget.from.name)),
                subtitle: Text(
                  t.srs_change_type_notes(n: widget.noteIds.length),
                ),
              ),
              FushiListItem(
                key: const ValueKey<String>('srs-change-type-target'),
                leading: const FushiListLeadingIcon(FushiIcons.swap),
                title: Text(t.srs_change_type_target),
                subtitle: Text(_to.name),
                onTap: () =>
                    srsRunLogged('SrsChangeNoteType.target', _pickTarget),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ],
          ),
        ),
      ),
      SrsSection(
        pane: SrsPane.secondary,
        FushiCard(
          key: const ValueKey<String>('srs-change-type-fields'),
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(
                context,
                t.srs_note_types_fields,
                t.srs_change_type_fields_hint,
              ),
              for (final SrsFieldDef f in _to.fields)
                _mappingRow(
                  context,
                  key: ValueKey<String>('srs-change-type-field-${f.name}'),
                  dense: wide,
                  icon: FushiIcons.textFields,
                  target: f.name,
                  source: _nameOfOldField(_fieldMap[f.id]),
                  onTap: () => srsRunLogged(
                    'SrsChangeNoteType.field',
                    () => _pickField(f),
                  ),
                ),
              if (unused.isNotEmpty)
                Padding(
                  padding: EdgeInsets.all(tokens.spacing.card),
                  child: Text(
                    t.srs_change_type_unused(names: unused.join('、')),
                    key: const ValueKey<String>('srs-change-type-unused'),
                    style: context.fushiType.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      SrsSection(
        FushiCard(
          key: const ValueKey<String>('srs-change-type-templates'),
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(
                context,
                t.srs_note_types_templates,
                _standardPair
                    ? t.srs_change_type_templates_hint
                    : t.srs_change_type_cloze_hint,
              ),
              if (_standardPair)
                for (final SrsTemplateDef x in _to.templates)
                  _mappingRow(
                    context,
                    key: ValueKey<String>('srs-change-type-template-${x.name}'),
                    dense: wide,
                    icon: FushiIcons.ankiCard,
                    target: x.name,
                    source: _nameOfOldTemplate(_templateMap[x.id]),
                    onTap: () => srsRunLogged(
                      'SrsChangeNoteType.template',
                      () => _pickTemplate(x),
                    ),
                  ),
            ],
          ),
        ),
      ),
      if (preview != null && preview.droppedCards > 0)
        SrsSection(
          FushiCard(
            key: const ValueKey<String>('srs-change-type-dropped'),
            tone: FushiCardTone.error,
            child: Row(
              spacing: tokens.spacing.gap * 1.5,
              children: <Widget>[
                const FushiIcon(FushiIcons.warning),
                Expanded(
                  child: Text(
                    t.srs_change_type_dropped(n: preview.droppedCards),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
    return SrsAdaptiveSections(
      sections: sections,
      primaryFlex: 2,
      secondaryFlex: 3,
    );
  }

  /// 一条映射：新类型的 [target] 取自旧类型的 [source]。窄窗两行（名字 + 「← 来源」），
  /// [dense]（宽窗）时一行：名字在左、「← 来源」靠右，与 Anki 桌面映射表同一读法。
  Widget _mappingRow(
    BuildContext context, {
    required Key key,
    required bool dense,
    required IconData icon,
    required String target,
    required String source,
    required VoidCallback onTap,
  }) {
    final Widget from = Text(
      '← $source',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (!dense) {
      return FushiListItem(
        key: key,
        leading: FushiListLeadingIcon(icon),
        title: Text(target),
        subtitle: from,
        onTap: onTap,
        trailing: const FushiIcon(FushiIcons.chevronRight),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiListItem(
      key: key,
      leading: FushiListLeadingIcon(icon),
      title: Row(
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Expanded(
            child: Text(target, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: context.fushiType.bodyMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.end,
              child: from,
            ),
          ),
        ],
      ),
      onTap: onTap,
      trailing: const FushiIcon(FushiIcons.chevronRight),
    );
  }

  Widget _header(BuildContext context, String title, String hint) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.gap / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          Text(title, style: context.fushiType.titleSmall),
          Text(hint, style: context.fushiType.bodySmall),
        ],
      ),
    );
  }
}
