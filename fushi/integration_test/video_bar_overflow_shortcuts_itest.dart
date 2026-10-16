// 反馈 eeWvjG93_d / tMFIoEr0me 真机端到端（Windows 桌面真 app）：
//
//   ① 「⋯」里只剩一项时不再弹只有一行的菜单：那一项的按钮直接画在「⋯」的位置。
//   ② 点「⋯」打开溢出菜单时控制条不消失：菜单开着期间跨过两个自动隐藏时长
//      （2s）后控制条仍可见；菜单关掉后照常按时淡出（没有被永久钉住）。
//   ③ 播放器设置面板「控制按钮」分类里有「快捷键设置」入口，焦点驱动（Tab +
//      Enter）进入后快捷键页预选「视频」分域。
//
// 真相源：页面 test hook `debugControlsVisible`（fork 推来的真实 `visible`）+ media_kit
// 控制条自身那层 AnimatedOpacity（两者必须一致，见 video_keyboard_controls_keepalive_itest）。
// 「⋯」的点击与 hover 是被测输入本身（反馈说的就是鼠标点「⋯」），用真实鼠标
// TestGesture 注入；设置面板里的入口按规矩焦点驱动（Tab / Enter），不用 tester.tap。
//
// 运行：fushi/ 下
//   .\tool\run_windows_itest.ps1 integration_test/video_bar_overflow_shortcuts_itest.dart -Visible
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_control_bar.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kVideoFixture = r'D:\hibiki_video_test\sample.mp4';
const String _kVideoBookUid = 'video/bar-overflow-itest-sample';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'video bar: single overflow item is a direct button, menu keeps controls, '
    'shortcut settings entry',
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[bar-overflow] ${details.exceptionAsString()}');
      };

      Future<void> shot(String name) async {
        final RenderView view = tester.binding.renderViews.first;
        final OffsetLayer? layer = view.debugLayer as OffsetLayer?;
        if (layer == null) return;
        final ui.Image image = await layer.toImage(view.paintBounds);
        try {
          final ByteData? png = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (png == null) return;
          final File out = File(
            '${observeScreenshotDir().path}${Platform.pathSeparator}'
            'observe-$name.png',
          );
          await out.writeAsBytes(png.buffer.asUint8List());
          debugPrint('[bar-overflow] screenshot ${out.path}');
        } finally {
          image.dispose();
        }
      }

      Future<void> pumpFor(Duration total) async {
        final int steps = total.inMilliseconds ~/ 100;
        for (int i = 0; i < steps; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);
        expect(File(_kVideoFixture).existsSync(), isTrue);
        await repo.saveVideoBook(
          VideoBooksCompanion(
            bookUid: const Value(_kVideoBookUid),
            title: const Value('bar overflow itest'),
            videoPath: Value(File(_kVideoFixture).absolute.path),
          ),
        );

        final NavigatorState navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) =>
                  VideoFushiPage(bookUid: _kVideoBookUid, repo: repo),
            ),
          ),
        );

        VideoFushiTestHooks hooks() =>
            tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
                as VideoFushiTestHooks;

        double? controlsOpacity() {
          final Finder f = find.descendant(
            of: find.byType(Video),
            matching: find.byType(AnimatedOpacity),
          );
          if (f.evaluate().isEmpty) return null;
          return tester.widget<AnimatedOpacity>(f.first).opacity;
        }

        bool ready = false;
        for (int i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(VideoFushiPage).evaluate().isNotEmpty &&
              hooks().debugPositionMs != null) {
            ready = true;
            break;
          }
        }
        expect(ready, isTrue, reason: 'video controller should load');

        // 真实鼠标唤起控制条。
        final RenderBox videoBox = tester.renderObject<RenderBox>(
          find.byType(Video),
        );
        final Offset center = videoBox.localToGlobal(
          videoBox.size.center(Offset.zero),
        );
        final TestGesture mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: center - const Offset(0, 40));
        addTearDown(() => mouse.removePointer());
        Future<bool> wake() async {
          for (int i = 0; i < 12; i++) {
            await mouse.moveTo(center + Offset(i.toDouble(), 0));
            await tester.pump(const Duration(milliseconds: 100));
            if (hooks().debugControlsVisible) return true;
          }
          return false;
        }

        expect(await wake(), isTrue, reason: '真实 hover 应唤起控制条');
        await pumpFor(const Duration(milliseconds: 400));

        final String moreTooltip = MaterialLocalizations.of(
          tester.element(find.byType(VideoFushiPage)),
        ).showMenuTooltip;

        // 每条控制条上的按钮 tooltip（= 用户看到的按钮清单）。
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
        final List<Element> bars = find
            .byType(VideoControlBar)
            .evaluate()
            .toList();
        expect(bars, isNotEmpty);
        Element? bottomBar;
        for (final Element bar in bars) {
          final VideoControlBar w = bar.widget as VideoControlBar;
          final int folded = w.entries
              .where((VideoBarEntry e) => e.folded)
              .length;
          final List<String> tips = barTooltips(bar);
          debugPrint(
            '[bar-overflow] bar fill=${w.fill} entries=${w.entries.length} '
            'folded=$folded tooltips=$tips',
          );
          if (w.fill) bottomBar = bar;
        }
        await shot('01-controls-visible');

        // ── ① 只剩一项：不画「⋯」，直接画那一项 ───────────────────────────
        expect(bottomBar, isNotNull, reason: '底栏 VideoControlBar(fill: true)');
        final VideoControlBar bottom = bottomBar!.widget as VideoControlBar;
        final List<VideoBarEntry> bottomFolded = bottom.entries
            .where((VideoBarEntry e) => e.folded)
            .toList();
        debugPrint(
          '[bar-overflow] bottom folded labels='
          '${bottomFolded.map((VideoBarEntry e) => e.menuAction?.label).toList()}',
        );
        final List<String> bottomTips = barTooltips(bottomBar);
        if (bottomFolded.length == 1) {
          final String onlyLabel = bottomFolded.single.menuAction!.label;
          expect(
            bottomTips.contains(moreTooltip),
            isFalse,
            reason: '「⋯」只有一项（$onlyLabel）时不应再画「⋯」',
          );
          expect(
            bottomTips.contains(onlyLabel),
            isTrue,
            reason: '那一项（$onlyLabel）的按钮应直接出现在栏上',
          );
        } else {
          debugPrint(
            '[bar-overflow] WARN 默认布局底栏常驻菜单项 = ${bottomFolded.length}，'
            '①的「只剩一项」前置条件不成立',
          );
        }

        // ── ② 点「⋯」开菜单：控制条不消失 ─────────────────────────────────
        final Finder moreButtons = find
            .byWidgetPredicate(
              (Widget w) => w is FushiTooltip && w.message == moreTooltip,
            )
            .hitTestable();
        debugPrint(
          '[bar-overflow] hit-testable ⋯ buttons: '
          '${moreButtons.evaluate().length}',
        );
        expect(
          moreButtons,
          findsWidgets,
          reason: '需要至少一个仍有多项的「⋯」来验证菜单开着时控制条不消失',
        );
        final Offset moreAt = tester.getCenter(moreButtons.first);
        await mouse.moveTo(moreAt);
        await tester.pump(const Duration(milliseconds: 100));
        await mouse.down(moreAt);
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.up();
        await pumpFor(const Duration(milliseconds: 500));
        final int menuItems = find
            .byType(PopupMenuItem<VideoBarMenuAction>)
            .evaluate()
            .length;
        debugPrint('[bar-overflow] menu items after click: $menuItems');
        expect(menuItems, greaterThan(1), reason: '「⋯」菜单应弹出且多于一项');
        expect(
          hooks().debugControlsVisible,
          isTrue,
          reason: '菜单弹出的同一时刻控制条不得消失（反馈 eeWvjG93_d）',
        );
        await shot('02-menu-open');
        // 跨过两个自动隐藏时长（2s），菜单仍开着，控制条仍在。
        await pumpFor(const Duration(milliseconds: 4500));
        debugPrint(
          '[bar-overflow] menu open +4.5s: visible=${hooks().debugControlsVisible} '
          'opacity=${controlsOpacity()}',
        );
        expect(hooks().debugControlsVisible, isTrue);
        expect(controlsOpacity(), 1.0);
        await shot('03-menu-open-4500ms');

        // 关菜单（Esc）：控制条随即照常倒计时，不被永久钉住。
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pumpFor(const Duration(milliseconds: 500));
        expect(find.byType(PopupMenuItem<VideoBarMenuAction>), findsNothing);
        debugPrint(
          '[bar-overflow] menu closed: visible=${hooks().debugControlsVisible}',
        );
        bool hidAgain = false;
        for (int i = 0; i < 60 && !hidAgain; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          hidAgain = !hooks().debugControlsVisible;
        }
        expect(hidAgain, isTrue, reason: '菜单关掉后控制条应按时自动隐藏（hold 已放开）');

        // ── ③ 设置面板「控制按钮」→ 快捷键设置（视频分域）──────────────────
        hooks().debugOpenControlsSettings();
        await pumpFor(const Duration(milliseconds: 1500));
        final String entryTitle = t.shortcut_settings_title;
        expect(
          find.text(entryTitle),
          findsWidgets,
          reason: '控制按钮分类里应有「${t.shortcut_settings_title}」入口',
        );
        await shot('04-controls-settings');

        bool focusedOnEntry() {
          final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
          if (ctx == null) return false;
          return find
              .descendant(
                of: find.byElementPredicate((Element e) => identical(e, ctx)),
                matching: find.text(entryTitle),
              )
              .evaluate()
              .isNotEmpty;
        }

        int tabs = 0;
        for (; tabs < 80 && !focusedOnEntry(); tabs++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump(const Duration(milliseconds: 80));
        }
        debugPrint('[bar-overflow] Tab x$tabs -> focused=${focusedOnEntry()}');
        expect(focusedOnEntry(), isTrue, reason: 'Tab 应能把焦点走到快捷键入口');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        bool opened = false;
        for (int i = 0; i < 40 && !opened; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          opened = find.byType(ShortcutSettingsPage).evaluate().isNotEmpty;
        }
        expect(opened, isTrue, reason: 'Enter 应打开快捷键设置页');
        await pumpFor(const Duration(milliseconds: 1200));
        final ShortcutSettingsPage page = tester.widget<ShortcutSettingsPage>(
          find.byType(ShortcutSettingsPage),
        );
        expect(page.initialScope?.name, 'video');
        final Finder videoChip = find.byKey(
          const ValueKey<String>('shortcut-domain-video'),
        );
        final Finder videoNav = find.byKey(
          const ValueKey<String>('shortcut-nav-video'),
        );
        bool? chipSelected;
        if (videoChip.evaluate().isNotEmpty) {
          chipSelected = tester.widget<FushiChoiceChip>(videoChip).selected;
        }
        final bool allSelected =
            find
                .byKey(const ValueKey<String>('shortcut-domain-all'))
                .evaluate()
                .isNotEmpty &&
            tester
                .widget<FushiChoiceChip>(
                  find.byKey(const ValueKey<String>('shortcut-domain-all')),
                )
                .selected;
        debugPrint(
          '[bar-overflow] shortcut page: videoChip=${videoChip.evaluate().length} '
          'selected=$chipSelected allSelected=$allSelected '
          'videoNav=${videoNav.evaluate().length}',
        );
        if (videoChip.evaluate().isNotEmpty) {
          expect(chipSelected, isTrue, reason: '应预选「视频」分域');
          expect(allSelected, isFalse);
        }
        // 视频分域的行在列表里（全屏 / 静音是反馈里点名的两条）。
        final List<String> texts = <String>[
          for (final Element e in find.byType(Text).evaluate())
            if ((e.widget as Text).data case final String s) s,
        ];
        debugPrint(
          '[bar-overflow] shortcut page has fullscreen row: '
          '${texts.contains(t.shortcut_action_video_toggle_fullscreen)} '
          'mute row: ${texts.contains(t.shortcut_action_video_toggle_mute)}',
        );
        expect(texts.contains(t.shortcut_action_video_toggle_mute), isTrue);
        await shot('05-shortcut-settings-video');

        // 返回播放器：页面仍在。
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pumpFor(const Duration(milliseconds: 1500));
        debugPrint(
          '[bar-overflow] after back: shortcutPage='
          '${find.byType(ShortcutSettingsPage).evaluate().length} '
          'videoPage=${find.byType(VideoFushiPage).evaluate().length}',
        );
        expect(find.byType(VideoFushiPage), findsOneWidget);

        expect(
          errors,
          isEmpty,
          reason: errors.map((e) => e.exceptionAsString()).join('\n'),
        );
      } finally {
        FlutterError.onError = oldHandler;
        try {
          final ProviderContainer container = ProviderScope.containerOf(
            tester.element(find.byType(MaterialApp).first),
          );
          final FushiDatabase db = container.read(appProvider).database;
          await (db.delete(
            db.videoBooks,
          )..where((VideoBooks t) => t.bookUid.equals(_kVideoBookUid))).go();
        } catch (_) {}
      }
    },
    skip: !Platform.isWindows,
  );
}
