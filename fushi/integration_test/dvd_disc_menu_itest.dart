import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// DVD 原盘菜单的原路径（Windows，焦点驱动、只发按键，禁坐标点击）：
/// 库条目（`<盘根>/VIDEO_TS/TITLE_01.dvdtitle`）→「播放原盘」进 libdvdnav 菜单
/// （VMGM 标题菜单，`dvd-state` 快照）→ → 移到按钮 2 → Enter 进 title 1 第 2 章，
/// 按 title 号绑定库条目（同 BD 的 MPLS 绑定代际规则）→ 片尾 post 命令回到标题菜单。
///
/// 盘：`tool/dvd/make_test_dvd.py` 编的无加密测试盘（3 个按钮：title 1 / title 1
/// 第 2 章 / title 2）。运行：tool/run_windows_itest.ps1，
/// -DartDefine FUSHI_DVD_MENU_ROOT=<含 VIDEO_TS 的目录>。缺盘明确跳过，不计入验收。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const String root = String.fromEnvironment('FUSHI_DVD_MENU_ROOT');
  final String? skipReason = !Platform.isWindows
      ? 'Windows disc session path'
      : root.isEmpty
      ? 'Set FUSHI_DVD_MENU_ROOT to a tool/dvd/make_test_dvd.py disc'
      : !File(p.join(root, 'VIDEO_TS', 'VIDEO_TS.IFO')).existsSync()
      ? 'Disc fixture is not mounted: $root'
      : null;
  if (skipReason != null) debugPrint('[dvd-menu] SKIP: $skipReason');

  testWidgets(
    'dvd menu: library title -> disc menu -> title bound -> back to menu',
    (WidgetTester tester) async {
      final String titlePath = dvdTitlePath(root, 1);
      final FlutterExceptionHandler? errorHandler = FlutterError.onError;
      addTearDown(() => FlutterError.onError = errorHandler);
      expect(fushiTestRootPath(), isNotNull);
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
      FlutterError.onError = errorHandler;
      final AppModel appModel = await enableFocusNavigation(tester);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final String uid =
          'video/itest-dvd-menu-${DateTime.now().microsecondsSinceEpoch}';
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: const Value('DVD menu integration fixture'),
          videoPath: Value(titlePath),
        ),
      );

      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage.neutralized(
              bookUid: uid,
              repo: repo,
              openBlurayMenu: true,
            ),
          ),
        ),
      );
      VideoFushiTestHooks? hooks() {
        // The disc session's auto fullscreen pushes media_kit's fullscreen
        // route over the page, so the page is offstage while the menu runs.
        final Finder page = find.byType(VideoFushiPage, skipOffstage: false);
        if (page.evaluate().isEmpty) return null;
        return tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
      }

      void log(String what) {
        final VideoDiscNavigationState? s = hooks()?.debugDiscNavigationState;
        debugPrint(
          '[dvd-menu] $what: type=${s?.discType} domain=${s?.dvd?.domain} '
          'title=${s?.title} gen=${s?.generation} button=${s?.dvd?.button} '
          'ready=${hooks()?.debugDiscTitleReady} '
          'path=${hooks()?.debugDiscPlaylistPath} '
          'book=${hooks()?.debugActiveBookUid} '
          'error=${hooks()?.debugDiscMenuError}',
        );
      }

      // 1. The VMGM title menu with its first button focused.
      await _waitFor(
        tester,
        () {
          final VideoDiscNavigationState? s = hooks()?.debugDiscNavigationState;
          return s != null &&
              s.discType == VideoDiscType.dvd &&
              s.menuActive &&
              s.dvd?.domain == VideoDvdDomain.videoManagerMenu &&
              s.dvd?.button == 1;
        },
        'DVD title menu',
        hooks,
      );
      log('menu');
      final int menuGeneration = hooks()!.debugDiscNavigationState!.generation;
      expect(hooks()!.debugDiscLearningBlocked, isTrue);

      // Native menu keys reach the disc through the shared video FocusNode
      // (same precondition as the Blu-ray menu itest).
      await _waitFor(
        tester,
        () =>
            hooks()?.debugDiscNavigationState?.stable == true &&
            hooks()?.debugVideoFocusAttached == true &&
            hooks()?.debugVideoSurfaceHoldsFocus == true,
        'video surface focus',
        hooks,
      );

      // 2. Right arrow moves the highlight (disc key through the DVD table).
      await _sendKey(tester, LogicalKeyboardKey.arrowRight);
      await _waitFor(
        tester,
        () => hooks()?.debugDiscNavigationState?.dvd?.button == 2,
        'button 2 highlighted',
        hooks,
      );
      log('button 2');

      // 3. Enter: title 1 chapter 2 plays and binds the library row by title.
      await _sendKey(tester, LogicalKeyboardKey.enter);
      await _waitFor(
        tester,
        () =>
            hooks()?.debugDiscTitleReady == true &&
            hooks()?.debugDiscNavigationState?.dvdTitleNumber == 1,
        'title 1 bound',
        hooks,
      );
      log('title');
      final VideoDiscNavigationState onTitle =
          hooks()!.debugDiscNavigationState!;
      expect(onTitle.generation, greaterThan(menuGeneration));
      expect(onTitle.dvd!.domain, VideoDvdDomain.title);
      expect(
        p.normalize(hooks()!.debugDiscPlaylistPath!),
        p.normalize(titlePath),
      );
      expect(hooks()!.debugActiveBookUid, uid);
      expect(hooks()!.debugDiscLearningBlocked, isFalse);

      // 4. The title's post command returns to the title menu: identity is
      // released (new generation, nothing bound, learning blocked again).
      await _waitFor(
        tester,
        () {
          final VideoDiscNavigationState? s = hooks()?.debugDiscNavigationState;
          return s != null &&
              s.dvd?.domain == VideoDvdDomain.videoManagerMenu &&
              s.menuActive &&
              s.generation > onTitle.generation;
        },
        'back in the title menu',
        hooks,
      );
      log('menu again');
      expect(hooks()!.debugDiscTitleReady, isFalse);
      expect(hooks()!.debugDiscLearningBlocked, isTrue);
      expect(hooks()!.debugDiscMenuError, isNull);
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _sendKey(WidgetTester tester, LogicalKeyboardKey key) async {
  final FocusNode? focus = FocusManager.instance.primaryFocus;
  final bool handled = await tester.sendKeyEvent(key);
  debugPrint(
    '[dvd-menu] key ${key.debugName} handled=$handled '
    'focus=${focus?.debugLabel} widget=${focus?.context?.widget.runtimeType}',
  );
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done,
  String what,
  VideoFushiTestHooks? Function() hooks,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!done()) {
    final String? error = hooks()?.debugDiscMenuError;
    if (error != null) fail('disc menu error while waiting for $what: $error');
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'timed out waiting for $what '
        '(stage=${hooks()?.debugDiscLoadStage}, '
        'state=${hooks()?.debugDiscNavigationState?.dvd?.domain}, '
        'pages incl. offstage='
        '${find.byType(VideoFushiPage, skipOffstage: false).evaluate().length})',
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
