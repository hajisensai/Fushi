import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/video_banner_sources.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_work_detail_page.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_image_user_store.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 视频作品「横幅…」面板真像素：真 app、真库。造一部散装电影（附加图组里有两张
/// 横版标题卡当「片中」候选），按用户身份写一张横幅（与面板「文件」路同一个
/// apply），打开面板（当前横幅 + 锁角标 + 片中候选），再进作品详情页看横幅落在
/// hero 上。控件经回调 / 导航器驱动，不做坐标点击。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('视频横幅面板与作品详情页横幅（真像素）', (WidgetTester tester) async {
    UpdateChecker.disableAutoCheckForTesting = true;
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    final FushiDatabase db = appModel.database;
    final Directory work = Directory(
      p.join(appModel.thumbnailsDirectory.path, 'itest_video_banner'),
    )..createSync(recursive: true);

    Future<void> pumpFor(int quarterSeconds) async {
      for (int i = 0; i < quarterSeconds; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    String gradient(String name, int r, int g, int b) {
      final img.Image canvas = img.Image(width: 1280, height: 720);
      for (int y = 0; y < canvas.height; y++) {
        for (int x = 0; x < canvas.width; x++) {
          canvas.setPixelRgb(
            x,
            y,
            (r + x * 120 ~/ canvas.width).clamp(0, 255),
            (g + y * 100 ~/ canvas.height).clamp(0, 255),
            b,
          );
        }
      }
      final File file = File(p.join(work.path, name))
        ..writeAsBytesSync(img.encodePng(canvas));
      return file.path;
    }

    const String uid = 'itest-banner-movie';
    final File video = File(p.join(work.path, 'Banner Movie (2024).mkv'))
      ..writeAsBytesSync(const <int>[0]);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>(uid),
        title: const Value<String>('Banner Movie'),
        videoPath: Value<String>(video.path),
      ),
    );
    await db.replaceMediaImagesForBook(uid, <MediaImagesCompanion>[
      for (final (int i, String path) in <(int, String)>[
        (0, gradient('card0.png', 30, 90, 160)),
        (1, gradient('card1.png', 150, 60, 40)),
      ])
        MediaImagesCompanion.insert(
          bookUid: const Value<String?>(uid),
          kind: MediaImageKind.titleCard.dbValue,
          position: Value<int>(i),
          path: path,
        ),
    ]);

    const MediaImageOwner owner = MediaImageOwner.book(uid);
    Future<BannerPickerTarget> target() =>
        loadVideoBannerPickerTarget(db: db, owner: owner, onlineEnabled: false);
    await (await target()).apply(
      File(gradient('itest_banner_source.png', 40, 60, 150)),
    );
    final MediaImageRow picked = (await db.getMediaImagesForBook(uid))
        .firstWhere(
          (MediaImageRow r) => r.kind == MediaImageKind.backdrop.dbValue,
        );
    expect(picked.userChosen, isTrue);

    unawaited(
      showBannerPickerSheet(
        context: appModel.navigatorKey.currentContext!,
        target: await target(),
      ),
    );
    await pumpFor(24); // 片中候选在后台 isolate 扫描
    expect(find.byType(BannerPickerSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('banner-picker-current-locked')),
      findsOneWidget,
    );
    final ObserveShot sheetShot = await captureFlutterFrame(
      tester,
      '01-video-banner-sheet',
    );
    expect(sheetShot.saved, isTrue);
    debugPrint(
      '[video-banner-itest] candidates=${find.byWidgetPredicate((Widget w) {
        final Key? k = w.key;
        return k is ValueKey<String> && k.value.startsWith('banner-candidate-');
      }).evaluate().length}',
    );

    appModel.navigatorKey.currentState!.pop();
    await pumpFor(4);

    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => VideoWorkDetailPage(
            database: db,
            repository: VideoBookRepository(db),
            workRef: const VideoWorkRef.book(uid),
            onChanged: () {},
            onPickBanner: (MediaImageOwner _) async => false,
          ),
        ),
      ),
    );
    await pumpFor(16);
    expect(
      find.byKey(const ValueKey<String>('video-work-banner')),
      findsOneWidget,
    );
    final ObserveShot detailShot = await captureFlutterFrame(
      tester,
      '02-video-detail-with-banner',
    );
    expect(detailShot.saved, isTrue);
  });
}
