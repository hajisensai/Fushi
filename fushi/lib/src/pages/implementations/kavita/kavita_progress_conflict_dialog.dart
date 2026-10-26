/// 打开 Kavita 书时本机与服务器进度分叉：问用户保留哪一边。
///
/// 返回 [KavitaSyncAction.adoptServer] / [KavitaSyncAction.pushLocal]；点空白 /
/// 返回键按「保留本机」处理（不丢本机进度、也不覆盖服务器——`pushLocal` 在调用方
/// 才会真的推）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/utils.dart';

Future<KavitaSyncAction> showKavitaProgressConflictDialog(
  BuildContext context, {
  required int localSection,
  required int serverSection,
}) async {
  final KavitaSyncAction? choice = await showDialog<KavitaSyncAction>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      key: const ValueKey<String>('kavita-progress-conflict'),
      title: Text(t.kavita_progress_conflict_title),
      content: Text(
        t.kavita_progress_conflict_body(
          local: localSection + 1,
          server: serverSection + 1,
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('kavita-progress-conflict-local'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(KavitaSyncAction.pushLocal),
          child: Text(t.kavita_progress_conflict_use_local),
        ),
        FushiTextButton(
          key: const ValueKey<String>('kavita-progress-conflict-server'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(KavitaSyncAction.adoptServer),
          child: Text(t.kavita_progress_conflict_use_server),
        ),
      ],
    ),
  );
  return choice ?? KavitaSyncAction.pushLocal;
}
