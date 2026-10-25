/// 复习页通往「同步与备份」/「Fushi 互联」设置的入口。
///
/// 复习数据没有单独的同步开关：它随已认证的云盘通道与已启用的互联通道一起同步（见
/// srs_sync_scheduler.dart）。复习页上只给去这两个设置分类的路，不另立一套开关。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/src/models/app_model.dart';
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

/// 首次 v2 同步的确认（设计 §13 第 5 条）：升级后第一次同步前问一次，说明各设备的数据是「并入、不覆盖」。
///
/// 本机没有用户笔记（新装、只有内置行）时没什么可并的，直接记成已确认、不打扰。返回此刻是否已确认。
/// 「稍后」不记任何东西：同步暂停，下次进复习页或点「立即同步」再问。
Future<bool> ensureSrsFirstSyncConfirmed(
  BuildContext context,
  AppModel app,
  SrsDbStore? store,
) async {
  if (app.srsSync2MergeConfirmed) return true;
  if (store == null) return false;
  if (!await store.hasUserNotes()) {
    await app.setSrsSync2MergeConfirmed(true);
    return true;
  }
  if (!context.mounted) return false;
  final bool ok = await showFushiConfirmDialog(
    context: context,
    title: t.srs_sync_confirm_title,
    message: t.srs_sync_confirm_body,
    confirmLabel: t.srs_sync_confirm_start,
    cancelLabel: t.srs_sync_confirm_later,
    icon: FushiIcons.cloudSync,
  );
  if (!ok) return false;
  await app.setSrsSync2MergeConfirmed(true);
  return true;
}

/// 同步与历史页的说明：复习数据随已有的同步通道走（附两个分类的入口）。
class SrsSyncSettingsNotice extends StatelessWidget {
  const SrsSyncSettingsNotice({super.key, required this.modules});

  final ModuleVisibility modules;

  @override
  Widget build(BuildContext context) {
    final List<SettingsDestination> destinations = srsSyncDestinations(modules);
    return FushiInlineNotice(
      key: const ValueKey<String>('srs-sync-cloud-hint'),
      icon: FushiIcons.cloudSync,
      message: t.srs_timeline_cloud_hint,
      actions: <Widget>[
        for (final SettingsDestination d in destinations)
          FushiTextButton(
            key: ValueKey<String>('srs-sync-open-${d.id.name}'),
            onPressed: () => unawaited(openSrsSyncDestination(context, d)),
            child: Text(srsSyncDestinationLabel(d)),
          ),
      ],
    );
  }
}
