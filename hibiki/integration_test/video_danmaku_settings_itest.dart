// 真机集成测试（Windows 离屏）：TODO-1376 弹幕增强在真实桌面 app 上：
// ① 弹幕设置分类可达并渲染样式滑块 / 屏蔽词输入框 / 手动匹配入口（UI 可调）。
// ② 屏蔽词落盘并真生效（parseVideoDanmakuBlockRules + filterVideoDanmaku 依当前规则过滤）。
// ③ 样式滑块 commit 落盘（appModel.videoDanmakuStyle 真变化）。
// ④ 手动搜索 / 选集侧栏可开（手动匹配入口可达，DanmakuManualMatchPanel 渲染）。
//
// 运行：hibiki/ 下 `.\tool\run_windows_itest.ps1 integration_test\video_danmaku_settings_itest.dart`
// （FUSHI_TEST_HIDDEN 离屏）。需真机 media_kit native + 测试视频
// D:\hibiki_video_test\sample.mp4（本机已置）。
//
// 真实弹幕匹配（弹弹play 网络搜索 / 拉评论）不在此测——需真视频指纹 + 外网，是真机门。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/video/danmaku_manual_match_panel.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import 'test_helpers.dart';

const String _kVideoFixture = r'D:\hibiki_video_test\sample.mp4';
const String _kVideoBookUid = 'video/danmaku-itest-sample';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'danmaku settings: style sliders + block filter + manual match reachable',
    (WidgetTester tester) async {
      app.main();
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);

      final File fixture = File(_kVideoFixture);
      expect(fixture.existsSync(), isTrue, reason: '测试视频 $_kVideoFixture 应存在');

      await repo.saveVideoBook(VideoBooksCompanion(
        bookUid: const Value(_kVideoBookUid),
        title: const Value('danmaku itest'),
        videoPath: Value(fixture.absolute.path),
      ));

      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => VideoFushiPage(bookUid: _kVideoBookUid, repo: repo),
      )));

      VideoFushiTestHooks hooks() =>
          tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
              as VideoFushiTestHooks;
      bool ready = false;
      for (int i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byType(VideoFushiPage).evaluate().isNotEmpty &&
            hooks().debugPositionMs != null) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: 'video controller should load');

      // ── ① 打开弹幕设置分类，断言样式滑块 + 屏蔽词框 + 手动匹配入口渲染 ──
      hooks().debugOpenDanmakuSettings();
      await tester.pumpAndSettle();

      expect(find.textContaining(t.video_setting_danmaku_font_scale),
          findsWidgets);
      expect(
          find.textContaining(t.video_setting_danmaku_opacity), findsWidgets);
      expect(find.textContaining(t.video_setting_danmaku_speed), findsWidgets);
      expect(find.textContaining(t.video_setting_danmaku_area), findsWidgets);
      expect(
          find.byKey(const Key('danmaku-block-rules-field')), findsOneWidget);
      expect(
        find.widgetWithText(
          AdaptiveSettingsNavigationRow,
          t.video_setting_danmaku_manual_match,
        ),
        findsOneWidget,
      );
      debugPrint('[danmaku-itest] danmaku settings category rendered');

      // ── ② 屏蔽词输入 → 落盘 + 真生效（filterVideoDanmaku 依当前规则过滤） ──
      await tester.enterText(
        find.byKey(const Key('danmaku-block-rules-field')),
        'spoiler',
      );
      await tester.pumpAndSettle();
      expect(appModel.videoDanmakuBlockRulesText, contains('spoiler'),
          reason: '屏蔽词应落盘');
      final VideoDanmakuBlockRules rules =
          parseVideoDanmakuBlockRules(appModel.videoDanmakuBlockRulesText);
      const VideoDanmakuItem blocked = VideoDanmakuItem(
        startMs: 0,
        text: 'a spoiler!',
        mode: VideoDanmakuMode.scroll,
        colorArgb: 0xFFFFFFFF,
      );
      const VideoDanmakuItem kept = VideoDanmakuItem(
        startMs: 0,
        text: 'keep me',
        mode: VideoDanmakuMode.scroll,
        colorArgb: 0xFFFFFFFF,
      );
      final List<VideoDanmakuItem> visible = filterVideoDanmaku(
        <VideoDanmakuItem>[blocked, kept],
        rules,
      );
      expect(visible.map((VideoDanmakuItem i) => i.text), <String>['keep me'],
          reason: '屏蔽词过滤应真生效');
      debugPrint('[danmaku-itest] block filter persisted + effective');

      // ── ③ 样式滑块 commit → 落盘（真生效） ──
      final AdaptiveSettingsSliderRow fontRow =
          tester.widget<AdaptiveSettingsSliderRow>(
        find.byWidgetPredicate((Widget w) =>
            w is AdaptiveSettingsSliderRow &&
            w.title == t.video_setting_danmaku_font_scale),
      );
      fontRow.onChangeEnd!(1.6);
      await tester.pumpAndSettle();
      expect(appModel.videoDanmakuStyle.fontScale, closeTo(1.6, 0.001),
          reason: '弹幕字号样式应落盘真生效');
      debugPrint(
          '[danmaku-itest] style fontScale=${appModel.videoDanmakuStyle.fontScale}');

      // ── ④ 手动搜索 / 选集侧栏可开 ──
      hooks().debugOpenDanmakuMatch();
      await tester.pumpAndSettle();
      expect(find.byType(DanmakuManualMatchPanel), findsOneWidget,
          reason: '手动匹配入口可达');
      expect(
          find.byKey(const Key('danmaku-manual-search-field')), findsOneWidget);
      debugPrint('[danmaku-itest] manual match panel opened');
    },
  );
}
