/// 「更改笔记类型」的公共入口（笔记编辑页的类型行、浏览页的批量操作共用）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_change_note_type_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/utils.dart';

/// 对 [noteIds]（必须是同一个源笔记类型）走一遍「更改笔记类型」：
/// 选目标类型 → 字段映射 → 卡片模板映射 → 确认 → 写入（经事件存储，可同步、可按冲突规则合并）。
///
/// 返回 true = 已更改（调用方据此重读列表；[srsRevisionProvider] 也已递增）；
/// false = 用户取消、笔记的源类型不一致（给出提示）或没有可换的目标类型（给出提示）。
/// 需要 [context] 在 [ProviderScope] 之下。
Future<bool> showSrsChangeNoteTypeFlow(
  BuildContext context,
  List<String> noteIds,
) async {
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
      builder: (_) => SrsChangeNoteTypePage(
        noteIds: List<String>.unmodifiable(noteIds),
        from: from,
        targets: targets,
      ),
    ),
  );
  return changed ?? false;
}
