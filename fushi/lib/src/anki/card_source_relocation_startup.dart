/// 启动后台跑一次存量小说出处坐标迁移（[runCardSourceRelocationScope]，拍板 hSZjfrcejt）。
///
/// 制卡历史每台设备一份，总要跑；Fushi 复习只在模块开着、当前 profile 的库打得开时跑（模块
/// 后来才打开 / 换了 profile 的，下次启动补上——状态按 profile 分开记）。做完的范围有改动或
/// 有定位不到的，弹一条提示（复习卡片与制卡历史分开报修了几条 / 没定位到几条，见
/// [cardSourceRelocationReportMessage]）；完整报告留在状态文件里。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_anki/fushi_anki.dart' show CardSourceLink;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/card_source_relocation_migration.dart';
import 'package:fushi/src/anki/card_source_router.dart'
    show resolveCardSourceBook;
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

bool _started = false;

/// 本进程只起一次；失败记日志，已完成的书已落进状态文件，下次启动接着做。
void scheduleCardSourceRelocationMigration(FushiDatabase db) {
  if (_started) return;
  _started = true;
  unawaited(
    _run(db).catchError((Object e, StackTrace stack) {
      ErrorLogService.instance.log('CardSourceRelocation', e, stack);
    }),
  );
}

Future<void> _run(FushiDatabase db) async {
  final CardSourceRelocationStateFile stateFile =
      await CardSourceRelocationStateFile.standard(
        await AppPaths.supportRootDirectory(),
      );
  Future<String?> extractDirOfRow(EpubBookRow? row) async {
    final String dir = row?.extractDir ?? '';
    return dir.isNotEmpty && await EpubStorage.bookDirExists(dir) ? dir : null;
  }

  void onBookError(String book, Object e, StackTrace stack) =>
      ErrorLogService.instance.log('CardSourceRelocation.book', e, stack);

  final CardSourceRelocationReport? history =
      await runCardSourceRelocationScope(
        scope: kCardSourceRelocationHistoryScope,
        stateFile: stateFile,
        loadItems: () => loadMinedSentenceRelocationItems(
          db,
          extractDirOf: (String bookKey) async =>
              extractDirOfRow(await db.getEpubBook(bookKey)),
        ),
        relocate: relocateInBackgroundIsolate,
        onBookError: onBookError,
      );

  CardSourceRelocationReport? srs;
  final SrsDbStore? store = await SrsAppHost.current?.readStore();
  if (store != null) {
    // 只要真写进了复习库就通知（复习界面重读、推给别的设备，与复习页内的写入同一条通路）——
    // 中途抛错（库被关 / 换代）时已写的那些也要推，不等下一次别的写入顺带。
    bool wrote = false;
    try {
      srs = await runCardSourceRelocationScope(
        scope: cardSourceRelocationSrsScope(store.profileUid),
        stateFile: stateFile,
        loadItems: () async => <CardSourceRelocationItem>[
          for (final CardSourceRelocationItem item
              in await loadSrsNoteRelocationItems(
                store,
                extractDirOf: (CardSourceLink link) async =>
                    extractDirOfRow(await resolveCardSourceBook(db, link)),
              ))
            CardSourceRelocationItem(
              bookGroup: item.bookGroup,
              request: item.request,
              write: (int offset, int length) async {
                final bool ok = await item.write(offset, length);
                if (ok) wrote = true;
                return ok;
              },
            ),
        ],
        relocate: relocateInBackgroundIsolate,
        onBookError: onBookError,
      );
    } finally {
      if (wrote) SrsAppHost.current?.notifyLocalWrite?.call();
    }
  }

  debugPrint('[CardSourceRelocation] history=$history srs=$srs');
  final String? message = cardSourceRelocationReportMessage(
    history: history,
    cards: srs,
  );
  if (message == null) return;
  FushiToast.show(
    msg: message,
    toastLength: Toast.LENGTH_LONG,
    severity: ToastSeverity.info,
  );
}

/// 迁移结束时的提示（null = 不用提示：没跑 / 全都已正确）。复习卡片与制卡历史分开报：
/// 同一张卡通常两边各一条，合成一个数会翻倍；只用外部 Anki 的用户只有制卡历史被修，
/// 报成「修了 N 张卡」会误以为 Anki 里的卡也好了。
String? cardSourceRelocationReportMessage({
  CardSourceRelocationReport? history,
  CardSourceRelocationReport? cards,
}) {
  bool worthTelling(CardSourceRelocationReport? r) =>
      r != null && (r.relocated > 0 || r.notLocated > 0);
  final List<String> lines = <String>[
    if (worthTelling(cards))
      t.card_source_relocation_report_cards(
        fixed: cards!.relocated,
        missed: cards.notLocated,
      ),
    if (worthTelling(history))
      t.card_source_relocation_report_history(
        fixed: history!.relocated,
        missed: history.notLocated,
      ),
  ];
  if (lines.isEmpty) return null;
  return <String>[t.card_source_relocation_report_title, ...lines].join('\n');
}
