// 网页档设置面板「画质增强」页签（拍板 kp-No6loQi：页签不能整页消失；拍板 cbKi3PN0G7-r2：
// 两档同一个播放器，切换入口放这一页）：上面是「制卡优先 / 画质优先」二选一，下面是本档的
// 画质增强——制卡优先能选超分档位，画质优先由站点直接绘制、给一行说明。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/video_web_playback_mode_panel.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/pages/implementations/video_shader_dialog.dart';
import 'package:fushi/src/settings/settings_destination.dart' show VideoGroup;

import '../../helpers/video_quick_settings_harness.dart';

const ValueKey<String> _captureRowKey = ValueKey<String>(
  'video.player.web_mode.builtin',
);
const ValueKey<String> _qualityRowKey = ValueKey<String>(
  'video.player.web_mode.windowed',
);
const ValueKey<String> _tierRowKey = ValueKey<String>(
  'video.player.web_mode.shader_tier',
);
const ValueKey<String> _unavailableKey = ValueKey<String>(
  'video.player.web_mode.shaders_unavailable',
);

Future<void> _pumpShadersPage(
  WidgetTester tester,
  VideoSheetHarness harness, {
  VideoWebPlaybackModeHost? web,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: buildVideoSheetUnderTest(
          harness: harness,
          host: buildTestVideoHost(),
          initialCategory: VideoGroup.shaders.name,
          groups: const <VideoGroup>[
            VideoGroup.playback,
            VideoGroup.shaders,
            VideoGroup.controls,
          ],
          webPlaybackMode: web,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

VideoWebPlaybackModeHost _host({
  required WebVideoHosting current,
  bool qualityFirstAvailable = true,
  List<WebVideoHosting>? modes,
  List<VideoShaderTier>? tiers,
}) => VideoWebPlaybackModeHost(
  current: current,
  qualityFirstAvailable: qualityFirstAvailable,
  onSelectMode: (WebVideoHosting m) => modes?.add(m),
  shaderTier: VideoShaderTier.off,
  onSelectShaderTier: (VideoShaderTier tier) => tiers?.add(tier),
);

void main() {
  testWidgets('制卡优先：两档都列出、当前档打勾；能选超分档位，点「画质优先」换档', (WidgetTester tester) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    final List<WebVideoHosting> modes = <WebVideoHosting>[];
    final List<VideoShaderTier> tiers = <VideoShaderTier>[];
    await _pumpShadersPage(
      tester,
      harness,
      web: _host(current: WebVideoHosting.builtin, modes: modes, tiers: tiers),
    );

    expect(
      find.byKey(
        ValueKey<String>('video-settings-cat-${VideoGroup.shaders.name}'),
      ),
      findsOneWidget,
    );
    expect(find.byType(VideoShaderManagerView), findsNothing);
    expect(find.byKey(_captureRowKey), findsOneWidget);
    expect(find.byKey(_qualityRowKey), findsOneWidget);
    expect(find.text(t.web_video_mode_capture_title), findsOneWidget);
    expect(find.text(t.web_video_mode_capture_subtitle), findsOneWidget);
    expect(find.text(t.web_video_mode_quality_title), findsOneWidget);
    expect(find.text(t.web_video_mode_quality_subtitle), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_captureRowKey),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(find.byKey(_tierRowKey), findsOneWidget);
    expect(find.byKey(_unavailableKey), findsNothing);

    await tester.tap(find.text(t.video_shader_tier_medium));
    await tester.pump();
    expect(tiers, <VideoShaderTier>[VideoShaderTier.medium]);

    // 当前档再点不换档。
    await tester.tap(find.text(t.web_video_mode_capture_title));
    await tester.pump();
    expect(modes, isEmpty);
    await tester.tap(find.text(t.web_video_mode_quality_title));
    await tester.pump();
    expect(modes, <WebVideoHosting>[WebVideoHosting.windowed]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画质优先：没有超分档位，改画一行说明；点「制卡优先」换档', (WidgetTester tester) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    final List<WebVideoHosting> modes = <WebVideoHosting>[];
    await _pumpShadersPage(
      tester,
      harness,
      web: _host(current: WebVideoHosting.windowed, modes: modes),
    );

    expect(find.byKey(_tierRowKey), findsNothing);
    expect(find.byKey(_unavailableKey), findsOneWidget);
    expect(find.text(t.web_video_mode_shaders_unavailable), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_qualityRowKey),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(t.web_video_mode_capture_title));
    await tester.pump();
    expect(modes, <WebVideoHosting>[WebVideoHosting.builtin]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('引擎不支持底层合成：「画质优先」行写明不可用、点了不换档', (WidgetTester tester) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    final List<WebVideoHosting> modes = <WebVideoHosting>[];
    await _pumpShadersPage(
      tester,
      harness,
      web: _host(
        current: WebVideoHosting.builtin,
        qualityFirstAvailable: false,
        modes: modes,
      ),
    );

    expect(find.text(t.web_video_mode_quality_unavailable), findsOneWidget);
    expect(find.text(t.web_video_mode_quality_subtitle), findsNothing);
    await tester.tap(find.text(t.web_video_mode_quality_title));
    await tester.pump();
    expect(modes, isEmpty);
  });

  testWidgets('本地档：画质增强页照旧是着色器管理视图，没有网页档位', (WidgetTester tester) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    await _pumpShadersPage(tester, harness);

    expect(find.byType(VideoShaderManagerView), findsOneWidget);
    expect(find.byKey(_captureRowKey), findsNothing);
    expect(find.byKey(_tierRowKey), findsNothing);
  });
}
