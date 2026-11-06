// BUG-3684 原始路径（Windows runner，手动跑）：复习模块开着 + 本机开互联 host（同步走
// `SrsSyncScheduler.localDirectory`）→ 导入约 1.2 万张卡的 apkg → 打开浏览页 → 跑同步轮，
// 量 UI isolate 的最长单段阻塞（1 ms 周期计时器两次触发的最大间隔；看门狗判卡死的就是它）。
// 结果打 `[srs-large-sync]` 行。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_large_library_sync_itest.dart `
//     -DartDefine @('FUSHI_PROBE_APKG=C:/path/bench12k.apkg')
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_import_entry.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart'
    show FushiServerStartError, FushiServerStartOutcome;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/srs/apkg/srs_import_report.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _apkg = String.fromEnvironment('FUSHI_PROBE_APKG');

void _log(String line) {
  final String full = '[srs-large-sync] $line';
  debugPrint(full);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'srs_large_sync_probe.txt'),
  ).writeAsStringSync('$full\n', mode: FileMode.append, flush: true);
}

/// UI isolate 事件循环的单段阻塞探针。
class _StallProbe {
  _StallProbe() {
    _sw.start();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final int now = _sw.elapsedMilliseconds;
      final int gap = now - _last;
      if (gap > _max) _max = gap;
      if (gap >= 100) _over100++;
      _last = now;
    });
  }

  final Stopwatch _sw = Stopwatch();
  late final Timer _timer;
  int _last = 0;
  int _max = 0;
  int _over100 = 0;

  /// 取本段统计并清零。
  String take() {
    final String s = 'maxGap=${_max}ms gaps>=100ms=$_over100';
    _max = 0;
    _over100 = 0;
    _last = _sw.elapsedMilliseconds;
    return s;
  }

  void stop() => _timer.cancel();
}

/// 一边等 [future] 一边按帧 pump（让 UI 真在跑），返回结果。
Future<T> _pumpUntil<T>(WidgetTester tester, Future<T> future) async {
  bool done = false;
  unawaited(
    future.then((_) {}, onError: (Object _) {}).whenComplete(() => done = true),
  );
  while (!done) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return future;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('大库 + 互联 host：浏览页与同步轮不卡 UI', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await tester.pump(const Duration(seconds: 1));
    final ProviderContainer container = ProviderScope.containerOf(
      appModel.navigatorKey.currentContext!,
    );
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    final SrsMediaStore media = (await container.read(
      srsMediaStoreProvider.future,
    ))!;
    final SrsAppRuntime runtime = container.read(srsAppRuntimeProvider)!;

    // 用户自己开着的 Fushi 占着默认互联端口（不碰它）：隔离库里换一个端口。
    await SyncRepository(appModel.database).setServerPort(38999);
    final FushiServerStartOutcome outcome = await _pumpUntil(
      tester,
      appModel.syncServerController.start(),
    );
    _log(
      'host start outcome=$outcome '
      '${outcome is FushiServerStartError ? outcome.message : ""}',
    );
    _log(
      'host running=${appModel.syncServerController.isRunning} '
      'clientSyncRoot=${appModel.syncServerController.clientSyncRoot}',
    );
    if (appModel.syncServerController.clientSyncRoot == null) {
      _log('RESULT host did not start; original path not reproducible');
      return;
    }

    final _StallProbe probe = _StallProbe();
    final Stopwatch clock = Stopwatch()..start();
    final SrsImportReport report = await _pumpUntil(
      tester,
      runSrsAnkiImport(store: store, media: media, file: File(_apkg)),
    );
    container.read(srsRevisionProvider.notifier).state++;
    _log(
      'import ${clock.elapsedMilliseconds}ms report=${srsImportReportLines(report).join(" | ")} '
      '${probe.take()}',
    );

    clock.reset();
    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => const SrsBrowsePage(),
        ),
      ),
    );
    for (int i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    _log('browse open+2.4s ${probe.take()}');
    await captureFlutterFrame(tester, 'large-01-browse');

    for (int round = 0; round < 3; round++) {
      clock.reset();
      final Future<SrsSyncNowResult> sync = runtime.syncNow();
      // 同步进行中继续操作浏览页：方向键 / 翻页键滚列表。
      int keys = 0;
      bool done = false;
      unawaited(sync.whenComplete(() => done = true));
      while (!done) {
        await tester.sendKeyEvent(
          keys.isEven
              ? LogicalKeyboardKey.pageDown
              : LogicalKeyboardKey.arrowDown,
        );
        keys++;
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      final SrsSyncNowResult r = await sync;
      _log(
        'sync#$round ${clock.elapsedMilliseconds}ms ran=${r.ran} '
        'errors=${r.errors} keys=$keys ${probe.take()}',
      );
    }
    await captureFlutterFrame(tester, 'large-02-browse-after-sync');

    // 「清空卡组仍卡」：删掉卡最多的那个牌组（连卡一起删 = 软删 + 墓碑），再同步一轮。
    final List<SrsDeckSummary> decks = await store.deckSummaries();
    decks.sort(
      (SrsDeckSummary a, SrsDeckSummary b) =>
          b.totalCards.compareTo(a.totalCards),
    );
    clock.reset();
    final List<String> deleted = await _pumpUntil(
      tester,
      store.deleteDeck(decks.first.deck.id, deleteCards: true),
    );
    container.read(srsRevisionProvider.notifier).state++;
    _log(
      'delete deck ${decks.first.fullName} (${decks.first.totalCards} cards, '
      '${deleted.length} notes) ${clock.elapsedMilliseconds}ms ${probe.take()}',
    );
    clock.reset();
    final SrsSyncNowResult after = await _pumpUntil(tester, runtime.syncNow());
    _log(
      'sync after delete ${clock.elapsedMilliseconds}ms ran=${after.ran} '
      'errors=${after.errors} ${probe.take()}',
    );
    await captureFlutterFrame(tester, 'large-03-after-delete-sync');
    probe.stop();
  }, skip: _apkg.isEmpty);
}
