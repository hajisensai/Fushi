import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/utils.dart';
import '../helpers/video_quick_settings_harness.dart';
import 'video_hibiki_page_source_corpus.dart';

// 阶段 B：面板消费 schema 投影，widget 用例经共享 harness（内存 DB AppModel +
// 可变状态 host）构造；行为断言（回调写穿）保持不变。
Future<VideoSheetHarness> _pumpSheet(
  WidgetTester tester, {
  void Function(bool)? onDanmakuEnabledChanged,
  void Function(bool)? onDanmakuOnlineEnabledChanged,
  void Function(int)? onDanmakuMaxActiveChanged,
  void Function(VideoDanmakuStyle)? onDanmakuStylePreview,
  void Function(VideoDanmakuStyle)? onDanmakuStyleCommit,
  void Function(String)? onDanmakuBlockRulesChanged,
  VoidCallback? onManualDanmakuMatch,
}) async {
  final VideoSheetHarness harness = await VideoSheetHarness.create();
  addTearDown(harness.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: buildVideoSheetUnderTest(
          harness: harness,
          host: buildTestVideoHost(
            onDanmakuEnabledChanged: onDanmakuEnabledChanged ?? (_) {},
            onDanmakuOnlineEnabledChanged:
                onDanmakuOnlineEnabledChanged ?? (_) {},
            onDanmakuMaxActiveChanged: onDanmakuMaxActiveChanged ?? (_) {},
            onDanmakuStylePreview: onDanmakuStylePreview,
            onDanmakuStyleCommit: onDanmakuStyleCommit,
            onDanmakuBlockRulesChanged: onDanmakuBlockRulesChanged,
            onManualDanmakuMatch: onManualDanmakuMatch,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return harness;
}

void main() {
  testWidgets('video settings exposes danmaku switch and active limit',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    bool? enabled;
    bool? onlineEnabled;
    int? maxActive;
    await _pumpSheet(
      tester,
      onDanmakuEnabledChanged: (bool value) => enabled = value,
      onDanmakuOnlineEnabledChanged: (bool value) => onlineEnabled = value,
      onDanmakuMaxActiveChanged: (int value) => maxActive = value,
    );

    // 按稳定 id key 命中弹幕分类 chip（不依赖标签文案）。TODO-1351 全文标签把顶栏
    // 撑宽，末位分类可能在横滑视口外，先滑入视口再点（模拟真实用户横滑）。
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('video-settings-cat-danmaku')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-settings-cat-danmaku')),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.video_setting_danmaku_enabled), findsOneWidget);
    expect(find.text(t.video_setting_danmaku_online), findsOneWidget);
    expect(find.text(t.video_setting_danmaku_max_active), findsOneWidget);

    final AdaptiveSettingsSwitchRow enabledRow =
        tester.widget<AdaptiveSettingsSwitchRow>(
      find.widgetWithText(
        AdaptiveSettingsSwitchRow,
        t.video_setting_danmaku_enabled,
      ),
    );
    enabledRow.onChanged!(false);
    await tester.pump();
    expect(enabled, isFalse);

    final AdaptiveSettingsSwitchRow onlineRow =
        tester.widget<AdaptiveSettingsSwitchRow>(
      find.widgetWithText(
        AdaptiveSettingsSwitchRow,
        t.video_setting_danmaku_online,
      ),
    );
    onlineRow.onChanged!(false);
    await tester.pump();
    expect(onlineEnabled, isFalse);

    final AdaptiveSettingsStepperRow maxRow =
        tester.widget<AdaptiveSettingsStepperRow>(
      find.widgetWithText(
        AdaptiveSettingsStepperRow,
        t.video_setting_danmaku_max_active,
      ),
    );
    maxRow.onChanged(120);
    await tester.pump();
    expect(maxActive, 120);
  });

  testWidgets('video settings exposes danmaku style, filter and manual match',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoDanmakuStyle? preview;
    VideoDanmakuStyle? committed;
    String? rules;
    bool manualOpened = false;
    await _pumpSheet(
      tester,
      onDanmakuStylePreview: (VideoDanmakuStyle s) => preview = s,
      onDanmakuStyleCommit: (VideoDanmakuStyle s) => committed = s,
      onDanmakuBlockRulesChanged: (String v) => rules = v,
      onManualDanmakuMatch: () => manualOpened = true,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('video-settings-cat-danmaku')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-settings-cat-danmaku')),
    );
    await tester.pumpAndSettle();

    // Style sliders present.
    expect(find.textContaining(t.video_setting_danmaku_font_scale),
        findsOneWidget);
    expect(
        find.textContaining(t.video_setting_danmaku_opacity), findsOneWidget);
    expect(find.textContaining(t.video_setting_danmaku_speed), findsOneWidget);
    expect(find.textContaining(t.video_setting_danmaku_area), findsOneWidget);

    // Font-scale slider preview + commit reach the callbacks.
    final AdaptiveSettingsSliderRow fontRow =
        tester.widget<AdaptiveSettingsSliderRow>(
      find.byWidgetPredicate((Widget w) =>
          w is AdaptiveSettingsSliderRow &&
          w.title.startsWith(t.video_setting_danmaku_font_scale)),
    );
    fontRow.onChanged(1.5);
    await tester.pump();
    expect(preview?.fontScale, 1.5);
    fontRow.onChangeEnd!(1.5);
    await tester.pump();
    expect(committed?.fontScale, 1.5);

    // Manual match navigation row triggers the callback.
    final AdaptiveSettingsNavigationRow manualRow =
        tester.widget<AdaptiveSettingsNavigationRow>(
      find.widgetWithText(
        AdaptiveSettingsNavigationRow,
        t.video_setting_danmaku_manual_match,
      ),
    );
    manualRow.onTap();
    await tester.pump();
    expect(manualOpened, isTrue);

    // Block-rules field forwards edits.
    await tester.enterText(
      find.byKey(const Key('danmaku-block-rules-field')),
      'spoiler',
    );
    await tester.pump();
    expect(rules, 'spoiler');
  });

  test(
      'source guard: danmaku layer is local-only, non-blocking and under subtitles',
      () {
    final String page = readVideoHibikiSource();
    final String overlay =
        File('lib/src/media/video/video_danmaku_overlay.dart')
            .readAsStringSync();
    final String model =
        File('lib/src/media/video/video_danmaku_model.dart').readAsStringSync();
    final String source = File('lib/src/media/video/video_danmaku_source.dart')
        .readAsStringSync();

    expect(page, contains('findDanmakuSidecar'));
    expect(page, contains('loadDanmakuSidecarFile'));
    expect(page, contains('VideoDanmakuOverlay'));
    expect(overlay, contains('IgnorePointer'));
    expect(page, isNot(contains('dandanplay.com')),
        reason: 'TODO-259/260 只做本地 MVP，不实现在线 Dandanplay endpoint');

    final int danmakuIdx = page.indexOf('VideoDanmakuOverlay(');
    final int subtitleIdx = page.indexOf('VideoSubtitleOverlay(');
    expect(danmakuIdx, greaterThanOrEqualTo(0));
    expect(subtitleIdx, greaterThan(danmakuIdx),
        reason: '弹幕应画在可点击字幕下方，字幕/查词路径保持在更上层');

    for (final String src in <String>[overlay, model, source]) {
      expect(src, isNot(contains('AudioCue')),
          reason: '弹幕不能复用字幕/有声书 currentCue 语义');
      expect(src, isNot(contains('currentCue')),
          reason: '弹幕是多条同时活动，不是单 currentCue');
    }
  });

  test('source guard: danmaku settings reload or clear the current video', () {
    final String page = readVideoHibikiSource();

    expect(page, contains('Future<void> _setVideoDanmakuEnabled'));
    expect(page, contains('Future<void> _setVideoDanmakuOnlineEnabled'));
    expect(page, contains('Future<void> _setVideoDanmakuMaxActive'));
    expect(page, contains('void _clearDanmakuForCurrentVideo'));
    expect(page, contains('++_danmakuLoadSeq'));
    expect(
        page, contains('unawaited(_loadDanmakuForVideo(_currentVideoPath))'));
    expect(page, contains('onDanmakuEnabledChanged: _setVideoDanmakuEnabled'));
    expect(
      page,
      contains('onDanmakuOnlineEnabledChanged: _setVideoDanmakuOnlineEnabled'),
    );
    expect(
        page, contains('onDanmakuMaxActiveChanged: _setVideoDanmakuMaxActive'));
    expect(
      page,
      isNot(
          contains('onDanmakuEnabledChanged: appModel.setVideoDanmakuEnabled')),
    );
  });

  test('source guard: danmaku style/filter/manual-match wired end to end', () {
    final String page = readVideoHibikiSource();
    final String overlay =
        File('lib/src/media/video/video_danmaku_overlay.dart')
            .readAsStringSync();
    final String layout = File('lib/src/media/video/video_danmaku_layout.dart')
        .readAsStringSync();

    // Overlay consumes the block-filtered list and applies the style.
    expect(page, contains('items: _danmakuVisibleItems'));
    expect(page, contains('style: _danmakuStyle'));
    expect(overlay, contains('style.opacity'));
    expect(overlay, contains('fontScale'));
    expect(layout, contains('areaFraction'));
    expect(layout, contains('fontScale'));

    // Page wires style preview/commit + block rules + manual match.
    expect(page, contains('onDanmakuStylePreview: _previewVideoDanmakuStyle'));
    expect(page, contains('onDanmakuStyleCommit: _setVideoDanmakuStyle'));
    expect(
      page,
      contains('onDanmakuBlockRulesChanged: _setVideoDanmakuBlockRules'),
    );
    expect(page, contains('onManualDanmakuMatch: _openDanmakuManualMatch'));
    expect(page, contains('Future<void> _bindDanmakuEpisode'));
    expect(page, contains('client.searchEpisodes'));
    expect(page, contains('filterVideoDanmaku'));
  });

  test(
      'BUG-1057 source guard: manual bind gates on fetch status before '
      'persisting the episode', () {
    final String page = readVideoHibikiSource();
    final int start = page.indexOf('Future<void> _bindDanmakuEpisode');
    expect(start, greaterThanOrEqualTo(0));
    final int end = page.indexOf('\n  /// 手动匹配侧栏内容', start);
    expect(end, greaterThan(start));
    final String body = page.substring(start, end);

    // 失败必须先于「落 episodeId」返回：此前非 2xx 被吞成空列表，直接走成功分支
    // （面板关闭 + episodeId 落库 + 弹幕为空 + 零提示）。
    final int gate = body.indexOf('result.status != DandanplayFetchStatus.hit');
    final int persist = body.indexOf('setVideoDanmakuEpisodeId');
    expect(gate, greaterThanOrEqualTo(0), reason: '手动绑定必须检查拉弹幕的状态，而不是只看是否抛异常');
    expect(persist, greaterThan(gate),
        reason: '拉弹幕失败时不得持久化 episodeId，否则下次自动加载会记住一个错的集');
    expect(body.indexOf('return;', gate), lessThan(persist),
        reason: '失败分支必须直接 return，不落库不关面板');

    // 失败按类型给具体文案，而不是一句笼统的「请稍后重试」。
    expect(body, contains('t.video_danmaku_manual_network_error'));
    expect(body, contains('t.video_danmaku_manual_bind_server_error'));
    // 该集有效但 0 条弹幕：绑定生效，但要说清楚。
    expect(body, contains('t.video_danmaku_manual_bind_empty'));
  });

  test(
      'BUG-1057 source guard: cached-episode load only re-matches on a genuine '
      'empty hit', () {
    final String page = readVideoHibikiSource();
    final int start = page.indexOf('Future<void> _loadDanmakuForVideo');
    expect(start, greaterThanOrEqualTo(0));
    final int end = page.indexOf('void _clearDanmakuForCurrentVideo', start);
    expect(end, greaterThan(start));
    final String body = page.substring(start, end);

    expect(
      body,
      contains('cached.status == DandanplayFetchStatus.hit &&'),
      reason: '记住的集拉失败时不得退回整文件匹配——那只会白算一次 16MiB hash 再失败一遍',
    );
    expect(body, contains('cached.items.isEmpty'));
  });
}
