/// 复习的笔记类型管理：列出全部笔记类型（含笔记数），新建（基础类型 / 克隆）、改名、删除，
/// 点进编辑字段 / 卡片模板 / 样式（[SrsNoteTypeEditorPage]）。
///
/// 写操作全部经 [SrsNoteTypeStoreOps]（修改记录，随同步传播、按项合并）。内置 Lapis 不能删除。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_card_appearance_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_type_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 名字校验结果 → 提示文案（笔记类型名 / 字段名 / 模板名共用）。
String? srsNameProblemText(SrsNameProblem? p) => switch (p) {
  null => null,
  SrsNameProblem.empty => t.srs_note_types_name_empty,
  SrsNameProblem.duplicate => t.srs_note_types_name_duplicate,
  SrsNameProblem.invalidChars => t.srs_note_types_name_invalid,
  SrsNameProblem.reserved => t.srs_note_types_name_reserved,
};

/// 新建菜单里的一项：基础类型或克隆某个已有类型。
sealed class _NewTypeChoice {
  const _NewTypeChoice();
}

final class _StockChoice extends _NewTypeChoice {
  const _StockChoice(this.stock);
  final SrsStockNoteType stock;

  @override
  bool operator ==(Object other) =>
      other is _StockChoice && other.stock == stock;

  @override
  int get hashCode => stock.hashCode;
}

final class _CloneChoice extends _NewTypeChoice {
  const _CloneChoice(this.source);
  final SrsNoteTypeView source;

  @override
  bool operator ==(Object other) =>
      other is _CloneChoice && other.source.id == source.id;

  @override
  int get hashCode => source.id.hashCode;
}

enum _TypeAction { rename, clone, delete, appearance, migrateToFushiCard }

/// 基础类型的显示名。
String srsStockNoteTypeLabel(SrsStockNoteType s) => switch (s) {
  SrsStockNoteType.basic => t.srs_note_types_stock_basic,
  SrsStockNoteType.basicReversed => t.srs_note_types_stock_reversed,
  SrsStockNoteType.cloze => t.srs_note_types_stock_cloze,
};

class SrsNoteTypesPage extends ConsumerStatefulWidget {
  const SrsNoteTypesPage({super.key});

  @override
  ConsumerState<SrsNoteTypesPage> createState() => _SrsNoteTypesPageState();
}

class _SrsNoteTypesPageState extends ConsumerState<SrsNoteTypesPage> {
  bool _loading = true;
  SrsDbStore? _store;
  List<SrsNoteTypeView> _types = const <SrsNoteTypeView>[];
  Map<String, int> _counts = const <String, int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final List<SrsNoteTypeView> types = await store.noteTypes();
    final Map<String, int> counts = await store.noteCountsByType();
    if (!mounted) return;
    setState(() {
      _store = store;
      _types = types;
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _afterWrite() async {
    bumpSrsRevision(ref);
    await _reload();
  }

  String? _validateTypeName(String value, {String? exceptId}) =>
      srsNameProblemText(
        srsValidatePlainName(value, <String>[
          for (final SrsNoteTypeView v in _types)
            if (v.id != exceptId) v.name,
        ]),
      );

  Future<void> _open(SrsNoteTypeView type) async {
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => SrsNoteTypeEditorPage(noteTypeId: type.id),
      ),
    );
    if (mounted) await _afterWrite();
  }

  Future<void> _add() async {
    final _NewTypeChoice? choice = await showFushiChoiceDialog<_NewTypeChoice>(
      context: context,
      title: t.srs_note_types_add,
      icon: FushiIcons.add,
      options: <FushiChoiceOption<_NewTypeChoice>>[
        for (final SrsStockNoteType s in SrsStockNoteType.values)
          FushiChoiceOption<_NewTypeChoice>(
            value: _StockChoice(s),
            label: srsStockNoteTypeLabel(s),
          ),
        for (final SrsNoteTypeView v in _types)
          FushiChoiceOption<_NewTypeChoice>(
            value: _CloneChoice(v),
            label: t.srs_note_types_clone_of(name: v.name),
          ),
      ],
    );
    if (choice == null || !mounted) return;
    final String initial = switch (choice) {
      _StockChoice(:final SrsStockNoteType stock) => srsStockNoteTypeLabel(
        stock,
      ),
      _CloneChoice(:final SrsNoteTypeView source) => t.srs_note_types_copy_name(
        name: source.name,
      ),
    };
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.srs_note_types_add,
      labelText: t.srs_key_name,
      initialValue: _uniqueName(initial),
      icon: FushiIcons.ankiCard,
      validator: _validateTypeName,
    );
    final SrsDbStore? store = _store;
    if (name == null || store == null || !mounted) return;
    final String id = switch (choice) {
      _StockChoice(:final SrsStockNoteType stock) =>
        await store.createStockNoteType(stock, name),
      _CloneChoice(:final SrsNoteTypeView source) => await store.cloneNoteType(
        source.id,
        name,
      ),
    };
    await _afterWrite();
    final SrsNoteTypeView? created = _types
        .where((SrsNoteTypeView v) => v.id == id)
        .firstOrNull;
    if (created != null && mounted) await _open(created);
  }

  /// 默认名已被占用时加序号（「问答 2」）。
  String _uniqueName(String base) {
    if (_validateTypeName(base) == null) return base;
    for (int i = 2; i < 100; i++) {
      final String n = '$base $i';
      if (_validateTypeName(n) == null) return n;
    }
    return base;
  }

  Future<void> _rename(SrsNoteTypeView type) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.srs_note_types_rename,
      labelText: t.srs_key_name,
      initialValue: type.name,
      icon: FushiIcons.rename,
      validator: (String v) => _validateTypeName(v, exceptId: type.id),
    );
    final SrsDbStore? store = _store;
    if (name == null || name == type.name || store == null) return;
    await store.renameNoteType(type.id, name);
    if (mounted) await _afterWrite();
  }

  Future<void> _clone(SrsNoteTypeView type) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.srs_note_types_clone,
      labelText: t.srs_key_name,
      initialValue: _uniqueName(t.srs_note_types_copy_name(name: type.name)),
      icon: FushiIcons.copy,
      validator: _validateTypeName,
    );
    final SrsDbStore? store = _store;
    if (name == null || store == null) return;
    await store.cloneNoteType(type.id, name);
    if (mounted) await _afterWrite();
  }

  Future<void> _delete(SrsNoteTypeView type) async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    if (!store.canDeleteNoteType(type)) {
      FushiToast.show(msg: t.srs_note_types_builtin_hint);
      return;
    }
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_note_types_delete,
      message: t.srs_note_types_delete_confirm(
        name: type.name,
        n: _counts[type.id] ?? 0,
      ),
      confirmLabel: t.srs_note_types_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok) return;
    await store.deleteNoteType(type.id);
    if (mounted) await _afterWrite();
  }

  void _onAction(SrsNoteTypeView type, _TypeAction action) {
    switch (action) {
      case _TypeAction.rename:
        srsRunLogged('SrsNoteTypes.rename', () => _rename(type));
      case _TypeAction.clone:
        srsRunLogged('SrsNoteTypes.clone', () => _clone(type));
      case _TypeAction.delete:
        srsRunLogged('SrsNoteTypes.delete', () => _delete(type));
      case _TypeAction.appearance:
        srsRunLogged(
          'SrsNoteTypes.appearance',
          () => openSrsCardAppearancePage(context),
        );
      case _TypeAction.migrateToFushiCard:
        srsRunLogged('SrsNoteTypes.migrate', () async {
          if (await showSrsMigrateToFushiCardFlow(context) && mounted) {
            await _afterWrite();
          }
        });
    }
  }

  FushiToolbarItem get _addItem => FushiToolbarItem(
    key: const ValueKey<String>('srs_note_types_add'),
    icon: FushiIcons.add,
    label: t.srs_note_types_add,
    onPressed: _store == null
        ? null
        : () => srsRunLogged('SrsNoteTypes.add', _add),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_note_types_title,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              FushiIconButton(
                key: _addItem.key,
                icon: _addItem.icon,
                tooltip: _addItem.label,
                enabled: _addItem.onPressed != null,
                onTap: _addItem.onPressed,
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
        title: t.srs_note_types_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[_addItem],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsDbStore store = _store!;
    final List<Widget> items = <Widget>[
      if (_types.isEmpty)
        Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.ankiCard,
            message: t.srs_note_types_empty,
          ),
        ),
      for (int i = 0; i < _types.length; i++)
        _TypeRow(
          key: ValueKey<String>('srs-note-type-${_types[i].id}'),
          type: _types[i],
          notes: _counts[_types[i].id] ?? 0,
          index: i,
          count: _types.length,
          deletable: store.canDeleteNoteType(_types[i]),
          onOpen: () =>
              srsRunLogged('SrsNoteTypes.open', () => _open(_types[i])),
          onAction: (_TypeAction a) => _onAction(_types[i], a),
        ),
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: items.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({
    super.key,
    required this.type,
    required this.notes,
    required this.index,
    required this.count,
    required this.deletable,
    required this.onOpen,
    required this.onAction,
  });

  final SrsNoteTypeView type;
  final int notes;
  final int index;
  final int count;
  final bool deletable;
  final VoidCallback onOpen;
  final void Function(_TypeAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiPressScale(
      child: FushiGroupedListItem(
        index: index,
        count: count,
        onTap: onOpen,
        child: FushiListItem(
          density: srsListDensityOf(context),
          leading: FushiListLeadingIcon(
            FushiIcons.ankiCard,
            tone: type.builtinKey != null
                ? FushiCardTone.primary
                : FushiCardTone.neutral,
          ),
          title: Text(type.name),
          // 逐段不可拆：窄屏不会在「1」与「种卡片」之间断行。
          subtitle: SrsMetaLine(<String>[
            if (type.builtinKey != null) t.srs_note_types_builtin,
            if (type.isCloze) t.srs_note_types_kind_cloze,
            ...SrsMetaLine.split(
              t.srs_note_types_summary(
                notes: notes,
                fields: type.fields.length,
                cards: type.templates.length,
              ),
            ),
          ]),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: tokens.spacing.gap / 2,
            children: <Widget>[
              if (type.edits.conflicted.isNotEmpty)
                FushiTooltip(
                  message: t.srs_note_types_conflict,
                  child: const FushiIcon(FushiIcons.warning),
                ),
              FushiPopupMenuButton<_TypeAction>(
                tooltip: t.srs_deck_menu,
                icon: const FushiIcon(FushiIcons.more),
                onSelected: onAction,
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<_TypeAction>>[
                      PopupMenuItem<_TypeAction>(
                        value: _TypeAction.rename,
                        child: Text(t.srs_note_types_rename),
                      ),
                      PopupMenuItem<_TypeAction>(
                        value: _TypeAction.clone,
                        child: Text(t.srs_note_types_clone),
                      ),
                      if (type.builtinKey == kSrsBuiltinFushiCardKey)
                        PopupMenuItem<_TypeAction>(
                          key: const ValueKey<String>(
                            'srs-note-types-appearance',
                          ),
                          value: _TypeAction.appearance,
                          child: Text(t.srs_card_appearance_title),
                        ),
                      if (type.builtinKey == kSrsBuiltinLapisKey && notes > 0)
                        PopupMenuItem<_TypeAction>(
                          key: const ValueKey<String>('srs-note-types-migrate'),
                          value: _TypeAction.migrateToFushiCard,
                          child: Text(t.srs_migrate_fushi_action),
                        ),
                      if (deletable)
                        PopupMenuItem<_TypeAction>(
                          value: _TypeAction.delete,
                          child: Text(t.srs_note_types_delete),
                        ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
