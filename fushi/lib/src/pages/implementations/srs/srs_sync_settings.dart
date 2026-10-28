/// 复习页通往「同步与备份」/「Fushi 互联」设置的入口。
///
/// 复习数据没有单独的同步开关：它随已认证的云盘通道与已启用的互联通道一起同步（见
/// srs_sync_scheduler.dart）。复习页上只给去这两个设置分类的路，不另立一套开关。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart' show SrsRemoteProfile;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart' show SrsProfileConflict;
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

/// 用户对 profile 冲突（[SrsProfileConflict]）的选择。
sealed class SrsProfileConflictChoice {
  const SrsProfileConflictChoice();
}

/// 采用候选 [uid]（本机有笔记时并入）。
class SrsProfileConflictAdopt extends SrsProfileConflictChoice {
  const SrsProfileConflictAdopt(this.uid);
  final String uid;
}

/// 保持本机独立：这个位置的这组候选不再提示。
class SrsProfileConflictKeepSeparate extends SrsProfileConflictChoice {
  const SrsProfileConflictKeepSeparate();
}

/// 候选的副标题：最近更新时刻（有的话）+ uid 前 8 位（同名的几份靠它区分）。
String srsProfileCandidateSubtitle(SrsRemoteProfile c) {
  final int? at = c.updatedAt;
  String two(int v) => v.toString().padLeft(2, '0');
  final String? when = at == null
      ? null
      : () {
          final DateTime d = DateTime.fromMillisecondsSinceEpoch(at).toLocal();
          return '${d.year}-${two(d.month)}-${two(d.day)} '
              '${two(d.hour)}:${two(d.minute)}';
        }();
  return <String>[
    if (when != null) t.srs_sync_profile_conflict_updated(date: when),
    c.uid.length > 8 ? c.uid.substring(0, 8) : c.uid,
  ].join(' · ');
}

/// 同步位置里没法自动关联本机 profile（多个有数据的同名 profile，或两边都有笔记）：让用户选采用哪一份、保持本机
/// 独立，或稍后再说（返回 null）。本机有笔记时说明会并入、不丢数据。
Future<SrsProfileConflictChoice?> showSrsProfileConflictDialog(
  BuildContext context,
  SrsProfileConflict conflict,
) => showAppDialog<SrsProfileConflictChoice>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog(
    icon: const FushiDialogHeroIcon(icon: FushiIcons.cloudSync),
    title: Text(t.srs_sync_profile_conflict_title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.srs_sync_profile_conflict_body),
          const SizedBox(height: 8),
          Text(
            conflict.localHasNotes
                ? t.srs_sync_profile_conflict_merge_hint
                : t.srs_sync_profile_conflict_adopt_hint,
            style: Theme.of(dialogContext).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final SrsRemoteProfile c in conflict.candidates)
            FushiListTile(
              key: ValueKey<String>('srs-profile-conflict-${c.uid}'),
              title: c.displayName,
              subtitle: srsProfileCandidateSubtitle(c),
              icon: FushiIcons.cloudSync,
              selected: false,
              onTap: () => Navigator.of(
                dialogContext,
              ).pop(SrsProfileConflictAdopt(c.uid)),
            ),
        ],
      ),
    ),
    actions: <Widget>[
      FushiDialogAction(
        label: t.srs_sync_profile_conflict_later,
        kind: FushiDialogActionKind.secondary,
        onPressed: () => Navigator.of(dialogContext).pop(),
      ),
      FushiDialogAction(
        key: const ValueKey<String>('srs-profile-conflict-keep-separate'),
        label: t.srs_sync_profile_conflict_keep_separate,
        kind: FushiDialogActionKind.secondary,
        onPressed: () => Navigator.of(
          dialogContext,
        ).pop(const SrsProfileConflictKeepSeparate()),
      ),
    ],
  ),
);

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
