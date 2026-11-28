import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/item_scrape_detail.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/media/video/video_specs_providers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/book_detail_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show filteredVideoBookUidsProvider;
import 'package:fushi/src/pages/implementations/video_work_detail_page.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_image.dart';
import 'helpers/h264_test_clip.dart';
import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 横屏手机「有内容」巡检：书架 / 视频库填上内容，再逐个截书详情、视频作品详情、
/// 阅读器三种 view mode（含底栏与快速设置）、视频播放器。
///
/// 阅读器正文是 WebView、视频画面是平台纹理，Flutter 图层截图抓不到，所以这里不在
/// 进程内截图：每到一帧打一行 `[lp-content] SHOT <名字>` 再静置 [_kHold]，由宿主
/// 侧盯 logcat 的脚本用 `adb exec-out screencap -p` 抓真屏。
///
/// 跑法（Android 模拟器）：
///   adb shell settings put system accelerometer_rotation 0
///   adb shell settings put system user_rotation 1
///   adb shell settings put secure immersive_mode_confirmations confirmed
///   flutter drive --driver=test_driver/integration_test.dart
///     --target=integration_test/landscape_phone_content_sweep_itest.dart
/// 同时在宿主上盯 logcat 抓图（bash）：
///   adb logcat -v raw -s flutter:I | while read -r l; do case "$l" in
///     *"SHOT "*) n="${l##*SHOT }"; n="${n%$'\r'}"
///       case "$n" in *-video-player) adb shell input tap 1700 300; sleep .5;; esac
///       adb exec-out screencap -p > "$n.png";;
///     *"[lp-content] DONE"*) break;; esac; done
/// 播放器那一帧先点一下屏幕：手机上控制条只认触摸唤出。跑完把两项旋转设置还原。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 播放器控制条在手机上只认触摸唤出：让宿主脚本的 `adb input tap` 真正落到
  // app 上（默认测试绑定吞掉设备指针事件）。测试本身照旧焦点驱动。
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('landscape phone content sweep', (WidgetTester tester) async {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
    ]);
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);
    await _settle(tester, 2);

    final String bookKey = await seedReaderBook(tester);
    for (final String title in <String>[
      '吾輩は猫である',
      '坊っちゃん',
      'こころ',
      '銀河鉄道の夜',
      '羅生門',
    ]) {
      final Uint8List bytes = await buildAudiobookEpubBytes(
        title: title,
        cues: buildSampleCues(bookKey: 'pending'),
      );
      await EpubImporter.import(
        db: appModel.database,
        bytes: bytes,
        fileName: '$title.epub',
      );
    }
    final List<String> videoUids = await _seedVideos(tester, appModel);

    // 阅读器读的是进程里那一份活设置（不是新 new 的 DB 实例）。
    final ReaderSettings readerSettings =
        ReaderFushiSource.resolveEffectiveReaderSettings(appModel)!;
    final _DetailArt art = await _writeDetailArt();
    final String viewModeBefore = readerSettings.viewMode;
    final String designBefore = appModel.themeNotifier.designSystem;
    final FocusDriver driver = FocusDriver(tester);
    try {
      for (final String design in <String>['material', 'glass']) {
        await appModel.themeNotifier.setDesignSystem(design);
        await _settle(tester, 2);

        HomePage.debugSelectTab?.call(HomeTab.books);
        await _settle(tester, 3);
        await _shot(tester, '$design-books');

        HomePage.debugSelectTab?.call(HomeTab.video);
        HomeVideoPage.debugRefreshVideos?.call();
        await _settle(tester, 3);
        await _shot(tester, '$design-videos');

        final NavigatorState navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );

        for (final bool withArt in <bool>[false, true]) {
          unawaited(
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => BookDetailPage(
                  snapshot: () => BookDetailSnapshot(
                    title: '吾輩は猫である',
                    author: '夏目漱石',
                    progress: 0.35,
                    cover: withArt ? FileImage(art.cover) : null,
                  ),
                  loadDetail: () async => withArt
                      ? ItemScrapeDetail(backdropPath: art.backdrop.path)
                      : ItemScrapeDetail.empty,
                  onOpen: () async {},
                ),
              ),
            ),
          );
          await _settle(tester, 3);
          await _shot(tester, '$design-book-detail${withArt ? '-art' : ''}');
          navigator.pop();
          await _settle(tester, 1);
        }

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => VideoWorkDetailPage(
                database: appModel.database,
                videoSpecs: container.read(videoSpecsProvider),
                repository: VideoBookRepository(appModel.database),
                workRef: VideoWorkRef.book(videoUids.first),
                onChanged: () {},
              ),
            ),
          ),
        );
        await _settle(tester, 2);
        await _shot(tester, '$design-video-detail');
        final Finder play = find.byKey(
          const ValueKey<String>('video-work-play'),
        );
        // 主按钮直接拿焦点 + Enter（Tab 遍历从页头起走，详情页按钮多、步数不稳）。
        final Finder playFocus = find.descendant(
          of: play,
          matching: find.byType(Focus),
        );
        // Focus 不一定带显式 focusNode（节点在它自己的 State 里）：从它的子元素
        // 往上取最近的节点即这个 Focus 的节点；外层包装的不可取焦节点跳过。
        final FocusNode? playNode = playFocus
            .evaluate()
            .map((Element e) {
              FocusNode? node = (e.widget as Focus).focusNode;
              if (node == null) {
                e.visitChildElements((Element child) {
                  node ??= Focus.maybeOf(child);
                });
              }
              return node;
            })
            .whereType<FocusNode>()
            .where((FocusNode n) => n.canRequestFocus && !n.skipTraversal)
            .firstOrNull;
        debugPrint('[lp-content] play node ($design): $playNode');
        if (playNode != null) {
          playNode.requestFocus();
          await tester.pump();
          await driver.activate();
          await _settle(tester, 5);
          await _shot(tester, '$design-video-player');
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await _settle(tester, 1);
          await _shot(tester, '$design-video-player-paused');
        } else {
          debugPrint('[lp-content] play button not focusable ($design)');
        }
        await _leaveRoute(tester);

        for (final String mode in <String>['paginated', 'continuous', 'vn']) {
          await readerSettings.setViewMode(mode);
          await openBookViaProductionPath(tester, bookKey);
          for (int i = 0; i < 40; i++) {
            if (ReaderFushiPage.debugCaptureWebView != null) break;
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _settle(tester, 4);
          await _shot(tester, '$design-reader-$mode');
          await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
          await _settle(tester, 2);
          await _shot(tester, '$design-reader-$mode-chrome');
          if (mode == 'paginated') {
            await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
            await _settle(tester, 1);
            await ReaderFushiPage.debugOpenQuickSettings?.call();
            await _settle(tester, 2);
            await _shot(tester, '$design-reader-quick-settings');
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await _settle(tester, 1);
          }
          await _leaveRoute(tester);
        }
      }
    } finally {
      await readerSettings.setViewMode(viewModeBefore);
      await appModel.themeNotifier.setDesignSystem(designBefore);
    }
    debugPrint('[lp-content] DONE');
  });
}

/// 宿主截图脚本每帧要 1～2 秒（screencap + 拉回），静置要比这长。
const Duration _kHold = Duration(seconds: 4);

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump();
  debugPrint('[lp-content] SHOT $name');
  final DateTime until = DateTime.now().add(_kHold);
  while (DateTime.now().isBefore(until)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _settle(WidgetTester tester, int seconds) async {
  for (int i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// 退出当前全屏路由（阅读器 / 播放器）：先走 Esc（globalBack 逐级退），退不掉再
/// maybePop 兜底，直到回到主页。
Future<void> _leaveRoute(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    final NavigatorState nav = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    if (!nav.canPop()) return;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester, 1);
    if (i >= 3) {
      await nav.maybePop();
      await _settle(tester, 1);
    }
  }
}

/// 三段内嵌 H.264 小片（五端 libmpv 都能解；不依赖设备上的 ffmpeg）。
Future<List<String>> _seedVideos(WidgetTester tester, AppModel appModel) async {
  final Directory docs = await getApplicationDocumentsDirectory();
  final Directory dir = Directory('${docs.path}/lp_content_fixtures');
  await dir.create(recursive: true);
  final VideoBookRepository repo = VideoBookRepository(appModel.database);
  final List<String> uids = <String>[];
  for (final String title in <String>['テスト動画 第1話', 'テスト動画 第2話', '映画テスト']) {
    final File file = File('${dir.path}/$title.mp4');
    await file.writeAsBytes(h264TestClipBytes(), flush: true);
    final String uid = singleVideoBookUid(file.path);
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value(file.absolute.path),
      ),
    );
    uids.add(uid);
  }
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  container.invalidate(filteredVideoBookUidsProvider);
  HomeVideoPage.debugRefreshVideos?.call();
  await tester.pump();
  return uids;
}

class _DetailArt {
  const _DetailArt(this.cover, this.backdrop);
  final File cover;
  final File backdrop;
}

/// 详情页「有图」那一帧：竖版封面 + 16:9 横版背景（刮削后的常见形态）。
Future<_DetailArt> _writeDetailArt() async {
  final Directory docs = await getApplicationDocumentsDirectory();
  final Directory dir = Directory('${docs.path}/lp_content_fixtures');
  await dir.create(recursive: true);
  const TestImageGenerator gen = TestImageGenerator();
  final File cover = File('${dir.path}/cover.png');
  await cover.writeAsBytes(gen.pngBytes(width: 400, height: 600, seed: 3));
  final File backdrop = File('${dir.path}/backdrop.png');
  await backdrop.writeAsBytes(gen.pngBytes(width: 1280, height: 720, seed: 7));
  return _DetailArt(cover, backdrop);
}
