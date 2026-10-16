/// 「导入 Anki 包」的选项对话框（对齐 Anki 23.10+ 导入页）。
///
/// - 顶部：标题「导入选项」+ 文件名，右上「?」逐项说明；
/// - 两个开关：导入所有学习进度信息（with_scheduling）/ 导入所有牌组预设配置
///   （with_deck_configs）；
/// - 可折叠分组「更新」：合并笔记模板（开关）、更新笔记 / 更新笔记模板（较新时 /
///   始终 / 从不），每项右侧「恢复默认」，值等于默认时不可点。
///
/// 默认值取 [SrsAnkiImportOptions] 的默认构造（= Anki 源码默认）；上次的选择记在
/// 偏好 [kSrsImportOptionsPrefKey] 里（见 [readSrsImportOptions]）。
/// 宽屏标签在左、控件在右；窄屏由设置行自己的堆叠规则把下拉换到下一行。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/apkg/srs_import_options.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 偏好键：上次导入 Anki 包时的选项（String，[SrsAnkiImportOptions.toJson] 的 JSON）。
///
/// 普通偏好（随 Profile 快照 / 备份走），不进复习的事件存储：这是对话框的默认值，
/// 不是复习数据，写进事件存储只会给同步添无意义的修改记录；Anki 也把它存在集合
/// 配置里跟着用户走，而不是绑在某台设备上。
const String kSrsImportOptionsPrefKey = 'srs_import_anki_options';

/// 读上次的选择；没有 / 坏值回落到 Anki 默认值。
SrsAnkiImportOptions readSrsImportOptions(PrefStore prefs) {
  final Object? raw = prefs.getPref(kSrsImportOptionsPrefKey, defaultValue: '');
  if (raw is! String || raw.isEmpty) return const SrsAnkiImportOptions();
  try {
    final Object? json = jsonDecode(raw);
    if (json is Map) {
      return SrsAnkiImportOptions.fromJson(json.cast<String, Object?>());
    }
  } on FormatException {
    // 坏值：按默认值处理，下次确认时覆盖。
  }
  return const SrsAnkiImportOptions();
}

Future<void> writeSrsImportOptions(
  PrefStore prefs,
  SrsAnkiImportOptions options,
) => prefs.setPref(kSrsImportOptionsPrefKey, jsonEncode(options.toJson()));

/// 弹出选项对话框；取消返回 null。
Future<SrsAnkiImportOptions?> showSrsImportOptionsDialog({
  required BuildContext context,
  required String fileName,
  required SrsAnkiImportOptions initial,
  bool wholeCollection = false,
}) => showAppDialog<SrsAnkiImportOptions>(
  context: context,
  builder: (BuildContext dialogContext) => SrsImportOptionsDialog(
    fileName: fileName,
    initial: initial,
    wholeCollection: wholeCollection,
  ),
);

class SrsImportOptionsDialog extends StatefulWidget {
  const SrsImportOptionsDialog({
    required this.fileName,
    required this.initial,
    this.wholeCollection = false,
    super.key,
  });

  final String fileName;
  final SrsAnkiImportOptions initial;

  /// .colpkg：多一条「合并导入、不替换」的说明。
  final bool wholeCollection;

  /// 对话框正文宽度（与其它表单对话框同档；窄屏由对话框外边距收窄）。
  static const double contentWidth = 520;

  @override
  State<SrsImportOptionsDialog> createState() => _SrsImportOptionsDialogState();
}

class _SrsImportOptionsDialogState extends State<SrsImportOptionsDialog> {
  static const SrsAnkiImportOptions _defaults = SrsAnkiImportOptions();

  late SrsAnkiImportOptions _options = widget.initial;

  void _set(SrsAnkiImportOptions next) => setState(() => _options = next);

  String _conditionLabel(SrsImportUpdateCondition c) => switch (c) {
    SrsImportUpdateCondition.ifNewer => t.srs_import_update_if_newer,
    SrsImportUpdateCondition.always => t.srs_import_update_always,
    SrsImportUpdateCondition.never => t.srs_import_update_never,
  };

  List<AdaptiveSettingsPickerOption<SrsImportUpdateCondition>>
  get _conditionOptions =>
      <AdaptiveSettingsPickerOption<SrsImportUpdateCondition>>[
        for (final SrsImportUpdateCondition c
            in SrsImportUpdateCondition.values)
          AdaptiveSettingsPickerOption<SrsImportUpdateCondition>(
            value: c,
            label: _conditionLabel(c),
          ),
      ];

  /// 「更新」组的一项：设置行 + 右侧「恢复默认」。
  Widget _withReset({
    required Key key,
    required Widget row,
    required bool isDefault,
    required VoidCallback onReset,
  }) {
    return Row(
      key: key,
      children: <Widget>[
        Expanded(child: row),
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: FushiIconButton(
            icon: FushiIcons.undo,
            tooltip: t.srs_import_reset_default,
            enabled: !isDefault,
            onTap: onReset,
          ),
        ),
      ],
    );
  }

  Future<void> _showHelp() {
    final ThemeData theme = Theme.of(context);
    Widget item(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
    return showAppDialog<void>(
      context: context,
      builder: (BuildContext helpContext) => FushiAlertDialog(
        title: Text(t.srs_import_options_title),
        content: SizedBox(
          width: SrsImportOptionsDialog.contentWidth,
          child: SingleChildScrollView(
            child: Column(
              key: const ValueKey<String>('srs-import-options-help'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                item(
                  t.srs_import_with_scheduling,
                  t.srs_import_with_scheduling_help,
                ),
                item(
                  t.srs_import_with_deck_configs,
                  t.srs_import_with_deck_configs_help,
                ),
                item(
                  t.srs_import_merge_notetypes,
                  t.srs_import_merge_notetypes_help,
                ),
                item(t.srs_import_update_notes, t.srs_import_update_notes_help),
                item(
                  t.srs_import_update_notetypes,
                  t.srs_import_update_notetypes_help,
                ),
                if (widget.wholeCollection)
                  Text(
                    t.srs_import_colpkg_note,
                    style: theme.textTheme.bodyMedium,
                  ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          FushiDialogAction(
            label: t.dialog_ok,
            kind: FushiDialogActionKind.primary,
            autofocus: true,
            onPressed: () => Navigator.of(helpContext).pop(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsAnkiImportOptions o = _options;
    // 手机宽度：下拉换到标题下方整行（行内时被「恢复默认」再挤掉一截，DropdownMenu
    // 只剩 ~120 宽，「较新时」都被截成「较新」）。
    final bool narrow = MediaQuery.sizeOf(context).width < 600;
    int step = 0;
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: step++, child: child);

    final Size screen = MediaQuery.sizeOf(context);
    final double insetX = (screen.width * 0.05).clamp(16.0, 40.0);
    final bool twoColumn = srsIsShortLandscape(BoxConstraints.tight(screen));
    final List<Widget> basic = <Widget>[
      if (widget.wholeCollection) ...<Widget>[
        stagger(FushiInlineNotice(message: t.srs_import_colpkg_note)),
        SizedBox(height: tokens.spacing.gap),
      ],
      stagger(
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('srs-import-with-scheduling'),
              title: t.srs_import_with_scheduling,
              value: o.withScheduling,
              onChanged: (bool v) => _set(o.copyWith(withScheduling: v)),
            ),
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('srs-import-with-deck-configs'),
              title: t.srs_import_with_deck_configs,
              value: o.withDeckConfigs,
              onChanged: (bool v) => _set(o.copyWith(withDeckConfigs: v)),
            ),
          ],
        ),
      ),
    ];
    final Widget updates = stagger(
      AdaptiveSettingsSection(
        title: t.srs_import_section_updates,
        titlePlacement: SettingsSectionTitlePlacement.inside,
        collapsible: true,
        children: <Widget>[
          _withReset(
            key: const ValueKey<String>('srs-import-merge-notetypes'),
            isDefault: o.mergeNoteTypes == _defaults.mergeNoteTypes,
            onReset: () =>
                _set(o.copyWith(mergeNoteTypes: _defaults.mergeNoteTypes)),
            row: AdaptiveSettingsSwitchRow(
              // 行宽被右侧「恢复默认」占去 52：声明开关实宽，开关与
              // 同组其它行一样留在标题右侧，不被挤到标题下方。
              trailingWidth: kSettingsRowIntrinsicTrailingWidth,
              title: t.srs_import_merge_notetypes,
              value: o.mergeNoteTypes,
              onChanged: (bool v) => _set(o.copyWith(mergeNoteTypes: v)),
            ),
          ),
          _withReset(
            key: const ValueKey<String>('srs-import-update-notes'),
            isDefault: o.updateNotes == _defaults.updateNotes,
            onReset: () => _set(o.copyWith(updateNotes: _defaults.updateNotes)),
            row: AdaptiveSettingsPickerRow<SrsImportUpdateCondition>(
              title: t.srs_import_update_notes,
              options: _conditionOptions,
              selected: o.updateNotes,
              materialWidth: 160,
              controlBelow: narrow,
              onChanged: (SrsImportUpdateCondition c) =>
                  _set(o.copyWith(updateNotes: c)),
            ),
          ),
          _withReset(
            key: const ValueKey<String>('srs-import-update-notetypes'),
            isDefault: o.updateNoteTypes == _defaults.updateNoteTypes,
            onReset: () =>
                _set(o.copyWith(updateNoteTypes: _defaults.updateNoteTypes)),
            row: AdaptiveSettingsPickerRow<SrsImportUpdateCondition>(
              title: t.srs_import_update_notetypes,
              options: _conditionOptions,
              selected: o.updateNoteTypes,
              materialWidth: 160,
              controlBelow: narrow,
              onChanged: (SrsImportUpdateCondition c) =>
                  _set(o.copyWith(updateNoteTypes: c)),
            ),
          ),
        ],
      ),
    );
    return FushiAlertDialog(
      // 窄屏收窄对话框外边距（与 [FushiDialogFrame] 同一条比例：屏宽 5%，16～40）：
      // 共享默认的 40 在手机上白丢 80dp，开关标签「导入所有学习进度信息」因此折出
      // 一个孤字。
      insetPadding: EdgeInsets.symmetric(horizontal: insetX, vertical: 24),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(t.srs_import_options_title),
                const SizedBox(height: 2),
                Text(
                  widget.fileName,
                  key: const ValueKey<String>('srs-import-options-file'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FushiIconButton(
            key: const ValueKey<String>('srs-import-options-help-button'),
            icon: FushiIcons.help,
            tooltip: t.srs_import_options_help,
            onTap: _showHelp,
          ),
        ],
      ),
      content: SizedBox(
        width: twoColumn
            ? math.min(
                SrsImportOptionsDialog.contentWidth * 2,
                screen.width - insetX * 2 - 48,
              )
            : SrsImportOptionsDialog.contentWidth,
        child: SingleChildScrollView(
          child: FushiEntranceScope(
            child: twoColumn
                // 手机横屏（又宽又矮）：基础开关与「更新」两组并排，不必在 ~250 高的
                // 正文里上下滚。
                ? Row(
                    key: const ValueKey<String>('srs-import-options'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: tokens.spacing.gap * 2,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          key: const ValueKey<String>(
                            'srs-import-options-basic',
                          ),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: basic,
                        ),
                      ),
                      Expanded(
                        key: const ValueKey<String>(
                          'srs-import-options-updates',
                        ),
                        child: updates,
                      ),
                    ],
                  )
                : Column(
                    key: const ValueKey<String>('srs-import-options'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      ...basic,
                      SizedBox(height: tokens.spacing.gap),
                      updates,
                    ],
                  ),
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs-import-confirm'),
          label: t.srs_import,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(_options),
        ),
      ],
    );
  }
}
