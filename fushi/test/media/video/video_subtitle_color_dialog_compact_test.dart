// PM-iIH9G0b：手机（384x853dp）上字幕取色对话框的排版与「无描边」。
//
// ① 横屏 853x384 时对话框内容区只剩 ~100dp，旧实现把 300x300 的包内 ColorPicker
//    塞进 SingleChildScrollView：色板被裁成一条、色相条（换色系）与 Hex 输入不可见，
//    色板又吃掉竖向拖动，滚动视图滚不下去。现由 FushiDialogColorPicker 按内容区约束
//    反推尺寸：整块取色器一屏放下（maxScrollExtent == 0），色相条与 Hex 输入都在
//    可见区内。
// ② 描边取色对话框带「无描边」，点了把粗细归 0；只打开看一眼就「完成」不得 commit
//    （旧实现关闭即 commit，会把粗细从 0 顶回 2px，描边关不掉）。
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_settings_actions.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_dialog_color_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/video_quick_settings_harness.dart';

Widget _app(Widget home, {bool apple = false}) {
  return TranslationProvider(
    child: MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF006C52)),
        extensions: <ThemeExtension<dynamic>>[
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
        ],
      ).copyWith(platform: TargetPlatform.android),
      themeAnimationDuration: Duration.zero,
      locale: const Locale('en'),
      supportedLocales: const <Locale>[Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: home,
    ),
  );
}

Future<void> _pumpRow(
  WidgetTester tester,
  VideoSheetHarness harness,
  Widget Function(SettingsContext context) row, {
  TestVideoHostState? hostState,
  List<VideoSubtitleStyle>? commits,
  bool apple = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: _app(
        apple: apple,
        Scaffold(
          body: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? child) {
              return row(
                SettingsContext(
                  context: context,
                  appModel: harness.appModel,
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                  video: hostState == null
                      ? null
                      : buildTestVideoHost(
                          state: hostState,
                          onSubtitleStyleCommit: commits?.add,
                        ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _setScreen(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 2.8125;
  tester.view.physicalSize = logical * 2.8125;
  addTearDown(tester.view.reset);
}

/// 断言 [finder] 的整个矩形落在取色器滚动视口内（没有被裁掉）。
void _expectInsideViewport(WidgetTester tester, Finder finder, Rect viewport) {
  final Rect rect = tester.getRect(finder);
  expect(
    rect.top >= viewport.top - 0.5 && rect.bottom <= viewport.bottom + 0.5,
    isTrue,
    reason: '$finder 被裁出可见区：rect=$rect viewport=$viewport',
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    for (final Size screen in <Size>[
      const Size(384, 853), // 反馈机竖屏
      const Size(853, 384), // 反馈机横屏（视频全屏播放时）
    ]) {
      testWidgets('PM-iIH9G0b: color dialog fits on ${screen.width.toInt()}x'
          '${screen.height.toInt()} without clipping '
          '(${apple ? 'Apple' : 'MD3'})', (WidgetTester tester) async {
        _setScreen(tester, screen);
        final VideoSheetHarness harness = await VideoSheetHarness.create();
        addTearDown(harness.dispose);
        await _pumpRow(
          tester,
          harness,
          buildVideoSubtitleOutlineColorRow,
          hostState: TestVideoHostState(),
          apple: apple,
        );
        await tester.tap(find.text(t.video_setting_subtitle_outline_color));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '不得有 RenderFlex 溢出');

        final Finder pickerScroll = find.descendant(
          of: find.byType(FushiDialogColorPicker),
          matching: find.byType(Scrollable),
        );
        final ScrollableState scrollable = tester.state(pickerScroll.first);
        expect(
          scrollable.position.maxScrollExtent,
          0,
          reason: '整块取色器应一屏放下，不依赖被色板吃掉手势的滚动',
        );
        final Rect viewport = tester.getRect(pickerScroll.first);
        final Finder area = find.byType(ColorPickerArea);
        _expectInsideViewport(tester, area, viewport);
        expect(
          tester.getSize(area).height,
          greaterThanOrEqualTo(FushiDialogColorPicker.minPaletteExtent),
        );
        // 色相条 = 换色系；Hex 输入；两者都必须完整可见。
        _expectInsideViewport(tester, find.byType(ColorPickerSlider), viewport);
        _expectInsideViewport(tester, find.byType(ColorPickerInput), viewport);
        // 对话框动作（完成 / 无描边）也在屏内。
        final Rect done = tester.getRect(find.text(t.dialog_done));
        expect(done.bottom <= screen.height, isTrue);
        expect(find.text(t.video_setting_subtitle_no_outline), findsOneWidget);
      });
    }
  }

  testWidgets('PM-iIH9G0b: "No outline" turns the outline off', (
    WidgetTester tester,
  ) async {
    _setScreen(tester, const Size(853, 384));
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    final TestVideoHostState state = TestVideoHostState(
      subtitleStyle: VideoSubtitleStyle.defaults.copyWith(
        outlineThickness: 3,
        outlineColor: const Color(0xFFFF0000),
      ),
    );
    final List<VideoSubtitleStyle> commits = <VideoSubtitleStyle>[];
    await _pumpRow(
      tester,
      harness,
      buildVideoSubtitleOutlineColorRow,
      hostState: state,
      commits: commits,
    );
    await tester.tap(find.text(t.video_setting_subtitle_outline_color));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_setting_subtitle_no_outline));
    await tester.pumpAndSettle();
    expect(commits, hasLength(1));
    expect(commits.single.outlineThickness, 0);
    expect(state.subtitleStyle.outlineThickness, 0);
    // 颜色保留：下次拉起粗细仍是用户选过的颜色。
    expect(state.subtitleStyle.outlineColor, const Color(0xFFFF0000));
  });

  testWidgets(
    'PM-iIH9G0b: opening the outline dialog and pressing Done without '
    'picking does not re-enable a disabled outline',
    (WidgetTester tester) async {
      final VideoSheetHarness harness = await VideoSheetHarness.create();
      addTearDown(harness.dispose);
      final TestVideoHostState state = TestVideoHostState(
        subtitleStyle: VideoSubtitleStyle.defaults.copyWith(
          outlineThickness: 0,
        ),
      );
      final List<VideoSubtitleStyle> commits = <VideoSubtitleStyle>[];
      await _pumpRow(
        tester,
        harness,
        buildVideoSubtitleOutlineColorRow,
        hostState: state,
        commits: commits,
      );
      await tester.tap(find.text(t.video_setting_subtitle_outline_color));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.dialog_done));
      await tester.pumpAndSettle();
      expect(commits, isEmpty, reason: '没选色就不该 commit');
      expect(state.subtitleStyle.outlineThickness, 0);
    },
  );

  testWidgets(
    'PM-iIH9G0b: without a player host the outline dialog writes the pref',
    (WidgetTester tester) async {
      final VideoSheetHarness harness = await VideoSheetHarness.create();
      addTearDown(harness.dispose);
      await tester.runAsync(
        () => harness.appModel.setVideoSubtitleStyle(
          VideoSubtitleStyle.encode(
            VideoSubtitleStyle.defaults.copyWith(outlineThickness: 2),
          ),
        ),
      );
      await _pumpRow(tester, harness, buildVideoSubtitleOutlineColorRow);
      await tester.tap(find.text(t.video_setting_subtitle_outline_color));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.video_setting_subtitle_no_outline));
      await tester.pumpAndSettle();
      expect(
        VideoSubtitleStyle.decode(
          harness.appModel.videoSubtitleStyle,
        ).outlineThickness,
        0,
      );
    },
  );
}
