import 'dart:async';

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/popup_header_buttons.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiSettings;

/// 设置 → 制卡 → 查词弹窗按钮（拍板台 b1JDe8McbS）：词条头上每颗按钮一行，整块可拖动
/// 排序（鼠标按下即拖、触屏长按拖），每行一个「在弹窗中显示」开关，外加「上移 / 下移」
/// 两颗可聚焦按钮与同名无障碍动作（手柄 / 键盘抓不住拖拽把手），与导航模块排序同一套。
///
/// 额外的制卡按钮（制卡方案）也是这里的行：点行编辑，行尾可删；列表末尾「添加制卡按钮」。
/// 方案只记它和字段映射不一样的项，落卡时作为单次请求的覆盖项随 fields map 走。
class PopupHeaderButtonsList extends StatefulWidget {
  const PopupHeaderButtonsList({required this.settingsContext, super.key});

  final SettingsContext settingsContext;

  @override
  State<PopupHeaderButtonsList> createState() => _PopupHeaderButtonsListState();
}

/// 内置按钮的行标题与图标。
({String label, IconData icon}) popupHeaderButtonIdentity(
  PopupHeaderButton button,
) => switch (button) {
  PopupHeaderButton.audio => (
    label: t.popup_header_button_audio,
    icon: FushiIcons.volumeUp,
  ),
  PopupHeaderButton.favorite => (
    label: t.popup_header_button_favorite,
    icon: FushiIcons.star,
  ),
  PopupHeaderButton.srsStatus => (
    label: t.popup_header_button_srs,
    icon: FushiIcons.restart,
  ),
  PopupHeaderButton.mine => (
    label: t.popup_header_button_mine,
    icon: FushiIcons.ankiCard,
  ),
  PopupHeaderButton.openInAnki => (
    label: t.popup_header_button_open_anki,
    icon: FushiIcons.openInNew,
  ),
  PopupHeaderButton.sentenceContext => (
    label: t.popup_header_button_context,
    icon: FushiIcons.quote,
  ),
  PopupHeaderButton.crossAppAudio => (
    label: t.popup_header_button_cross_app_audio,
    icon: FushiIcons.mic,
  ),
  PopupHeaderButton.advancedMining => (
    label: t.popup_header_button_advanced,
    icon: FushiIcons.settings,
  ),
};

class _PopupHeaderButtonsListState extends State<PopupHeaderButtonsList> {
  /// 拖拽提交后、偏好落库前的乐观排布（同 NavModuleOrderList：FushiReorderableColumn
  /// 提交即复位成恒等映射，父级按旧值重建会让行先弹回原位）。
  PopupHeaderButtonsConfig? _pending;

  PopupHeaderButtonsConfig get _config =>
      _pending ?? widget.settingsContext.appModel.popupHeaderButtons;

  Future<void> _save(PopupHeaderButtonsConfig next) async {
    setState(() => _pending = next);
    try {
      await widget.settingsContext.appModel.setPopupHeaderButtons(next);
    } finally {
      if (mounted) {
        setState(() => _pending = null);
        widget.settingsContext.refresh();
      }
    }
  }

  /// 同步回调里的提交入口：落库失败进全局错误日志，而不是变成无人接的 Future 错误。
  void _commit(PopupHeaderButtonsConfig next) {
    unawaited(
      _save(next).catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'settings',
            context: ErrorDescription('while saving the lookup popup buttons'),
          ),
        );
      }),
    );
  }

  void _move(int index, int delta) {
    final int target = index + delta;
    if (target < 0 || target >= _config.order.length) return;
    _commit(_config.moved(index, target));
  }

  AnkiSettings _ankiSettings() =>
      widget.settingsContext.ref.read(ankiViewModelProvider).settings;

  Future<void> _editScheme(PopupMiningScheme? existing) async {
    final PopupMiningScheme? edited = await showPopupMiningSchemeEditor(
      context: context,
      existing: existing,
      ankiSettings: _ankiSettings(),
    );
    if (edited == null || !mounted) return;
    _commit(_config.withScheme(edited));
  }

  Future<void> _deleteScheme(PopupMiningScheme scheme) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.popup_mining_scheme_delete,
      message: t.popup_mining_scheme_delete_confirm(name: scheme.label),
      confirmLabel: t.popup_mining_scheme_delete,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    _commit(_config.withoutScheme(scheme.id));
  }

  @override
  Widget build(BuildContext context) {
    final PopupHeaderButtonsConfig config = _config;
    final List<String> slots = config.order;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 自实现的 FushiReorderableColumn（不是 SDK ReorderableListView）：整棵树活在
        // FushiAppUiScale 的 Transform.scale 之下，SDK 拖拽浮层不认祖先缩放会漂移。
        FushiReorderableColumn(
          itemCount: slots.length,
          keyForIndex: (int index) =>
              ValueKey<String>('popup-header-button-${slots[index]}'),
          onReorder: (int from, int to) => _commit(config.moved(from, to)),
          itemBuilder: (BuildContext context, int index) =>
              FushiStaggeredEntrance(
                index: index,
                child: _buildRow(context, config, index),
              ),
        ),
        FushiStaggeredEntrance(
          index: slots.length,
          child: FushiListItem(
            key: const ValueKey<String>('popup-header-button-add-scheme'),
            leading: const FushiListLeadingIcon(
              FushiIcons.add,
              tone: FushiCardTone.primary,
            ),
            title: Text(t.popup_mining_scheme_add),
            onTap: () => unawaited(_editScheme(null)),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    PopupHeaderButtonsConfig config,
    int index,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String slot = config.order[index];
    final bool shown = !config.isHidden(slot);
    final bool canMoveUp = index > 0;
    final bool canMoveDown = index < config.order.length - 1;

    final PopupMiningScheme? miningScheme =
        slot.startsWith(kPopupMiningSchemeSlotPrefix)
        ? config.schemeById(slot.substring(kPopupMiningSchemeSlotPrefix.length))
        : null;
    final PopupHeaderButton? builtin = PopupHeaderButton.fromWire(slot);
    final String label;
    final IconData icon;
    final String? subtitle;
    if (miningScheme != null) {
      label = '+${miningScheme.label}';
      icon = FushiIcons.ankiCard;
      subtitle = _schemeSummary(miningScheme);
    } else if (builtin != null) {
      final ({String label, IconData icon}) identity =
          popupHeaderButtonIdentity(builtin);
      label = identity.label;
      icon = identity.icon;
      subtitle = null;
    } else {
      // normalized() 之后不会出现；防御性地不画。
      return const SizedBox.shrink();
    }

    return Semantics(
      key: ValueKey<String>('popup-header-button-semantics-$slot'),
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (canMoveUp)
          CustomSemanticsAction(label: t.move_up): () => _move(index, -1),
        if (canMoveDown)
          CustomSemanticsAction(label: t.move_down): () => _move(index, 1),
      },
      child: FushiListItem(
        key: ValueKey<String>('popup-header-button-row-$slot'),
        leading: FushiListLeadingIcon(
          icon,
          tone: shown ? FushiCardTone.secondary : FushiCardTone.neutral,
        ),
        title: Text(
          label,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: shown ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ),
        subtitle: subtitle == null ? null : Text(subtitle),
        onTap: miningScheme != null
            ? () => unawaited(_editScheme(miningScheme))
            : () => _commit(config.withHidden(slot, shown)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (miningScheme != null)
              FushiIconButton(
                key: ValueKey<String>('popup-header-button-delete-$slot'),
                icon: FushiIcons.delete,
                size: 18,
                tooltip: t.popup_mining_scheme_delete,
                isWideTapArea: true,
                onTap: () => unawaited(_deleteScheme(miningScheme)),
              ),
            Tooltip(
              message: t.popup_header_button_show,
              child: FushiSwitch(
                key: ValueKey<String>('popup-header-button-switch-$slot'),
                value: shown,
                onChanged: (bool value) =>
                    _commit(config.withHidden(slot, !value)),
              ),
            ),
            FushiIconButton(
              key: ValueKey<String>('popup-header-button-up-$slot'),
              icon: FushiIcons.expandLess,
              size: 18,
              tooltip: t.move_up,
              enabled: canMoveUp,
              isWideTapArea: true,
              onTap: () => _move(index, -1),
            ),
            FushiIconButton(
              key: ValueKey<String>('popup-header-button-down-$slot'),
              icon: FushiIcons.expandMore,
              size: 18,
              tooltip: t.move_down,
              enabled: canMoveDown,
              isWideTapArea: true,
              onTap: () => _move(index, 1),
            ),
            ExcludeSemantics(
              child: FushiIcon(
                FushiIcons.dragIndicator,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _schemeSummary(PopupMiningScheme s) => <String>[
    t.popup_mining_scheme_subtitle,
    if (s.deckName != null) s.deckName!,
    if (s.fieldTemplates.isNotEmpty)
      t.popup_mining_scheme_summary_fields(count: s.fieldTemplates.length),
    if (s.omitAudio) t.popup_mining_scheme_omit_audio,
    if (s.omitImage) t.popup_mining_scheme_omit_image,
  ].join(' · ');
}

/// 新建 / 编辑一套制卡方案。返回 null = 取消。
///
/// 字段列表取当前 Anki 字段映射的字段名：每个字段一个输入框，提示文字是继承来的模板，
/// 留空 = 继承（不写进方案）。卡组下拉第一项是「跟随设置」。
Future<PopupMiningScheme?> showPopupMiningSchemeEditor({
  required BuildContext context,
  required AnkiSettings ankiSettings,
  PopupMiningScheme? existing,
}) => showAppDialog<PopupMiningScheme>(
  context: context,
  builder: (_) =>
      _PopupMiningSchemeEditor(existing: existing, ankiSettings: ankiSettings),
);

class _PopupMiningSchemeEditor extends StatefulWidget {
  const _PopupMiningSchemeEditor({
    required this.existing,
    required this.ankiSettings,
  });

  final PopupMiningScheme? existing;
  final AnkiSettings ankiSettings;

  @override
  State<_PopupMiningSchemeEditor> createState() =>
      _PopupMiningSchemeEditorState();
}

class _PopupMiningSchemeEditorState extends State<_PopupMiningSchemeEditor> {
  late final TextEditingController _label = TextEditingController(
    text: widget.existing?.label ?? '',
  )..addListener(_onChanged);

  /// 字段名（按字段映射顺序）。方案里有、映射里已经没有的字段也列出来，免得编辑一次
  /// 就把它静默丢掉。
  late final List<String> _fieldNames = <String>[
    ...widget.ankiSettings.fieldMappings.keys,
    for (final String name
        in widget.existing?.fieldTemplates.keys ?? const <String>[])
      if (!widget.ankiSettings.fieldMappings.containsKey(name)) name,
  ];

  late final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{
        for (final String name in _fieldNames)
          name: TextEditingController(
            text: widget.existing?.fieldTemplates[name] ?? '',
          ),
      };

  /// 空串 = 跟随设置。
  late String _deck = widget.existing?.deckName ?? '';
  late bool _omitAudio = widget.existing?.omitAudio ?? false;
  late bool _omitImage = widget.existing?.omitImage ?? false;

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _label.dispose();
    for (final TextEditingController c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _canSubmit => _label.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    final Map<String, String> templates = <String, String>{
      for (final MapEntry<String, TextEditingController> e in _fields.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
    };
    Navigator.of(context).pop(
      PopupMiningScheme(
        id:
            widget.existing?.id ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        label: _label.text.trim(),
        deckName: _deck.isEmpty ? null : _deck,
        fieldTemplates: templates,
        omitAudio: _omitAudio,
        omitImage: _omitImage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> decks = <String>[
      '',
      for (final deck in widget.ankiSettings.availableDecks) deck.name,
      if (_deck.isNotEmpty &&
          !widget.ankiSettings.availableDecks.any((d) => d.name == _deck))
        _deck,
    ];
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.ankiCard),
      title: Text(
        widget.existing == null
            ? t.popup_mining_scheme_add
            : t.popup_mining_scheme_edit,
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiTextFieldControl(
            key: const ValueKey<String>('popup-mining-scheme-label'),
            controller: _label,
            autofocus: widget.existing == null,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: t.popup_mining_scheme_label,
              hintText: t.popup_mining_scheme_label_hint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(t.anki_deck, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          FushiDropdown<String>(
            key: const ValueKey<String>('popup-mining-scheme-deck'),
            options: decks,
            initialOption: _deck,
            generateLabel: (String d) =>
                d.isEmpty ? t.popup_mining_scheme_inherit : d,
            onChanged: (String? d) => setState(() => _deck = d ?? ''),
          ),
          const SizedBox(height: 8),
          FushiSwitchListTile(
            key: const ValueKey<String>('popup-mining-scheme-omit-audio'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.popup_mining_scheme_omit_audio),
            value: _omitAudio,
            onChanged: (bool v) => setState(() => _omitAudio = v),
          ),
          FushiSwitchListTile(
            key: const ValueKey<String>('popup-mining-scheme-omit-image'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.popup_mining_scheme_omit_image),
            value: _omitImage,
            onChanged: (bool v) => setState(() => _omitImage = v),
          ),
          const SizedBox(height: 8),
          Text(
            t.popup_mining_scheme_fields,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          Text(
            _fieldNames.isEmpty
                ? t.popup_mining_scheme_no_fields
                : t.popup_mining_scheme_fields_hint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final String name in _fieldNames)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FushiTextFieldControl(
                key: ValueKey<String>('popup-mining-scheme-field-$name'),
                controller: _fields[name],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: name,
                  hintText: widget.ankiSettings.fieldMappings[name],
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('popup-mining-scheme-save'),
          label: t.dialog_save,
          kind: FushiDialogActionKind.primary,
          onPressed: _canSubmit ? _submit : null,
        ),
      ],
    );
  }
}
