import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/external_reader_import_page.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_position_mapping.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_stat_segments.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 「第三方导入」（Hoshi Reader `.hoshi` 备份）真 app 端到端：真库、真 EpubImporter、真页面、真阅读器。
///
/// 输入是一份 Hoshi Reader（iOS / Android）「Settings › Backup › Books」导出的
/// `Books_*.hoshi`，外加一份由独立脚本从同一备份算出的期望值
/// `<备份>.expected.json`：`{"books": [{dir, title, archived, epub, chars, ms,
/// bookmark, bookmarkHref}, ...]}`（chars / ms 按与导入同一口径——日记录同 dateKey
/// 取最新、单日封顶 24h、会话剔除删除标记——求和）。备份含用户的书，不入库：
///   .\tool\run_windows_itest.ps1 integration_test/hoshi_import_e2e_itest.dart `
///     -DartDefine @('FUSHI_HOSHI_SAMPLE=C:/.../Books_x.hoshi')
///
/// 系统文件选择器是原生窗口、不在焦点树里，只有它经
/// [ExternalReaderImportPage.debugPickBackupPath] 替换；其余全部焦点驱动（Tab →
/// Enter），不做坐标点击。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Hoshi 备份：页面导入书 / 进度 / 统计 → 阅读器按导入位置打开 → 重复导入不变',
    (WidgetTester tester) async {
      const String samplePath = String.fromEnvironment('FUSHI_HOSHI_SAMPLE');
      expect(
        samplePath,
        isNotEmpty,
        reason: '需要 --dart-define FUSHI_HOSHI_SAMPLE',
      );
      expect(File(samplePath).existsSync(), isTrue, reason: samplePath);
      final List<Map<String, dynamic>> expected = <Map<String, dynamic>>[
        for (final dynamic b
            in (jsonDecode(File('$samplePath.expected.json').readAsStringSync())
                    as Map<String, dynamic>)['books']
                as List<dynamic>)
          b as Map<String, dynamic>,
      ];
      final List<Map<String, dynamic>> withEpub = <Map<String, dynamic>>[
        for (final Map<String, dynamic> b in expected)
          if (b['archived'] != true && b['epub'] != null) b,
      ];

      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await enableFocusNavigation(tester);
      final FushiDatabase db = appModel.database;
      final FocusDriver driver = FocusDriver(tester);

      ExternalReaderImportPage.debugPickBackupPath = () async => samplePath;
      try {
        appModel.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                ExternalReaderImportPage(appModel: appModel),
          ),
        );
        await _pumpFor(tester, const Duration(seconds: 2));
        expect(
          (await captureFlutterFrame(tester, 'hoshi-01-page')).nonBlank,
          isTrue,
        );

        // ── 第一次导入 ──────────────────────────────────────────────
        await _activateButton(tester, driver, t.hoshi_import_file_pick);
        expect(
          await _waitFor(tester, find.text(t.hoshi_import_run_start)),
          isTrue,
          reason: '扫描完应出现预览与「开始导入」',
        );
        debugPrint('[hoshi-e2e] preview: ${_visibleTexts(tester).join(' | ')}');
        await captureFlutterFrame(tester, 'hoshi-02-preview');

        final Stopwatch importClock = Stopwatch()..start();
        await _activateButton(tester, driver, t.hoshi_import_run_start);
        await _pumpFor(tester, const Duration(seconds: 3));
        await captureFlutterFrame(tester, 'hoshi-03-running');
        expect(
          await _waitFor(
            tester,
            find.text(t.hoshi_import_result_done),
            timeout: const Duration(minutes: 15),
          ),
          isTrue,
          reason: '导入应在 15 分钟内完成',
        );
        debugPrint(
          '[hoshi-e2e] import took ${importClock.elapsed.inSeconds}s; report: '
          '${_visibleTexts(tester).join(' | ')}',
        );
        await captureFlutterFrame(tester, 'hoshi-04-report');

        // ── 逐本核对：进库、统计总量、阅读位置落在 Hoshi 书签所在章 ──────
        Future<(int, int)> totals(String key) async {
          final List<StudySegmentRow> rows = await db.getStudySegmentsForMedia(
            mediaKind: kActivityMediaBook,
            mediaKey: key,
          );
          expect(
            rows.every(
              (StudySegmentRow r) =>
                  r.deviceId == kExternalReaderImportDeviceId,
            ),
            isTrue,
          );
          return (
            rows.fold<int>(0, (int a, StudySegmentRow r) => a + r.chars),
            rows.fold<int>(0, (int a, StudySegmentRow r) => a + r.durationMs),
          );
        }

        final Map<String, (int, int)> firstTotals = <String, (int, int)>{};
        final List<String> problems = <String>[];
        String? readerKey;
        int readerSection = -1;
        String? readerUid;
        for (final Map<String, dynamic> book in expected) {
          final String title = book['title'] as String;
          final String key = sanitizeTtuFilename(title);
          final (int chars, int ms) = await totals(key);
          firstTotals[key] = (chars, ms);
          if (chars != book['chars'] || ms != book['ms']) {
            problems.add(
              '$title: stats $chars/$ms != ${book['chars']}/${book['ms']}',
            );
          }
          final EpubBookRow? row = await db.getEpubBook(key);
          if (book['archived'] != true && book['epub'] != null && row == null) {
            problems.add('$title: not in library');
            continue;
          }
          final Map<String, dynamic>? bookmark =
              book['bookmark'] as Map<String, dynamic>?;
          final String? hoshiHref = book['bookmarkHref'] as String?;
          if (row == null || bookmark == null) continue;
          final ReaderPositionRow? pos = await db.getReaderPosition(row.uid);
          final List<FushiChapterRef> chapters = parseFushiChapterRefs(
            row.chaptersJson,
          );
          if (pos == null) {
            problems.add('$title: no position');
            continue;
          }
          final String fushiHref = chapters[pos.sectionIndex].href;
          final bool sameChapter =
              hoshiHref == null ||
              normalizeChapterHref(
                fushiHref,
              ).endsWith(normalizeChapterHref(hoshiHref));
          debugPrint(
            '[hoshi-e2e] ${sameChapter ? 'OK ' : 'BAD'} '
            'chars=$chars min=${ms ~/ 60000} sec=${pos.sectionIndex}/'
            '${chapters.length} norm=${pos.normCharOffset} '
            'charOffset=${pos.charOffset} hoshi=$hoshiHref | $title',
          );
          if (!sameChapter) {
            problems.add('$title: chapter $fushiHref != $hoshiHref');
          }
          if (pos.charOffset != -1) problems.add('$title: stale exact anchor');
          // 阅读器验收挑一本书签不在第 0 章、也没读完的书：恢复落空（回到开头）
          // 在它身上一眼可辨。
          if (readerKey == null &&
              pos.sectionIndex > 0 &&
              pos.sectionIndex < chapters.length - 1) {
            readerKey = key;
            readerSection = pos.sectionIndex;
            readerUid = row.uid;
          }
        }
        debugPrint(
          '[hoshi-e2e] problems=${problems.length} ${problems.join(' ; ')}',
        );
        expect(problems, isEmpty);
        expect((await db.getEpubBookMetas()).length, withEpub.length);

        // ── 第二次导入：同一份备份不应改变任何数字 ─────────────────────
        await _activateButton(tester, driver, t.hoshi_import_file_pick);
        expect(
          await _waitFor(tester, find.text(t.hoshi_import_run_start)),
          isTrue,
        );
        await _activateButton(tester, driver, t.hoshi_import_run_start);
        expect(
          await _waitFor(
            tester,
            find.text(t.hoshi_import_result_done),
            timeout: const Duration(minutes: 10),
          ),
          isTrue,
        );
        debugPrint(
          '[hoshi-e2e] report#2: ${_visibleTexts(tester).join(' | ')}',
        );
        expect(
          find.textContaining(
            t.hoshi_import_result_books(imported: 0, matched: withEpub.length),
          ),
          findsOneWidget,
        );
        for (final MapEntry<String, (int, int)> e in firstTotals.entries) {
          expect(await totals(e.key), e.value, reason: e.key);
        }
        expect((await db.getEpubBookMetas()).length, withEpub.length);
        await captureFlutterFrame(tester, 'hoshi-05-reimport');

        appModel.navigatorKey.currentState!.pop();
        await _pumpFor(tester, const Duration(seconds: 1));

        // ── 统计中心看得见导入的历史 ─────────────────────────────────
        appModel.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                const StatisticsCenterPage(initialTab: StatsCenterTab.reading),
          ),
        );
        await _pumpFor(tester, const Duration(seconds: 6));
        expect(
          (await captureFlutterFrame(
            tester,
            'hoshi-06-stats-reading',
          )).nonBlank,
          isTrue,
        );
        debugPrint(
          '[hoshi-e2e] stats: ${_visibleTexts(tester).take(60).join(' | ')}',
        );
        appModel.navigatorKey.currentState!.pop();
        await _pumpFor(tester, const Duration(seconds: 1));

        // ── 阅读器按导入的位置打开 ───────────────────────────────────
        expect(readerKey, isNotNull, reason: '备份里应有一本读到中间的书');
        await openBookViaProductionPath(tester, readerKey!);
        for (int i = 0; i < 120 && !readerWebViewReady(); i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(readerWebViewReady(), isTrue, reason: '阅读器 WebView 应建好');
        await _pumpFor(tester, const Duration(seconds: 12));
        await captureReaderWebView('hoshi-07-reader');
        final ReaderPositionRow afterOpen = (await db.getReaderPosition(
          readerUid!,
        ))!;
        debugPrint(
          '[hoshi-e2e] reader "$readerKey" imported section=$readerSection; '
          'after open section=${afterOpen.sectionIndex} '
          'norm=${afterOpen.normCharOffset} charOffset=${afterOpen.charOffset}',
        );
        // 恢复落空（回到第 0 章）时阅读器会把位置回写成开头：章节必须仍是导入的那章。
        expect(afterOpen.sectionIndex, readerSection);
      } finally {
        ExternalReaderImportPage.debugPickBackupPath = null;
      }
    },
    timeout: const Timeout(Duration(minutes: 40)),
  );
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const Duration step = Duration(milliseconds: 250);
  for (Duration d = Duration.zero; d < total; d += step) {
    await tester.pump(step);
  }
}

Future<bool> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  // 集成测试 binding 下 pump(时长) 是真实等待，导入的 isolate / IO 在其间推进
  // （与 readyAppModel 等 initialise 同一写法）。
  const Duration step = Duration(milliseconds: 500);
  for (Duration d = Duration.zero; d < timeout; d += step) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// 焦点驱动按下按钮：Tab 遍历到文案为 [label] 的按钮，再 Enter。
Future<void> _activateButton(
  WidgetTester tester,
  FocusDriver driver,
  String label,
) async {
  final Finder button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
  );
  expect(button, findsOneWidget, reason: '按钮「$label」应在树上');
  expect(
    await driver.focusWidget(button.first),
    isTrue,
    reason: '按钮「$label」应可经 Tab 聚焦',
  );
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump(const Duration(milliseconds: 300));
}

List<String> _visibleTexts(WidgetTester tester) => <String>[
  for (final Element e in find.byType(Text).evaluate())
    if ((e.widget as Text).data case final String data
        when data.trim().isNotEmpty)
      data,
];
