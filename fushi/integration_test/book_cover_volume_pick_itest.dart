import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-5379 真 app 复测：「在线匹配封面」→ MangaBaka（真网络）→ 系列卷封面网格 →
/// 选一卷，弹窗必须关闭并返回 (封面文件, 候选)。修复前弹窗卡在转圈、Navigator.pop
/// 抛类型错误。控件经其回调驱动（不做坐标点击）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BUG-5379 MangaBaka 选卷封面后弹窗关闭并返回封面', (WidgetTester tester) async {
    UpdateChecker.disableAutoCheckForTesting = true;
    final List<String> errors = <String>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails d) {
      errors.add(d.exceptionAsString());
      debugPrint('[bug5371] FlutterError: ${d.exceptionAsString()}');
    };
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      final AppModel appModel = await readyAppModel(tester);

      BookCoverScrapeSelection? result;
      bool closed = false;
      Object? popError;
      showBookCoverScrapeDialog(
            context: appModel.navigatorKey.currentContext!,
            initialQuery: 'Horimiya',
            volume: 1,
          )
          .then((BookCoverScrapeSelection? r) {
            result = r;
            closed = true;
          })
          .catchError((Object e) {
            popError = e;
          });

      Future<bool> pumpUntil(bool Function() done, int seconds) async {
        for (int i = 0; i < seconds * 4; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (done()) return true;
        }
        return false;
      }

      expect(
        await pumpUntil(
          () => find.byType(BookCoverScrapeDialog).evaluate().isNotEmpty,
          10,
        ),
        isTrue,
      );

      // 首帧自动搜（Bangumi）进行中下拉是禁用的：等它可用再切源，与用户一致。
      FushiDropdown<BookScrapeSource> picker() =>
          tester.widget<FushiDropdown<BookScrapeSource>>(
            find.byKey(const ValueKey<String>('book_scrape_source_picker')),
          );
      expect(await pumpUntil(() => picker().enabled, 30), isTrue);
      // 源切到 MangaBaka（下拉的回调，与用户选菜单项同一条路径）。
      picker().onChanged(BookScrapeSource.mangabaka);
      expect(
        await pumpUntil(
          () => find
              .byKey(
                const ValueKey<String>('book_scrape_mangabaka_attribution'),
              )
              .evaluate()
              .isNotEmpty,
          5,
        ),
        isTrue,
        reason: '源应已切到 MangaBaka',
      );
      final Finder useButtons = find.ancestor(
        of: find.text(t.book_scrape_use),
        matching: find.byType(FushiFilledButton),
      );
      expect(
        await pumpUntil(() => useButtons.evaluate().isNotEmpty, 30),
        isTrue,
        reason: 'MangaBaka 搜索应出候选',
      );
      await captureFlutterFrame(tester, '01-mangabaka-results');
      tester.widget<FushiFilledButton>(useButtons.first).onPressed!();

      final Finder vol1 = find.byKey(
        const ValueKey<String>('book_scrape_volume_1'),
      );
      expect(
        await pumpUntil(() => vol1.evaluate().isNotEmpty, 30),
        isTrue,
        reason: '卷封面网格应出第 1 卷',
      );
      await pumpUntil(() => false, 4); // 让缩略图加载
      await captureFlutterFrame(tester, '02-volume-grid');

      final Stopwatch sw = Stopwatch()..start();
      tester.widget<InkWell>(vol1).onTap!();
      await tester.pump(const Duration(milliseconds: 300));
      await captureFlutterFrame(tester, '03-after-pick');
      final bool dialogGone = await pumpUntil(
        () => find.byType(BookCoverScrapeDialog).evaluate().isEmpty,
        30,
      );
      debugPrint(
        '[bug5371] dialogGone=$dialogGone closed=$closed '
        'elapsedMs=${sw.elapsedMilliseconds} popError=$popError '
        'errors=${errors.length}',
      );
      await captureFlutterFrame(tester, '04-after-close');

      expect(errors, isEmpty, reason: '不应有 FlutterError（修复前是 pop 类型错误）');
      expect(dialogGone, isTrue, reason: '选中一卷后弹窗应关闭');
      expect(closed, isTrue);
      final BookCoverScrapeSelection selection = result!;
      final int bytes = selection.cover.lengthSync();
      debugPrint(
        '[bug5371] cover=${selection.cover.path} bytes=$bytes '
        'candidate.source=${selection.candidate.source.name} '
        'title=${selection.candidate.title} '
        'volume=${selection.candidate.volume} '
        'coverUrl=${selection.candidate.coverUrl}',
      );
      expect(bytes, greaterThan(10000));
      expect(selection.candidate.source, BookScrapeSource.mangabaka);
      expect(selection.candidate.volume, '1');
      await File(selection.cover.path).delete();
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
