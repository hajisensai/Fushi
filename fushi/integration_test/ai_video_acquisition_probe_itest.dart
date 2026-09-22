/// 「AI 下视频」真 app 探针（Windows 离屏 runner）。
///
/// 证明的是**确定性路径**在真 app 里走得通：AI 提供商指向一个连不上的端口 →
/// 意图解析失败 → 对话页退化成「原文当查询词 + chip」→ 真 MAL（Jikan）搜作品 →
/// 候选 / 详情 → 逐槽位提问（画质 / 字幕语言）→ 真 Nyaa 搜资源 → 摘要确认。
/// 每一步抓真像素帧到 `.codex-test/windows-itest/<runId>/screenshots/observe-*.png`。
///
/// 不真的入队（没有下载后端 runtime 时 confirm 会走「配置后端」失败态，也抓一帧）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/ai_video_acquisition_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'dart:io';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AI 下视频：真 app 里从一句话走到版本摘要（AI 不可用退化路径）', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    await enableFocusNavigation(tester);

    // 受管视频来源（对话页打开前置）。
    final Directory library = await Directory.systemTemp.createTemp(
      'fushi-ai-acquire-probe-',
    );
    final int sourceId = await appModel.database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Probe videos',
        mediaKind: 'video',
        rootPath: library.path,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await appModel.prefsRepo.setVideoDownloadTargetSourceId(sourceId);

    // 一个必然连不上的 AI 提供商：意图解析失败 → 退化成 chip 路径，正是要验的东西。
    final AiProviderConfig provider = AiProviderConfig(
      id: 'probe-unreachable',
      presetId: kAiCustomPresetId,
      name: 'probe',
      baseUrl: Uri.parse('http://127.0.0.1:9/v1'),
      apiKey: 'k',
      model: 'm',
      allowInsecureHttp: true,
    );
    await appModel.prefsRepo.setAiProviders(<AiProviderConfig>[provider]);
    await appModel.prefsRepo.setAiFeatureAssignments(
      appModel.prefsRepo.aiFeatureAssignments.withAssignment(
        AiFeature.videoAcquire,
        provider.id,
      ),
    );
    // 真 MAL / Nyaa 走本机代理（Clash 7890）；AI 那个 127.0.0.1:9 是直连目标，照样连不上。
    await appModel.prefsRepo.setUpdateCustomProxy('http://127.0.0.1:7890');
    await appModel.prefsRepo.setNetworkProxyMode('manual');
    // 画质固定、字幕语言未设置：第一次会问字幕语言（预选「跟随作品语言」）。
    await appModel.prefsRepo.setAiVideoDownloadQuality('1080p');
    await appModel.prefsRepo.setAiVideoDownloadSubtitleLanguage('');

    if (appModel.videoResourceRegistry == null) {
      await appModel.startAnimeDownloadService();
    }
    for (int i = 0; i < 20 && appModel.videoResourceRegistry == null; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    debugPrint(
      '[ai-acquire-probe] registry=${appModel.videoResourceRegistry != null} '
      'pipeline=${appModel.videoDownloadPipelineService != null}',
    );

    HomePage.debugSelectTab?.call(HomeTab.video);
    await tester.pump(const Duration(seconds: 2));
    final VideoDiscoveryActions actions =
        HomePage.debugVideoDiscoveryActions!.call();
    expect(actions.onAiAcquire, isNotNull, reason: '入口应已接线');
    actions.onAiAcquire!.call();
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(AiVideoAcquisitionPage).evaluate().isNotEmpty) break;
    }
    expect(find.byType(AiVideoAcquisitionPage), findsOneWidget);
    await captureFlutterFrame(tester, '01-ai-acquire-open');

    await tester.enterText(
      find.byKey(const ValueKey<String>('ai-video-acquire-input')),
      '葬送のフリーレン',
    );
    // 合成 Enter 键不会触发 TextField.onSubmitted（那是 IME 动作，不是按键），
    // 走测试输入通道的 send 动作——与用户按回车 / 点发送同一条路径。
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump(const Duration(milliseconds: 250));
    // AI 连接失败 + 真 MAL 搜索 + 详情：给足网络时间，等到第一个问题或失败出现。
    final AiVideoAcquisitionPage page = tester.widget(
      find.byType(AiVideoAcquisitionPage),
    );
    for (int i = 0; i < 240; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final VideoAcquisitionState state = page.service.state;
      if (state.question != null ||
          state.stage == VideoAcquisitionStage.idle && i > 4 ||
          state.stage == VideoAcquisitionStage.awaitingResourceConfirm) {
        break;
      }
    }
    debugPrint(
      '[ai-acquire-probe] stage=${page.service.state.stage.name} '
      'question=${page.service.state.question?.slot.name} '
      'transcript=${page.service.state.transcript.whereType<VideoAcquisitionAssistantMessage>().map((VideoAcquisitionAssistantMessage m) => m.say.kind.name).join(",")}',
    );
    await captureFlutterFrame(tester, '02-after-first-utterance');

    // 逐个问题用焦点驱动点第一个 chip（Tab 到 ActionChip → Enter），最多 6 轮。
    final FocusDriver driver = FocusDriver(tester);
    for (int round = 0; round < 6; round++) {
      final VideoAcquisitionQuestion? question = page.service.state.question;
      if (question == null ||
          page.service.state.stage ==
              VideoAcquisitionStage.awaitingResourceConfirm) {
        break;
      }
      final int index = question.preselectedIndex ?? 0;
      final String optionId = question.options[index].id;
      final Key chipKey = ValueKey<String>(
        'ai-video-acquire-option-${question.slot.name}-$optionId',
      );
      final bool reached = await driver.focusUntil(() {
        final BuildContext? ctx = driver.focused?.context;
        if (ctx == null) return false;
        return ctx.findAncestorWidgetOfExactType<ActionChip>()?.key == chipKey;
      }, maxSteps: 60);
      debugPrint(
        '[ai-acquire-probe] round $round slot=${question.slot.name} '
        'option=$optionId reached=$reached',
      );
      if (!reached) break;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final VideoAcquisitionState state = page.service.state;
        if (!state.busy &&
            (state.question != question ||
                state.stage == VideoAcquisitionStage.awaitingResourceConfirm)) {
          break;
        }
      }
      await captureFlutterFrame(
          tester, '0${3 + round}-after-${question.slot.name}');
    }
    final VideoAcquisitionState finalState = page.service.state;
    debugPrint(
      '[ai-acquire-probe] final stage=${finalState.stage.name} '
      'question=${finalState.question?.slot.name} '
      'plan=${finalState.plan?.picks.length} '
      'eligible=${finalState.eligibleGroups.length} '
      'transcript=${finalState.transcript.whereType<VideoAcquisitionAssistantMessage>().map((VideoAcquisitionAssistantMessage m) => m.say.kind.name).join(",")}',
    );
    await captureFlutterFrame(tester, '09-final');
    expect(
      finalState.transcript.whereType<VideoAcquisitionAssistantMessage>().map(
            (VideoAcquisitionAssistantMessage m) => m.say.kind,
          ),
      contains(VideoAcquisitionSayKind.aiUnavailable),
      reason: 'AI 连不上时必须走退化路径而不是卡住',
    );
  });
}
