import 'package:flutter/material.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/utils.dart';

/// 「今日」重置时刻（整点）编辑弹窗：统计中心页头「重置时刻」按钮的落点。
///
/// 这个整点是 `FushiDatabase.statDayResetHour`——阅读 / 观看 / 游戏三域学习段
/// 派生 dateKey 的**唯一**输入，所以它是统计中心的设置而不是某一域的：原先放在
/// 「阅读」设置页的「阅读统计」分组里，视频 / 游戏用户根本找不到（用户 2026-09-18
/// 要求挪到统计中心并配文字说明）。写穿走 [AppModel.setStatDayResetHour]（偏好 +
/// 镜像到 DB 静态量），与原设置项同一路径；改完只影响之后写入的段，历史段不重分桶，
/// 所以关掉弹窗不需要重聚合页面。
///
/// 行本体复用设置页同款 [AdaptiveSettingsStepperRow]：键盘 / 手柄左右键调值、
/// 单焦点停靠语义与设置页一致，说明文案作为行副标题常驻而不是藏进 tooltip。
@visibleForTesting
class StatDayResetHourDialog extends StatefulWidget {
  const StatDayResetHourDialog({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<StatDayResetHourDialog> createState() => _StatDayResetHourDialogState();
}

class _StatDayResetHourDialogState extends State<StatDayResetHourDialog> {
  late int _hour = widget.appModel.statDayResetHour;

  /// `HH:00`——只取整点（v92 学习段不跨整点边界，天边界落在整点上永远不会撕裂
  /// 一个段），与原阅读设置项的外显格式一致。
  static String formatHour(double value) =>
      '${value.round().toString().padLeft(2, '0')}:00';

  Future<void> _onChanged(double value) async {
    final int next = value.round();
    await widget.appModel.setStatDayResetHour(next);
    if (!mounted) return;
    setState(() => _hour = widget.appModel.statDayResetHour);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.stat_center_day_reset_action),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      // 设置行默认活在无界高的列表里；弹窗给的是有界高，不套滚动容器它会把
      // 高度撑满整个对话框（与 showStatGoalEditDialog 同一处理）。定宽 480 让
      // AlertDialog 的 IntrinsicWidth 不必向行内的 LayoutBuilder 要固有宽。
      content: SingleChildScrollView(
        child: SizedBox(
          width: 480,
          child: AdaptiveSettingsStepperRow(
            title: t.stat_center_day_reset_hour,
            subtitle: t.stat_center_day_reset_hour_hint,
            icon: Icons.update_outlined,
            showIcon: true,
            value: _hour.toDouble(),
            step: 1,
            min: PreferencesRepository.statDayResetHourMin.toDouble(),
            max: PreferencesRepository.statDayResetHourMax.toDouble(),
            format: formatHour,
            onChanged: _onChanged,
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}

/// 弹出「今日」重置时刻弹窗。值在弹窗内即改即写穿，关闭不返回结果。
Future<void> showStatDayResetHourDialog(
  BuildContext context,
  AppModel appModel,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        StatDayResetHourDialog(appModel: appModel),
  );
}
