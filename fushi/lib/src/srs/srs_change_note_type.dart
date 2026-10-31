/// 「更改笔记类型」的公共入口（笔记编辑页的类型行、浏览页的批量操作共用）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_change_note_type_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_legacy_lapis_migration_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 对 [noteIds]（必须是同一个源笔记类型）走一遍「更改笔记类型」：
/// 选目标类型 → 字段映射 → 卡片模板映射 → 确认 → 写入（经事件存储，可同步、可按冲突规则合并）。
///
/// 返回 true = 已更改（调用方据此重读列表；[srsRevisionProvider] 也已递增）；
/// false = 用户取消、笔记的源类型不一致（给出提示）或没有可换的目标类型（给出提示）。
/// 需要 [context] 在 [ProviderScope] 之下。
Future<bool> showSrsChangeNoteTypeFlow(
  BuildContext context,
  List<String> noteIds, {
  String? initialTargetId,
  Map<String, String?>? initialFieldMap,
  Map<String, String?>? initialTemplateMap,
}) async {
  if (noteIds.isEmpty) return false;
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final SrsDbStore? store;
  try {
    store = await container.read(srsStoreProvider.future);
  } catch (e, stack) {
    ErrorLogService.instance.log('showSrsChangeNoteTypeFlow.store', e, stack);
    return false;
  }
  if (store == null || !context.mounted) return false;
  final SrsNoteTypeView from;
  try {
    from = await store.sourceTypeOf(noteIds);
  } on ArgumentError {
    FushiToast.show(msg: t.srs_change_type_mixed);
    return false;
  }
  final List<SrsNoteTypeView> targets = <SrsNoteTypeView>[
    for (final SrsNoteTypeView v in await store.noteTypes())
      if (v.id != from.id) v,
  ];
  if (targets.isEmpty) {
    FushiToast.show(msg: t.srs_change_type_no_target);
    return false;
  }
  if (!context.mounted) return false;
  final bool? changed = await Navigator.of(context).push<bool>(
    adaptivePageRoute<bool>(
      context: context,
      // 沿用调用方的复习作用域（别的配置的笔记编辑页里改类型，见 srsInheritProviderScope）。
      builder: (_) => UncontrolledProviderScope(
        container: container,
        child: SrsChangeNoteTypePage(
          noteIds: List<String>.unmodifiable(noteIds),
          from: from,
          targets: targets,
          initialTargetId: initialTargetId,
          initialFieldMap: initialFieldMap,
          initialTemplateMap: initialTemplateMap,
        ),
      ),
    ),
  );
  return changed ?? false;
}

/// 浏览页批量菜单用的形状（[SrsChangeNoteTypeFlow]）：迁移选中的笔记。
Future<void> srsMigrateNotesToFushiCard(
  BuildContext context,
  List<String> noteIds,
) => showSrsMigrateToFushiCardFlow(context, noteIds: noteIds);

/// 「迁移到 Fushi 卡片」对话框的选择。
enum SrsMigrateChoice { migrate, adjust }

/// 旧 Lapis 变体 → Fushi 卡片 一键迁移（浏览页批量操作；笔记类型页走迁移页）。
///
/// [noteIds] 为 null = 打开「迁移旧 Lapis 到新模板」页（[openSrsLegacyLapisMigrationPage]：
/// 全部变体逐个预演 + 遗漏字段补迁），返回 false（页内自己刷新）。给了 [noteIds]：它们必须同属
/// 一种受支持的 Lapis 变体（内置 / 导入 / 改过名，见 [srsDetectLapisVariant]），先确认数量
/// （「迁移」按语义映射写入并逐条补同语义的空字段；「调整映射…」打开更改笔记类型页，目标与
/// 映射已预填）。复习历史经前身链接随迁。返回 true = 已迁移。
Future<bool> showSrsMigrateToFushiCardFlow(
  BuildContext context, {
  List<String>? noteIds,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final SrsDbStore? store;
  try {
    store = await container.read(srsStoreProvider.future);
  } catch (e, stack) {
    ErrorLogService.instance.log('showSrsMigrateToFushiCard.store', e, stack);
    return false;
  }
  if (store == null || !context.mounted) return false;
  if (noteIds == null) {
    await openSrsLegacyLapisMigrationPage(context);
    return false;
  }
  final List<String> ids = noteIds;
  if (ids.isEmpty) {
    FushiToast.show(msg: t.srs_migrate_fushi_none);
    return false;
  }
  final SrsNoteTypeView from;
  try {
    from = await store.sourceTypeOf(ids);
  } on ArgumentError {
    FushiToast.show(msg: t.srs_migrate_fushi_not_lapis);
    return false;
  }
  if (srsDetectLapisVariant(from) == null) {
    FushiToast.show(msg: t.srs_migrate_fushi_not_lapis);
    return false;
  }
  if (!context.mounted) return false;
  final SrsMigrateChoice? choice = await showAppDialog<SrsMigrateChoice>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: FushiDialogHeroIcon(icon: FushiIcons.swap),
      title: Text(t.srs_migrate_fushi_action),
      content: Text(t.srs_migrate_fushi_confirm(n: ids.length)),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs-migrate-adjust'),
          label: t.srs_migrate_fushi_adjust,
          kind: FushiDialogActionKind.secondary,
          onPressed: () =>
              Navigator.of(dialogContext).pop(SrsMigrateChoice.adjust),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs-migrate-confirm'),
          label: t.srs_migrate_fushi_action,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () =>
              Navigator.of(dialogContext).pop(SrsMigrateChoice.migrate),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return false;
  if (choice == SrsMigrateChoice.adjust) {
    final SrsNoteTypeView? to = await store.noteType(store.fushiCardNoteTypeId);
    if (to == null || !context.mounted) return false;
    return showSrsChangeNoteTypeFlow(
      context,
      ids,
      initialTargetId: to.id,
      initialFieldMap: srsLapisFieldPlan(store.profileUid, from, to).fieldMap,
      initialTemplateMap: srsLapisTemplateMap(from, to),
    );
  }
  try {
    final int n = await store.migrateLegacyLapis(from.id, noteIds: ids);
    container.read(srsRevisionProvider.notifier).state++;
    FushiToast.show(
      msg: t.srs_migrate_fushi_done(n: n),
      severity: ToastSeverity.success,
    );
    return true;
  } catch (e, stack) {
    ErrorLogService.instance.log('showSrsMigrateToFushiCard.apply', e, stack);
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    return false;
  }
}
