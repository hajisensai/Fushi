/// 「导出（.apkg）」的选项对话框（与导入选项对话框对称；所有者 2026-10-20：「导出同理，
/// 支持是否兼容 anki 等开关，这些开关都会记忆」）。
///
/// 三个开关：学习进度（with_scheduling）/ 牌组预设与 FSRS 参数（with_deck_configs）/
/// 兼容 Anki（不附带 fushi-ext）。范围里有 FSRS-7 牌组且带预设时，内联提示「Anki 里会
/// 改用 FSRS-6」（取代此前单独弹的确认框）。上次的选择记在偏好
/// [kSrsExportOptionsPrefKey] 里（见 [readSrsExportOptions]）。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/apkg/srs_export_options.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

/// 偏好键：上次导出 Anki 包时的选项（String，[SrsAnkiExportOptions.toJson] 的 JSON）。
/// 与导入选项同理是普通偏好（随 Profile 快照 / 备份走），不进复习的事件存储。
const String kSrsExportOptionsPrefKey = 'srs_export_anki_options';

/// 读上次的选择；没有 / 坏值回落到默认值（= 此前唯一的导出行为）。
SrsAnkiExportOptions readSrsExportOptions(PrefStore prefs) {
  final Object? raw = prefs.getPref(kSrsExportOptionsPrefKey, defaultValue: '');
  if (raw is! String || raw.isEmpty) return const SrsAnkiExportOptions();
  try {
    final Object? json = jsonDecode(raw);
    if (json is Map) {
      return SrsAnkiExportOptions.fromJson(json.cast<String, Object?>());
    }
  } on FormatException {
    // 坏值：按默认值处理，下次确认时覆盖。
  }
  return const SrsAnkiExportOptions();
}

Future<void> writeSrsExportOptions(
  PrefStore prefs,
  SrsAnkiExportOptions options,
) => prefs.setPref(kSrsExportOptionsPrefKey, jsonEncode(options.toJson()));

/// 弹出选项对话框；取消返回 null。[usesFsrs7] = 导出范围里有 FSRS-7 牌组。
Future<SrsAnkiExportOptions?> showSrsExportOptionsDialog({
  required BuildContext context,
  required SrsAnkiExportOptions initial,
  required bool usesFsrs7,
}) => showAppDialog<SrsAnkiExportOptions>(
  context: context,
  builder: (BuildContext dialogContext) =>
      SrsExportOptionsDialog(initial: initial, usesFsrs7: usesFsrs7),
);

class SrsExportOptionsDialog extends StatefulWidget {
  const SrsExportOptionsDialog({
    required this.initial,
    required this.usesFsrs7,
    super.key,
  });

  final SrsAnkiExportOptions initial;
  final bool usesFsrs7;

  /// 对话框正文宽度（与导入选项对话框同档）。
  static const double contentWidth = 520;

  @override
  State<SrsExportOptionsDialog> createState() => _SrsExportOptionsDialogState();
}

class _SrsExportOptionsDialogState extends State<SrsExportOptionsDialog> {
  late SrsAnkiExportOptions _options = widget.initial;

  void _set(SrsAnkiExportOptions next) => setState(() => _options = next);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsAnkiExportOptions o = _options;
    final Size screen = MediaQuery.sizeOf(context);
    final double insetX = (screen.width * 0.05).clamp(16.0, 40.0);
    int step = 0;
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: step++, child: child);
    return FushiAlertDialog(
      insetPadding: EdgeInsets.symmetric(horizontal: insetX, vertical: 24),
      title: Text(t.srs_export_options_title),
      content: SizedBox(
        width: SrsExportOptionsDialog.contentWidth,
        child: SingleChildScrollView(
          child: FushiEntranceScope(
            child: Column(
              key: const ValueKey<String>('srs-export-options'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                stagger(
                  AdaptiveSettingsSection(
                    children: <Widget>[
                      AdaptiveSettingsSwitchRow(
                        key: const ValueKey<String>(
                          'srs-export-with-scheduling',
                        ),
                        title: t.srs_export_with_scheduling,
                        subtitle: t.srs_export_with_scheduling_desc,
                        subtitleMaxLines: 3,
                        value: o.withScheduling,
                        onChanged: (bool v) =>
                            _set(o.copyWith(withScheduling: v)),
                      ),
                      AdaptiveSettingsSwitchRow(
                        key: const ValueKey<String>(
                          'srs-export-with-deck-configs',
                        ),
                        title: t.srs_export_with_deck_configs,
                        subtitle: t.srs_export_with_deck_configs_desc,
                        subtitleMaxLines: 3,
                        value: o.withDeckConfigs,
                        onChanged: (bool v) =>
                            _set(o.copyWith(withDeckConfigs: v)),
                      ),
                      AdaptiveSettingsSwitchRow(
                        key: const ValueKey<String>(
                          'srs-export-anki-compatible',
                        ),
                        title: t.srs_export_anki_compatible,
                        subtitle: t.srs_export_anki_compatible_desc,
                        subtitleMaxLines: 4,
                        value: o.ankiCompatible,
                        onChanged: (bool v) =>
                            _set(o.copyWith(ankiCompatible: v)),
                      ),
                    ],
                  ),
                ),
                if (widget.usesFsrs7 && o.withDeckConfigs) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  stagger(
                    FushiInlineNotice(
                      key: const ValueKey<String>('srs-export-fsrs7-note'),
                      message: t.srs_export_fsrs7_note,
                    ),
                  ),
                ],
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
          key: const ValueKey<String>('srs-export-confirm'),
          label: t.srs_export_apkg,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(_options),
        ),
      ],
    );
  }
}
