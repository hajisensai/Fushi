import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/external_reader_import_page.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_stat_segments.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 「从 Hoshi Reader 导入」真 app 端到端：真库、真 EpubImporter、真页面。
///
/// 样本是按 Hoshi Reader iOS / Android 源码落盘结构、用两本真实 EPUB 拼出的
/// `Books_*.hoshi`（生成脚本与期望值 `<样本>.summary.json` 由调用方提供，样本含
/// 版权书，不入库）：
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
      final Map<String, dynamic> expected =
          jsonDecode(File('$samplePath.summary.json').readAsStringSync())
              as Map<String, dynamic>;
      final Map<String, dynamic> ja = expected['ja'] as Map<String, dynamic>;
      final Map<String, dynamic> en = expected['en'] as Map<String, dynamic>;
      final Map<String, dynamic> deleted =
          expected['deleted'] as Map<String, dynamic>;
      final String jaKey = sanitizeTtuFilename(ja['title'] as String);
      final String enKey = sanitizeTtuFilename(en['title'] as String);
      final String deletedKey = sanitizeTtuFilename(deleted['title'] as String);

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

        await _activateButton(tester, driver, t.hoshi_import_run_start);
        expect(
          await _waitFor(
            tester,
            find.text(t.hoshi_import_result_done),
            timeout: const Duration(minutes: 5),
          ),
          isTrue,
          reason: '导入应在 5 分钟内完成',
        );
        debugPrint('[hoshi-e2e] report: ${_visibleTexts(tester).join(' | ')}');
        await captureFlutterFrame(tester, 'hoshi-03-report');

        // 书进库。
        expect(await db.getEpubBook(jaKey), isNotNull, reason: jaKey);
        expect(await db.getEpubBook(enKey), isNotNull, reason: enKey);
        expect(await db.getEpubBook(deletedKey), isNull);

        // 统计总量与 Hoshi 一致，全部是导入段。
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

        final (int jaChars, int jaMs) = await totals(jaKey);
        final (int enChars, int enMs) = await totals(enKey);
        final (int delChars, int delMs) = await totals(deletedKey);
        debugPrint(
          '[hoshi-e2e] totals ja=$jaChars/${jaMs ~/ 60000}min '
          'en=$enChars/${enMs ~/ 60000}min deleted=$delChars/${delMs ~/ 60000}min',
        );
        expect(jaChars, ja['sessions_chars']);
        expect(jaMs, ((ja['sessions_minutes'] as num) * 60000).round());
        expect(enChars, en['days_chars']);
        expect(enMs, ((en['days_minutes'] as num) * 60000).round());
        expect(delChars, deleted['chars']);

        // 阅读位置：Hoshi 书签时刻、无精确锚。
        final Map<String, dynamic> jaBookmark =
            ja['bookmark'] as Map<String, dynamic>;
        final int bookmarkAt =
            (((jaBookmark['lastModified'] as num) + 978307200) * 1000).round();
        final String jaUid = (await db.resolveEpubBookUid(jaKey))!;
        final ReaderPositionRow jaPos = (await db.getReaderPosition(jaUid))!;
        debugPrint(
          '[hoshi-e2e] ja position section=${jaPos.sectionIndex} '
          'norm=${jaPos.normCharOffset} charOffset=${jaPos.charOffset} '
          'updatedAt=${jaPos.updatedAt} (hoshi chapterIndex='
          '${jaBookmark['chapterIndex']} href=${ja['href']})',
        );
        expect(jaPos.updatedAt, closeTo(bookmarkAt, 1));
        expect(jaPos.charOffset, -1);
        final EpubBookRow jaRow = (await db.getEpubBook(jaKey))!;
        final List<dynamic> chapters = jaRow.chaptersJson.isEmpty
            ? <dynamic>[]
            : jsonDecode(jaRow.chaptersJson) as List<dynamic>;
        final String mappedHref =
            (chapters[jaPos.sectionIndex] as Map<String, dynamic>)['href']
                as String;
        expect(
          mappedHref.endsWith(ja['href'] as String),
          isTrue,
          reason: '映射到的章节 $mappedHref 应是 Hoshi 书签所在的 ${ja['href']}',
        );

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
            timeout: const Duration(minutes: 3),
          ),
          isTrue,
        );
        debugPrint(
          '[hoshi-e2e] report#2: ${_visibleTexts(tester).join(' | ')}',
        );
        expect(
          find.textContaining(
            t.hoshi_import_result_books(imported: 0, matched: 2),
          ),
          findsOneWidget,
        );
        expect(await totals(jaKey), (jaChars, jaMs));
        expect(await totals(enKey), (enChars, enMs));
        expect((await db.getEpubBookMetas()).length, 2);
        await captureFlutterFrame(tester, 'hoshi-04-reimport');

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
            'hoshi-05-stats-reading',
          )).nonBlank,
          isTrue,
        );
        debugPrint(
          '[hoshi-e2e] stats: ${_visibleTexts(tester).take(60).join(' | ')}',
        );
        appModel.navigatorKey.currentState!.pop();
        await _pumpFor(tester, const Duration(seconds: 1));

        // ── 阅读器按导入的位置打开 ───────────────────────────────────
        await openBookViaProductionPath(tester, jaKey);
        for (int i = 0; i < 120 && !readerWebViewReady(); i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(readerWebViewReady(), isTrue, reason: '阅读器 WebView 应建好');
        await _pumpFor(tester, const Duration(seconds: 12));
        await captureReaderWebView('hoshi-06-reader');
        final ReaderPositionRow afterOpen = (await db.getReaderPosition(
          jaUid,
        ))!;
        debugPrint(
          '[hoshi-e2e] after open section=${afterOpen.sectionIndex} '
          'norm=${afterOpen.normCharOffset} charOffset=${afterOpen.charOffset}',
        );
        // 恢复落空（回到第 0 章）时阅读器会把位置回写成开头：章节必须仍是导入的那章。
        expect(afterOpen.sectionIndex, jaPos.sectionIndex);
      } finally {
        ExternalReaderImportPage.debugPickBackupPath = null;
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
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
