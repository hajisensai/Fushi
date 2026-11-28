import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/book_banner_sources.dart';
import 'package:fushi/src/media/detail/item_scrape_detail.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/book_detail_page.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 「横幅…」面板真像素：真 app、真库、真 EPUB（带真图）。先按用户身份写一张横幅
/// （与面板「文件」路同一个 apply），再打开面板（当前横幅 + 锁角标 + 书中候选），
/// 最后进书详情页看横幅落在海报 hero 上。控件经回调 / 导航器驱动，不做坐标点击。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('横幅面板与书详情页横幅（真像素）', (WidgetTester tester) async {
    UpdateChecker.disableAutoCheckForTesting = true;
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    final String bookKey = await seedReaderBook(tester, withRealImages: true);
    final EpubBookRow row = (await appModel.database.getEpubBook(bookKey))!;
    final ItemScrapeKey key = ItemScrapeKey(MediaKind.epub, row.uid);

    Future<void> pumpFor(int quarterSeconds) async {
      for (int i = 0; i < quarterSeconds; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    // 一张 1920x1080 的渐变横幅，按用户身份写入（上锁）。
    final File source = File(
      p.join(appModel.thumbnailsDirectory.path, 'itest_banner_source.png'),
    );
    final img.Image canvas = img.Image(width: 1920, height: 1080);
    for (int y = 0; y < canvas.height; y++) {
      for (int x = 0; x < canvas.width; x++) {
        canvas.setPixelRgb(
          x,
          y,
          40 + (x * 160 ~/ canvas.width),
          60 + (y * 120 ~/ canvas.height),
          150,
        );
      }
    }
    await source.writeAsBytes(img.encodePng(canvas));

    Future<BannerPickerTarget> target() => loadBookBannerPickerTarget(
      db: appModel.database,
      key: key,
      title: row.title,
      onlineEnabled: false,
      thumbnailsDirectory: appModel.thumbnailsDirectory,
    );
    await (await target()).apply(source);
    expect(
      await ItemScrapeStore(
        appModel.database,
      ).isUserChosen(key, MediaImageKind.backdrop),
      isTrue,
    );

    final BannerPickerTarget sheetTarget = await target();
    unawaited(
      showBannerPickerSheet(
        context: appModel.navigatorKey.currentContext!,
        target: sheetTarget,
      ),
    );
    await pumpFor(24); // 书中候选在后台 isolate 扫描
    expect(find.byType(BannerPickerSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('banner-picker-current-locked')),
      findsOneWidget,
    );
    final ObserveShot sheetShot = await captureFlutterFrame(
      tester,
      '01-banner-sheet',
    );
    expect(sheetShot.saved, isTrue);
    debugPrint(
      '[banner-itest] candidates=${find.byWidgetPredicate((Widget w) {
        final Key? k = w.key;
        return k is ValueKey<String> && k.value.startsWith('banner-candidate-');
      }).evaluate().length}',
    );

    appModel.navigatorKey.currentState!.pop();
    await pumpFor(4);

    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => BookDetailPage(
            snapshot: () => BookDetailSnapshot(title: row.title),
            loadDetail: () => ItemScrapeDetail.load(appModel.database, key),
            onOpen: () async {},
            onBanner: () async {},
          ),
        ),
      ),
    );
    await pumpFor(12);
    final ObserveShot detailShot = await captureFlutterFrame(
      tester,
      '02-book-detail-with-banner',
    );
    expect(detailShot.saved, isTrue);
  });
}
