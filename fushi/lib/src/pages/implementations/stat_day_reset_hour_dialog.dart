import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 统计设置弹窗（2026-10-09 统计中心精简，PDF「第一行的四个按钮扔进设置」）：
/// 页头只剩一颗设置按钮，原先平铺的「重置时刻」与「清空统计」收进这里。
///
///  * 「今日」从几点开始：`FushiDatabase.statDayResetHour`——三域学习段派生 dateKey
///    的**唯一**输入，所以是统计中心的设置而不是某一域的（2026-09-18 从「阅读」
///    设置页挪来）。写穿走 [AppModel.setStatDayResetHour]（偏好 + 镜像到 DB 静态
///    量），即改即生效；只影响之后写入的段，历史段不重分桶。行本体复用设置页同款
///    [AdaptiveSettingsStepperRow]（键盘 / 手柄左右键调值）；
///  * 清空统计：清当前 tab 那一域（总览 = 三域），先关本弹窗再走调用方的确认流程；
///  * 副标题点明当前 Profile（v105 统计按 Profile 隔离，原在页头标题下）。
@visibleForTesting
class StatSettingsDialog extends StatefulWidget {
  const StatSettingsDialog({
    required this.appModel,
    super.key,
    this.settings,
    this.profileName,
  });

  final AppModel appModel;
  final StatTabSettings? settings;
  final String? profileName;

  /// `HH:00`——只取整点（v92 学习段不跨整点边界，天边界落在整点上永远不会撕裂
  /// 一个段）。
  static String formatHour(double value) =>
      '${value.round().toString().padLeft(2, '0')}:00';

  @override
  State<StatSettingsDialog> createState() => _StatSettingsDialogState();
}

class _StatSettingsDialogState extends State<StatSettingsDialog> {
  late int _hour = widget.appModel.statDayResetHour;

  Future<void> _onHourChanged(double value) async {
    await widget.appModel.setStatDayResetHour(value.round());
    if (!mounted) return;
    setState(() => _hour = widget.appModel.statDayResetHour);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final StatTabSettings? settings = widget.settings;
    final String? profile = widget.profileName;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.settings),
      title: Text(t.stat_center_settings),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 480,
          child: FushiEntranceScope(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (profile != null)
                  FushiStaggeredEntrance(
                    index: 0,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        tokens.spacing.card,
                        0,
                        tokens.spacing.card,
                        tokens.spacing.gap,
                      ),
                      child: Text(
                        t.stat_center_profile_scope(name: profile),
                        style: tokens.type.metadata.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                FushiStaggeredEntrance(
                  index: 1,
                  child: AdaptiveSettingsStepperRow(
                    title: t.stat_center_day_reset_hour,
                    subtitle: t.stat_center_day_reset_hour_hint,
                    icon: FushiIcons.schedule,
                    showIcon: true,
                    value: _hour.toDouble(),
                    step: 1,
                    min: PreferencesRepository.statDayResetHourMin.toDouble(),
                    max: PreferencesRepository.statDayResetHourMax.toDouble(),
                    format: StatSettingsDialog.formatHour,
                    onChanged: _onHourChanged,
                  ),
                ),
                if (settings != null)
                  FushiStaggeredEntrance(
                    index: 2,
                    child: FushiListItem(
                      key: const ValueKey<String>('stat-settings-clear-all'),
                      leading: FushiIcon(
                        FushiIcons.deleteSweep,
                        color: scheme.error,
                      ),
                      title: Text(
                        t.stat_clear_all,
                        style: TextStyle(color: scheme.error),
                      ),
                      onTap: settings.enabled
                          ? () {
                              Navigator.of(context).pop();
                              settings.onClearAll();
                            }
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_close,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// 弹出统计设置。值在弹窗内即改即写穿，关闭不返回结果。
Future<void> showStatSettingsDialog(
  BuildContext context,
  AppModel appModel, {
  StatTabSettings? settings,
  String? profileName,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => StatSettingsDialog(
      appModel: appModel,
      settings: settings,
      profileName: profileName,
    ),
  );
}
