// 拍板 kp-No6loQi（反馈「视频播放画质增强按钮没有了」）：网页站点后端（WebView2 底层
// 合成）里着色器不生效，以前整页「画质增强」页签被去掉，用户以为功能消失。现在页签留着、
// 画成说明态：为什么不生效 + 「切换到内置网页播放器」入口（内置档有自己的超分）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_shader_dialog.dart';
import 'package:fushi/src/settings/settings_destination.dart' show VideoGroup;

import '../../helpers/video_quick_settings_harness.dart';

const ValueKey<String> _noticeKey = ValueKey<String>(
  'video.player.web_shaders_notice',
);
const ValueKey<String> _switchKey = ValueKey<String>(
  'video.player.web_switch_builtin',
);

Future<void> _pumpShadersPage(
  WidgetTester tester,
  VideoSheetHarness harness, {
  required bool webBackend,
  VoidCallback? onSwitch,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
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
          webBackend: webBackend,
          onSwitchToBuiltinWebPlayer: onSwitch,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('网页档：画质增强页签还在，页内是说明态 + 切换入口，不画着色器管理视图', (
    WidgetTester tester,
  ) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    int switched = 0;
    await _pumpShadersPage(
      tester,
      harness,
      webBackend: true,
      onSwitch: () => switched++,
    );

    expect(
      find.byKey(
        ValueKey<String>('video-settings-cat-${VideoGroup.shaders.name}'),
      ),
      findsOneWidget,
    );
    expect(find.byType(VideoShaderManagerView), findsNothing);
    expect(find.byKey(_noticeKey), findsOneWidget);
    expect(find.text(t.video_settings_web_shaders_unavailable), findsOneWidget);
    expect(
      find.text(t.video_settings_web_shaders_unavailable_hint),
      findsOneWidget,
    );

    expect(find.byKey(_switchKey), findsOneWidget);
    await tester.tap(find.text(t.video_settings_web_switch_builtin));
    await tester.pump();
    expect(switched, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网页档无切换入口（站点入口，内置档读不到）：只有说明，没有切换行', (WidgetTester tester) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    await _pumpShadersPage(tester, harness, webBackend: true);

    expect(find.byKey(_noticeKey), findsOneWidget);
    expect(find.byKey(_switchKey), findsNothing);
    expect(find.byType(VideoShaderManagerView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地档：画质增强页照旧是着色器管理视图，没有说明态', (WidgetTester tester) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    await _pumpShadersPage(tester, harness, webBackend: false);

    expect(find.byType(VideoShaderManagerView), findsOneWidget);
    expect(find.byKey(_noticeKey), findsNothing);
    expect(find.byKey(_switchKey), findsNothing);
  });
}
