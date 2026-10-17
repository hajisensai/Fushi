// 设置 › 存储：「视频下载」类目逐集列出、按作品分组，单集删除真删文件 + 库行
// 并刷新界面（用户反馈：视频下载只有一个总分类、看不到具体内容也删不掉）。
//
// 真 app、真库、真文件；操作一律焦点驱动（Tab / Enter），不点坐标。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show AdaptiveSettingsRow;
import 'package:fushi/utils.dart' show t;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _work = 'Itest 作品';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int polls = 120,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (condition()) return;
  }
  fail(reason);
}

Finder _categoryRow(String title) => find.descendant(
  of: find.byType(AdaptiveSettingsRow),
  matching: find.text(title),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('存储页逐集列出下载视频并可单独删除（删文件 + 库行 + 刷新界面）', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await enableFocusNavigation(tester);
    final FushiDatabase db = appModel.database;

    // 播种：扩展源下载的落点 remote_videos/anime_sources，两集同属一部作品。
    final Directory dir = Directory(
      p.join((await AppPaths.remoteVideosDirectory()).path, 'anime_sources'),
    )..createSync(recursive: true);
    final File ep2 = File(p.join(dir.path, 'itest-ep2.mp4'))
      ..writeAsBytesSync(List<int>.filled(300 * 1024, 7));
    final File ep3 = File(p.join(dir.path, 'itest-ep3.mp4'))
      ..writeAsBytesSync(List<int>.filled(200 * 1024, 7));
    final VideoBookRepository repo = VideoBookRepository(db);
    for (final (String uid, String title, File f) in <(String, String, File)>[
      ('itest-ep2', 'Episode 2', ep2),
      ('itest-ep3', 'Episode 3', ep3),
    ]) {
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value(title),
          videoPath: Value(f.path),
        ),
      );
    }
    final int collectionId = await db.createMediaCollection(_work);
    await db.addToCollection(collectionId, MediaKind.video, 'itest-ep2');
    await db.addToCollection(collectionId, MediaKind.video, 'itest-ep3');

    final FocusDriver driver = FocusDriver(tester);
    HomePage.debugSelectTab!(HomeTab.settings);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      await driver.focusWidget(
        find.text(t.settings_destination_storage).first,
        maxSteps: 320,
      ),
      isTrue,
    );
    await driver.activate();
    await _pumpUntil(
      tester,
      () =>
          find
              .byWidgetPredicate(
                (Widget w) =>
                    w is SettingsDetailPage &&
                    w.destination?.id == SettingsDestinationId.storage,
              )
              .evaluate()
              .isNotEmpty ||
          find
              .byKey(
                const ValueKey<SettingsDestinationId>(
                  SettingsDestinationId.storage,
                ),
              )
              .evaluate()
              .isNotEmpty,
      reason: '存储页应打开',
    );
    await _pumpUntil(
      tester,
      () => find.byType(StorageUsageView).evaluate().isNotEmpty,
      reason: 'StorageUsageView 应渲染',
    );

    final Finder videoRow = _categoryRow(t.storage_category_video_downloads);
    await _pumpUntil(
      tester,
      () => videoRow.evaluate().isNotEmpty,
      reason: '视频下载类目行应出现',
    );
    // 等扫描出视频类目的数字（类目可展开 = 有明细）。
    await _pumpUntil(
      tester,
      () => !find.text('…').evaluate().isNotEmpty,
      reason: '扫描应结束',
    );
    expect(await driver.focusWidget(videoRow, maxSteps: 320), isTrue);
    await driver.activate();
    const ValueKey<String> groupKey = ValueKey<String>(
      'storage_entry_group:$_work',
    );
    await _pumpUntil(
      tester,
      () => find.byKey(groupKey).evaluate().isNotEmpty,
      reason: '展开后应出现作品组头',
    );
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.text('Episode 3'), findsOneWidget);
    await tester.ensureVisible(find.byKey(groupKey));
    await tester.pump(const Duration(milliseconds: 500));
    await captureFlutterFrame(tester, '01-video-entries-grouped');

    // 焦点移到 Episode 2 这一行的删除钮 → Enter → 确认框 Enter。
    final Finder deleteEp2 = find.descendant(
      of: find.byKey(const ValueKey<String>('storage_entry:itest-ep2')),
      matching: find.byTooltip(t.dialog_delete),
    );
    expect(deleteEp2, findsOneWidget);
    expect(await driver.focusWidget(deleteEp2, maxSteps: 320), isTrue);
    await driver.activate();
    await _pumpUntil(
      tester,
      () => find
          .text(t.storage_entry_delete_video_confirm_body)
          .evaluate()
          .isNotEmpty,
      reason: '应弹出删除确认框',
    );
    await captureFlutterFrame(tester, '02-confirm');
    final Finder confirm = find.widgetWithText(FilledButton, t.dialog_delete);
    expect(await driver.focusWidget(confirm, maxSteps: 20), isTrue);
    await driver.activate();

    await _pumpUntil(
      tester,
      () =>
          find.text('Episode 2').evaluate().isEmpty &&
          find.text('Episode 3').evaluate().isNotEmpty,
      reason: '删除后重扫：Episode 2 消失、Episode 3 仍在',
    );
    expect(ep2.existsSync(), isFalse, reason: '文件应真被删掉');
    expect(ep3.existsSync(), isTrue);
    expect(await repo.getByBookUid('itest-ep2'), isNull, reason: '库行应删掉');
    expect(await repo.getByBookUid('itest-ep3'), isNotNull);
    await tester.pump(const Duration(milliseconds: 500));
    await captureFlutterFrame(tester, '03-after-delete');
    debugPrint('[storage-video-itest] ep2 deleted, ep3 kept — OK');
  });
}
