// 长步进 / 短步进控制条真界面验证（Windows 桌面真 app，M3E 外壳）：
//
//   ① 出厂布局：短步进（±seekSeconds）与长步进（±longSeekSeconds）都收在右下「⋯」，
//      菜单项文案带的是设置里的秒数（默认 3 / 30），不再是写死的 10 秒。
//   ② 把四颗步进键拖上底栏中簇后：按钮标注是「−3s / −30s / +3s / +30s」。
//
// 「⋯」的打开与控制条唤起用真实鼠标 TestGesture（同 video_bar_overflow_shortcuts_itest：
// 被测的就是鼠标点「⋯」）。截图落 observe-*.png，菜单 / 按钮文案打到日志里可 diff。
//
// 运行：fushi/ 下
//   .\tool\run_windows_itest.ps1 integration_test/video_long_seek_controls_itest.dart
// Mac（Apple 外壳）：fushi/ 下
//   flutter test integration_test/video_long_seek_controls_itest.dart -d macos
//     --dart-define=FUSHI_TEST_ROOT=<隔离根>
//     --dart-define=FUSHI_ITEST_VIDEO_FILE=<本机 mp4> [--dart-define=FUSHI_ITEST_KEEP_LAYOUT=true]
// KEEP_LAYOUT=true 时跑完不还原控制条布局（隔离根里留着四颗步进在栏上，之后用同一根
// 起 release 包可以直接看）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_control_bar.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kVideoFixtureOverride = String.fromEnvironment(
  'FUSHI_ITEST_VIDEO_FILE',
);
const String _kVideoFixture = _kVideoFixtureOverride == ''
    ? r'D:\hibiki_video_test\sample.mp4'
    : _kVideoFixtureOverride;
const bool _kKeepLayout = bool.fromEnvironment('FUSHI_ITEST_KEEP_LAYOUT');
const String _kVideoBookUid = 'video/long-seek-itest-sample';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video short / long seek: overflow menu and bar labels follow '
      'the configured seconds', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
    final AppModel appModel = container.read(appProvider);
    final VideoControlLayout originalLayout = appModel.videoControlLayout;
    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    expect(File(_kVideoFixture).existsSync(), isTrue);
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: const Value(_kVideoBookUid),
        title: const Value('long seek itest'),
        videoPath: Value(File(_kVideoFixture).absolute.path),
      ),
    );

    Future<void> pumpFor(Duration total) async {
      final int steps = total.inMilliseconds ~/ 100;
      for (int i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    VideoFushiTestHooks hooks() =>
        tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
            as VideoFushiTestHooks;

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(() => mouse.removePointer());

    Future<void> openPage() async {
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage(bookUid: _kVideoBookUid, repo: repo),
          ),
        ),
      );
      bool ready = false;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byType(VideoFushiPage).evaluate().isNotEmpty &&
            hooks().debugPositionMs != null) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: 'video controller should load');
      // 暂停在 10 秒处：截图时控制条不因播放而自动淡出，片尾也留得出 +30 秒的余量。
      await hooks().debugPause();
      await hooks().debugSeekMs(10000);
      await pumpFor(const Duration(milliseconds: 800));
    }

    Future<void> wake() async {
      final RenderBox videoBox = tester.renderObject<RenderBox>(
        find.byType(Video),
      );
      final Offset center = videoBox.localToGlobal(
        videoBox.size.center(Offset.zero),
      );
      for (int i = 0; i < 12; i++) {
        await mouse.moveTo(center + Offset(i.toDouble(), -40));
        await tester.pump(const Duration(milliseconds: 100));
        if (hooks().debugControlsVisible) break;
      }
      expect(hooks().debugControlsVisible, isTrue, reason: 'hover 应唤起控制条');
      await pumpFor(const Duration(milliseconds: 400));
    }

    // M3E 只有一条 fill 底栏；Apple 外壳是几段胶囊（fill: false），一律看全部控制条。
    List<Element> bars() => find.byType(VideoControlBar).evaluate().toList();

    List<String> barTexts(Element bar) => <String>[
      for (final Element e
          in find
              .descendant(
                of: find.byElementPredicate((Element x) => x == bar),
                matching: find.byType(Text),
              )
              .evaluate())
        (e.widget as Text).data ?? '',
    ];

    List<String> folded(Element bar) => <String>[
      for (final VideoBarEntry e in (bar.widget as VideoControlBar).entries)
        if (e.folded && e.menuAction != null) e.menuAction!.label,
    ];

    List<String> barTooltips(Element bar) => <String>[
      for (final Element e
          in find
              .descendant(
                of: find.byElementPredicate((Element x) => x == bar),
                matching: find.byType(FushiTooltip),
              )
              .hitTestable()
              .evaluate())
        (e.widget as FushiTooltip).message ?? '',
    ];

    final String back3 = t.video_control_seek_backward_seconds(seconds: 3);
    final String fwd3 = t.video_control_seek_forward_seconds(seconds: 3);
    final String back30 = t.video_control_seek_backward_seconds(seconds: 30);
    final String fwd30 = t.video_control_seek_forward_seconds(seconds: 30);

    try {
      // ── ① 出厂布局：四颗步进都在右下「⋯」───────────────────────────────
      await appModel.setVideoControlLayout(VideoControlLayout.currentChrome);
      await openPage();
      await wake();
      final List<String> foldedLabels = <String>[
        for (final Element bar in bars()) ...folded(bar),
      ];
      debugPrint('[long-seek] ⋯ labels=$foldedLabels');
      expect(foldedLabels, containsAll(<String>[back3, fwd3, back30, fwd30]));
      final Element menuBar = bars().firstWhere(
        (Element bar) => folded(bar).contains(back30),
      );

      final String moreTooltip = MaterialLocalizations.of(
        tester.element(find.byType(VideoFushiPage)),
      ).showMenuTooltip;
      final Finder more = find
          .descendant(
            of: find.byElementPredicate((Element x) => x == menuBar),
            matching: find.byWidgetPredicate(
              (Widget w) => w is FushiTooltip && w.message == moreTooltip,
            ),
          )
          .hitTestable();
      expect(more, findsWidgets, reason: '收着步进键的那条控制条应有「⋯」');
      final Offset moreAt = tester.getCenter(more.first);
      await mouse.moveTo(moreAt);
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.down(moreAt);
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.up();
      await pumpFor(const Duration(milliseconds: 700));
      final List<String> menuTexts = <String>[
        for (final Element e
            in find
                .descendant(
                  of: find.byType(PopupMenuItem<VideoBarMenuAction>),
                  matching: find.byType(Text),
                )
                .evaluate())
          (e.widget as Text).data ?? '',
      ];
      debugPrint('[long-seek] menu texts=$menuTexts');
      expect(menuTexts, containsAll(<String>[back3, fwd3, back30, fwd30]));
      final ObserveShot menuShot = await captureFlutterFrame(
        tester,
        '01-default-overflow-menu',
      );
      expect(menuShot.saved, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFor(const Duration(milliseconds: 500));
      navigator.pop();
      await pumpFor(const Duration(seconds: 2));

      // ── ② 四颗步进拖上底栏中簇：标注带秒数 ───────────────────────────
      VideoControlLayout placed = VideoControlLayout.currentChrome;
      for (final VideoControlItem item in <VideoControlItem>[
        VideoControlItem.longSeekBackward,
        VideoControlItem.seekBackward,
        VideoControlItem.seekForward,
        VideoControlItem.longSeekForward,
      ]) {
        placed = placed.moveItem(item, VideoControlSlot.bottomCenter);
      }
      await appModel.setVideoControlLayout(placed);
      await openPage();
      await wake();
      final List<String> tips = <String>[
        for (final Element bar in bars()) ...barTooltips(bar),
      ];
      final List<String> labels = <String>[
        for (final Element bar in bars()) ...barTexts(bar),
      ];
      debugPrint('[long-seek] bar tooltips=$tips');
      debugPrint('[long-seek] bar labels=$labels');
      expect(tips, containsAll(<String>[back3, fwd3, back30, fwd30]));
      // M3E 按钮下有「−3s」这类可见文字；Apple 外壳把秒数画进图标
      // （VideoAppleSeekGlyph），没有 Text，只认 tooltip。
      if (!Platform.isMacOS) {
        expect(
          labels,
          containsAll(<String>[
            t.video_bottom_seek_back_seconds_label(seconds: 3),
            t.video_bottom_seek_forward_seconds_label(seconds: 3),
            t.video_bottom_seek_back_seconds_label(seconds: 30),
            t.video_bottom_seek_forward_seconds_label(seconds: 30),
          ]),
        );
      }
      final ObserveShot barShot = await captureFlutterFrame(
        tester,
        '02-bar-with-short-and-long-seek',
      );
      expect(barShot.saved, isTrue);

      // 点一下 +30s：位置真的前进约 30 秒（主机按 longSeekSeconds 执行）。
      final int before = hooks().debugPositionMs ?? 0;
      final Finder plus30 = find
          .byWidgetPredicate(
            (Widget w) => w is FushiTooltip && w.message == fwd30,
          )
          .hitTestable();
      final Offset at = tester.getCenter(plus30.first);
      await mouse.moveTo(at);
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.down(at);
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.up();
      await pumpFor(const Duration(milliseconds: 1500));
      final int after = hooks().debugPositionMs ?? 0;
      debugPrint('[long-seek] +30s: $before -> $after');
      expect(after - before, greaterThanOrEqualTo(25000));
      navigator.pop();
      await pumpFor(const Duration(seconds: 1));
    } finally {
      if (!_kKeepLayout) {
        await appModel.setVideoControlLayout(originalLayout);
      }
    }
  });
}
