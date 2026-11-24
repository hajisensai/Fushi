/// 启动后台跑一次存量小说出处坐标迁移（[runCardSourceRelocationScope]，拍板 hSZjfrcejt）。
///
/// 制卡历史每台设备一份，总要跑；Fushi 复习只在模块开着、当前 profile 的库打得开时跑（模块
/// 后来才打开 / 换了 profile 的，下次启动补上——状态按 profile 分开记）。做完的范围有改动或
/// 有定位不到的，弹一条汇总提示（修了几张 / 没定位到几张）；完整报告留在状态文件里。
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

  CardSourceRelocationReport report = const CardSourceRelocationReport();
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
      );
  if (history != null) report = report + history;

  final SrsDbStore? store = await SrsAppHost.current?.readStore();
  if (store != null) {
    final CardSourceRelocationReport? srs = await runCardSourceRelocationScope(
      scope: cardSourceRelocationSrsScope(store.profileUid),
      stateFile: stateFile,
      loadItems: () => loadSrsNoteRelocationItems(
        store,
        extractDirOf: (CardSourceLink link) async =>
            extractDirOfRow(await resolveCardSourceBook(db, link)),
      ),
      relocate: relocateInBackgroundIsolate,
    );
    if (srs != null) report = report + srs;
  }

  debugPrint('[CardSourceRelocation] $report');
  if (report.relocated == 0 && report.notLocated == 0) return;
  FushiToast.show(
    msg: t.card_source_relocation_report(
      fixed: report.relocated,
      missed: report.notLocated,
    ),
    toastLength: Toast.LENGTH_LONG,
    severity: ToastSeverity.info,
  );
}
