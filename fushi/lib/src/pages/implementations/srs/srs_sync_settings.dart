/// 复习页通往「同步与备份」/「Fushi 互联」设置的入口。
///
/// 复习数据没有单独的同步开关：它随已认证的云盘通道与已启用的互联通道一起同步（见
/// srs_sync_scheduler.dart）。复习页上只给去这两个设置分类的路，不另立一套开关。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 复习数据随之同步的设置分类（按模块可见性过滤：同步模块关掉时一个也没有）。
List<SettingsDestination> srsSyncDestinations(ModuleVisibility modules) =>
    <SettingsDestination>[
          buildSyncBackupDestination(),
          buildInterconnectDestination(),
        ]
        .where(
          (SettingsDestination d) =>
              isSettingsDestinationVisible(d.id, modules),
        )
        .toList();

/// 分类的显示名。
String srsSyncDestinationLabel(SettingsDestination d) =>
    d.id == SettingsDestinationId.interconnect
    ? t.settings_destination_interconnect
    : t.settings_destination_sync_backup;

Future<void> openSrsSyncDestination(
  BuildContext context,
  SettingsDestination destination,
) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (_) => SettingsDetailPage(destination: destination),
  ),
);

/// 「立即同步」没有任何可用通道时：说明复习数据怎么同步，并直达两个设置分类。
Future<void> showSrsSyncSetupDialog(
  BuildContext context,
  ModuleVisibility modules,
) async {
  final List<SettingsDestination> destinations = srsSyncDestinations(modules);
  final SettingsDestination? picked = await showAppDialog<SettingsDestination>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.cloudSync),
      title: Text(t.srs_sync_no_backend),
      content: Text(t.srs_sync_setup_body),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          kind: FushiDialogActionKind.secondary,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
        for (final SettingsDestination d in destinations)
          FushiDialogAction(
            key: ValueKey<String>('srs-sync-setup-${d.id.name}'),
            label: srsSyncDestinationLabel(d),
            kind: FushiDialogActionKind.primary,
            autofocus: d == destinations.first,
            onPressed: () => Navigator.of(dialogContext).pop(d),
          ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  await openSrsSyncDestination(context, picked);
}

/// 备份页的说明：本机备份不上云；上云 / 跨设备走同步设置（附两个分类的入口）。
class SrsSyncSettingsNotice extends StatelessWidget {
  const SrsSyncSettingsNotice({super.key, required this.modules});

  final ModuleVisibility modules;

  @override
  Widget build(BuildContext context) {
    final List<SettingsDestination> destinations = srsSyncDestinations(modules);
    return FushiInlineNotice(
      key: const ValueKey<String>('srs-backup-cloud-hint'),
      icon: FushiIcons.cloudSync,
      message: t.srs_backup_cloud_hint,
      actions: <Widget>[
        for (final SettingsDestination d in destinations)
          FushiTextButton(
            key: ValueKey<String>('srs-backup-open-${d.id.name}'),
            onPressed: () => unawaited(openSrsSyncDestination(context, d)),
            child: Text(srsSyncDestinationLabel(d)),
          ),
      ],
    );
  }
}
