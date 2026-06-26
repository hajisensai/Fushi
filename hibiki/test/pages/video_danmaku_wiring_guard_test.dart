import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/utils.dart';
import 'video_hibiki_page_source_corpus.dart';

VideoQuickSettingsSheet _sheet({
  void Function(bool)? onDanmakuEnabledChanged,
  void Function(bool)? onDanmakuOnlineEnabledChanged,
  void Function(int)? onDanmakuMaxActiveChanged,
}) {
  return VideoQuickSettingsSheet(
    initialDelayMs: 0,
    initialSpeed: 1.0,
    initialSubtitleObscureMode: VideoSubtitleObscureMode.none,
    initialSubtitleStyle: VideoSubtitleStyle.defaults,
    onSetDelay: (_) async {},
    onPreviewSpeed: (_) async {},
    onSetSpeed: (_) async {},
    onSetSubtitleObscureMode: (_) async {},
    onSubtitleStylePreview: (_) {},
    onSubtitleStyleCommit: (_) async {},
    initialAsbConfig: VideoAsbplayerConfig.defaults,
    onAsbConfigChanged: (_) async {},
    initialShadersEnabled: const <String>[],
    onApplyShaders: (_) async {},
    onSelectShaderTier: (_, __, ___) async {},
    initialMpvConfig: VideoMpvConfig.defaults,
    onMpvConfigChanged: (_) async {},
    initialLockWindowAspectRatio: true,
    onLockWindowAspectRatioChanged: (_) async {},
    initialVideoFitMode: VideoFitMode.cover,
    onVideoFitModeChanged: (_) async {},
    initialImmersiveMode: VideoImmersiveMode.lookupOnly,
    onImmersiveModeChanged: (_) async {},
    initialDanmakuEnabled: true,
    initialDanmakuMaxActive: kDefaultVideoDanmakuMaxActive,
    onDanmakuEnabledChanged: (bool value) async {
      onDanmakuEnabledChanged?.call(value);
    },
    onDanmakuOnlineEnabledChanged: (bool value) async {
      onDanmakuOnlineEnabledChanged?.call(value);
    },
    onDanmakuMaxActiveChanged: (int value) async {
      onDanmakuMaxActiveChanged?.call(value);
    },
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('video settings exposes danmaku switch and active limit',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    bool? enabled;
    bool? onlineEnabled;
    int? maxActive;
    await _pump(
      tester,
      _sheet(
        onDanmakuEnabledChanged: (bool value) => enabled = value,
        onDanmakuOnlineEnabledChanged: (bool value) => onlineEnabled = value,
        onDanmakuMaxActiveChanged: (int value) => maxActive = value,
      ),
    );

    // TODO-640：顶栏分类 chip 改纯图标（无文字），按稳定 id key 命中弹幕分类。
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
}
