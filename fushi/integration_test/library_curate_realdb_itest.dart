// 库管家真库探针（Windows 离屏 runner，手动跑）：把一份真实库快照播种进隔离根，启动真
// app，手动跑一趟库管家，打印书 / 漫画补刮的结论、待确认身份数与缺作者的书数，并抓漫画
// 书架截图。用来验 BUG-5366 / BUG-5390（系列补刮认不出 / 认出了却写不进作者）。
//
//   .\tool\run_windows_itest.ps1 integration_test/library_curate_realdb_itest.dart `
//     -DartDefine @('FUSHI_PROBE_CURATE_SEED=C:/path/seed')
//
// 种子目录：fushi.db（一致性快照；先关掉同步与自动复查、删掉同步凭据）。只读拷贝，
// 不碰真库。
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/identity/app_pending_identity.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi_engine/media/identity/curator_pending_identity.dart';
import 'package:fushi_engine/media/identity/pending_identity.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _seed = String.fromEnvironment('FUSHI_PROBE_CURATE_SEED');

/// 探针行同时写进隔离根里的文件：runner 卡住被杀时 stdout 会丢。
void _log(String line) {
  debugPrint(line);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'curate_probe.txt'),
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

Future<int> _missingAuthorCount(AppModel appModel) async {
  final List<QueryRow> rows = await appModel.database
      .customSelect(
        "SELECT COUNT(*) AS n FROM epub_books WHERE COALESCE(TRIM(author), '') = ''",
      )
      .get();
  return rows.single.read<int>('n');
}

Future<PendingIdentityListing> _pending(AppModel appModel) =>
    curatorPendingIdentitySourceOf(
      db: appModel.database,
      prefs: appModel.prefsRepo,
      domain: CuratorPendingIdentityDomain.books,
    ).load();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真库：库管家补刮把系列漫画认出来并补上作者', (WidgetTester tester) async {
    expect(_seed, isNotEmpty, reason: '要传 FUSHI_PROBE_CURATE_SEED');
    final Directory support = fushiTestDirectory('app-support')!;
    for (final String name in <String>[
      'fushi.db',
      'fushi.db-wal',
      'fushi.db-shm',
    ]) {
      final File f = File(p.join(_seed, name));
      if (f.existsSync()) f.copySync(p.join(support.path, name));
    }

    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);

    LibraryCurator? curator;
    for (int i = 0; i < 60 && curator == null; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      curator = appLibraryCurator();
    }
    expect(curator, isNotNull, reason: '根组件应已登记库管家');

    final PendingIdentityListing before = await _pending(appModel);
    final int authorsBefore = await _missingAuthorCount(appModel);
    _log(
      '[curate-probe] before: pending=${before.pending.length} '
      'missingAuthor=$authorsBefore',
    );

    final LibraryCurateRun run =
        await tester.runAsync(
              () => curator!.run(trigger: LibraryCurateTrigger.manual),
            )
            as LibraryCurateRun;
    for (final LibraryCurateStageResult s in run.stages) {
      if (s.stage != LibraryCurateStage.scrapeBooks) continue;
      _log(
        '[curate-probe] scrape.books status=${s.status.name} '
        'changes=${s.changes} pending=${s.pending} requests=${s.requests} '
        'error=${s.error}',
      );
    }
    for (final LibraryCuratePendingItem item in run.pendingItems) {
      if (item.kind != 'book_scrape_pending') continue;
      _log(
        '[curate-probe] pending ${item.title} reason=${item.reason} '
        'ai=${item.ai} candidates=${item.candidates}',
      );
    }

    final PendingIdentityListing after = await _pending(appModel);
    final int authorsAfter = await _missingAuthorCount(appModel);
    _log(
      '[curate-probe] after: pending=${after.pending.length} '
      'missingAuthor=$authorsAfter',
    );
    for (final String like in <String>[
      '魔法少女にあこがれて%',
      '不揃いの連理%',
      '十歳の最強魔導師%',
      'バカに告白%',
      '行進子犬に恋文を%',
      '世界で一番おっぱいが好き%',
      '週に一度クラスメイトを買う話%',
    ]) {
      final List<QueryRow> rows = await appModel.database
          .customSelect(
            'SELECT title, author FROM epub_books WHERE title LIKE ? '
            'ORDER BY title LIMIT 1',
            variables: <Variable<Object>>[Variable<String>(like)],
          )
          .get();
      for (final QueryRow r in rows) {
        _log(
          '[curate-probe] book ${r.read<String>('title')} -> '
          'author=${r.readNullable<String>('author')}',
        );
      }
    }

    HomePage.debugSelectTab?.call(HomeTab.manga);
    await tester.pump(const Duration(seconds: 3));
    final ObserveShot shot = await captureFlutterFrame(tester, '01-manga');
    expect(shot.saved, isTrue);

    expect(authorsAfter, lessThan(authorsBefore), reason: '库管家应给缺作者的系列漫画补上作者');
  });
}
