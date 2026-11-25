/// 降级屏 / 主库损坏屏上的「恢复更新前的数据」（设计
/// `docs/specs/2026-11-25-auto-backup-restore-points.md` 第一层，D5）。
///
/// 列出本版本能打开的更新前还原点（时间、schema 变化、大小）；点一项先确认（说明此后
/// 的改动会丢、当前库另存为还原点），再离线换库并重启。没有可用的还原点时整块不显示。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 还原点的显示时间（本地时区）。
String restorePointDisplayDate(RestorePoint point) =>
    FushiTimeFormat.dateHourMinute(point.createdAt.toLocal());

/// 「恢复更新前的数据」区块。
class RestorePointRollbackPanel extends StatefulWidget {
  const RestorePointRollbackPanel({
    required this.loadPoints,
    required this.companionOf,
    required this.onRollback,
    required this.onRestart,
    super.key,
  });

  /// 可回滚的还原点（新的在前）；挂载时读一次。
  final List<RestorePoint> Function() loadPoints;

  /// 与某个主库还原点一起换回的复习库还原点（确认框里提一句）。
  final RestorePoint? Function(RestorePoint point) companionOf;

  /// 离线换库；失败抛出。
  final Future<void> Function(RestorePoint point) onRollback;

  /// 换完之后重启 app。
  final Future<void> Function() onRestart;

  @override
  State<RestorePointRollbackPanel> createState() =>
      _RestorePointRollbackPanelState();
}

class _RestorePointRollbackPanelState extends State<RestorePointRollbackPanel> {
  late final List<RestorePoint> _points = _load();
  bool _running = false;
  String? _error;

  List<RestorePoint> _load() {
    try {
      return widget.loadPoints();
    } catch (e, stack) {
      ErrorLogService.instance.log('RestorePointRollbackPanel.load', e, stack);
      return const <RestorePoint>[];
    }
  }

  Future<void> _confirmAndRun(RestorePoint point) async {
    final RestorePoint? companion = widget.companionOf(point);
    final String body = companion == null
        ? t.db_restore_point_confirm_body
        : '${t.db_restore_point_confirm_body}\n\n${t.db_restore_point_confirm_srs}';
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.db_restore_point_confirm_title(
        date: restorePointDisplayDate(point),
      ),
      message: body,
      confirmLabel: t.db_restore_point_confirm_action,
      icon: FushiIcons.history,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await widget.onRollback(point);
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'RestorePointRollbackPanel.rollback',
        e,
        stack,
      );
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e';
      });
      return;
    }
    await widget.onRestart();
  }

  @override
  Widget build(BuildContext context) {
    if (_points.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return ConstrainedBox(
      key: const ValueKey<String>('restore_point_rollback_panel'),
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: 24),
          Text(
            t.db_restore_point_rollback_title,
            style: theme.textTheme.titleMedium?.copyWith(color: cs.onSurface),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            t.db_restore_point_rollback_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FushiEntranceScope(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < _points.length; i++)
                  FushiStaggeredEntrance(
                    index: i,
                    child: FushiPressScale(
                      enabled: !_running,
                      child: FushiListItem(
                        key: ValueKey<String>('restore_point_${_points[i].id}'),
                        leading: const FushiIcon(FushiIcons.history),
                        title: Text(
                          t.db_restore_point_item_title(
                            date: restorePointDisplayDate(_points[i]),
                          ),
                        ),
                        subtitle: Text(
                          t.db_restore_point_item_subtitle(
                            from: _points[i].fromSchema,
                            to: _points[i].toSchema,
                            size: formatStorageBytes(_points[i].totalBytes),
                          ),
                        ),
                        trailing: const FushiIcon(FushiIcons.restoreBackup),
                        autofocus: i == 0,
                        onTap: _running
                            ? null
                            : () => _confirmAndRun(_points[i]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_running) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const SizedBox.square(
                  dimension: 18,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(t.db_restore_point_rollback_running),
              ],
            ),
          ],
          if (_error case final String error) ...<Widget>[
            const SizedBox(height: 12),
            SelectableText(
              t.db_restore_point_rollback_failed(error: error),
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
