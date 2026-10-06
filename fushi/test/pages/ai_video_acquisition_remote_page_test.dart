import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_view.dart';
import 'package:fushi/src/pages/implementations/ai_video_acquisition_page.dart';
import '../helpers/glass_unwrap.dart';

/// 对话页只认 [VideoAcquisitionSession]：远端代办时标题下写「在 <设备> 上执行」、
/// 版本 chip 用过线的标签、「以后默认」勾选不被每次更新的新对象冲掉、断线失败
/// 翻成人话。不挂 ProviderScope。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget harness(_FakeSession session) => TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          home: AiVideoAcquisitionPage(service: session, executorLabel: 'PC'),
        ),
      );

  testWidgets('标题下显示执行设备；版本 chip 用视图里的标签；点选原样发给会话', (
    WidgetTester tester,
  ) async {
    final _FakeSession session = _FakeSession(_resourceQuestion());
    addTearDown(session.dispose);
    await tester.pumpWidget(harness(session));

    expect(
      find.byKey(const ValueKey<String>('ai-video-acquire-remote-executor')),
      findsOneWidget,
    );
    expect(find.text('在 PC 上执行'), findsOneWidget);
    expect(find.text('Group · 1080p · 1.2 GiB'), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('ai-video-acquire-option-resource-confirm'),
      ),
    );
    await tester.pump();
    expect(session.actions, <String>['choose:resource:confirm:null']);
  });

  // BUG-2958：候选 chip 曾只有「组 · 分辨率 · 片源 · 体积」，比不出差别。
  testWidgets('BUG-2958 候选版本 chip 与当前版本卡同口径：站点 · 集数 / 合集 · 做种 · 编码', (
    WidgetTester tester,
  ) async {
    final _FakeSession session = _FakeSession(
      _resourceQuestion(
        altArgs: const <String, Object?>{
          'releaseGroup': 'Erai-raws',
          'resolution': '1080p',
          'source': 'WEB-DL',
          'traits': 'HEVC 10bit',
          'provider': 'nyaa',
          'count': 12,
          'batch': false,
          'seeders': 30,
          'bytesPerEpisode': 1024 * 1024 * 1024,
        },
      ),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(harness(session));

    expect(
      find.text(
        'Erai-raws · 1080p · WEB-DL · HEVC 10bit · nyaa · 12 集 · 做种 30'
        ' · 每集约 1.0 GiB',
      ),
      findsOneWidget,
    );
    // 有 args 时不再用旧的字面量标签。
    expect(find.text('Group · 1080p · 1.2 GiB'), findsNothing);
  });

  testWidgets('BUG-2958 合集版本 chip 写「整季合集」而不是集数', (WidgetTester tester) async {
    final _FakeSession session = _FakeSession(
      _resourceQuestion(
        altArgs: const <String, Object?>{
          'releaseGroup': 'Judas',
          'resolution': '1080p',
          'provider': 'nyaa',
          'count': 1,
          'batch': true,
          'seeders': 74,
        },
      ),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(harness(session));

    expect(find.text('Judas · 1080p · nyaa · 整季合集 · 做种 74'), findsOneWidget);
  });

  testWidgets('远端每次推来新对象时「以后默认」的勾选不被重置', (WidgetTester tester) async {
    final _FakeSession session = _FakeSession(_qualityQuestion());
    addTearDown(session.dispose);
    await tester.pumpWidget(harness(session));

    Checkbox remember() => tester.widget<Checkbox>(
          glassUnwrap<Checkbox>(
            find.byKey(const ValueKey<String>('ai-video-acquire-remember')),
          ),
        );
    expect(remember().value, isTrue);
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-video-acquire-remember')),
    );
    await tester.pump();
    expect(remember().value, isFalse);

    // 同一个问题、新解码出来的对象（远端长轮询的常态）。
    session.push(_qualityQuestion());
    await tester.pump();
    expect(remember().value, isFalse, reason: '按对象身份比会把用户刚改的勾选冲掉');

    await tester.tap(
      find.byKey(
        const ValueKey<String>('ai-video-acquire-option-quality-720p'),
      ),
    );
    await tester.pump();
    expect(session.actions, <String>['choose:quality:720p:false']);
  });

  testWidgets('连接中断的失败提示翻成人话，且远端不给「去配置下载后端」按钮', (WidgetTester tester) async {
    final _FakeSession session = _FakeSession(const VideoAcquisitionView());
    addTearDown(session.dispose);
    await tester.pumpWidget(harness(session));

    session.push(
      const VideoAcquisitionView(
        transcript: <VideoAcquisitionMessage>[
          VideoAcquisitionUserMessage('Show'),
          VideoAcquisitionAssistantMessage(
            VideoAcquisitionSay(
              VideoAcquisitionSayKind.failed,
              args: <String, Object?>{
                'message': kVideoAcquisitionFailureRemoteUnavailable,
              },
            ),
          ),
        ],
        failureHint: VideoAcquisitionFailureHint.configureBackend,
      ),
    );
    await tester.pump();

    final String expected = t.ai_video_acquire_failed(
      message: t.ai_video_acquire_failure_remote_unavailable,
    );
    expect(find.text(expected), findsWidgets);
    expect(find.byType(SnackBarAction), findsNothing);
  });
}

/// [altArgs] 为空 = 旧 host（选项不带 args，chip 退回 [alternativeLabels]）。
VideoAcquisitionView _resourceQuestion({
  Map<String, Object?> altArgs = const <String, Object?>{},
}) {
  final VideoAcquisitionQuestion question = VideoAcquisitionQuestion(
    slot: VideoAcquisitionSlot.resource,
    options: <VideoAcquisitionOption>[
      const VideoAcquisitionOption(id: kVideoAcquisitionOptionConfirm),
      VideoAcquisitionOption(
        id: '${kVideoAcquisitionOptionAltPrefix}0',
        args: altArgs,
      ),
    ],
  );
  return VideoAcquisitionView(
    stage: VideoAcquisitionStage.awaitingResourceConfirm,
    transcript: <VideoAcquisitionMessage>[
      const VideoAcquisitionUserMessage('下 Show'),
      VideoAcquisitionAssistantMessage(
        const VideoAcquisitionSay(VideoAcquisitionSayKind.question),
        question: question,
      ),
    ],
    question: question,
    alternativeLabels: const <String>['Group · 1080p · 1.2 GiB'],
  );
}

VideoAcquisitionView _qualityQuestion() => const VideoAcquisitionView(
      stage: VideoAcquisitionStage.collectingSlots,
      transcript: <VideoAcquisitionMessage>[
        VideoAcquisitionUserMessage('Show'),
        VideoAcquisitionAssistantMessage(
          VideoAcquisitionSay(VideoAcquisitionSayKind.question),
          question: VideoAcquisitionQuestion(
            slot: VideoAcquisitionSlot.quality,
            rememberToggle: true,
            options: <VideoAcquisitionOption>[
              VideoAcquisitionOption(id: '1080p'),
              VideoAcquisitionOption(id: '720p'),
            ],
          ),
        ),
      ],
      question: VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.quality,
        rememberToggle: true,
        options: <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: '1080p'),
          VideoAcquisitionOption(id: '720p'),
        ],
      ),
    );

class _FakeSession implements VideoAcquisitionSession {
  _FakeSession(this._view);

  VideoAcquisitionView _view;
  final StreamController<VideoAcquisitionView> _views =
      StreamController<VideoAcquisitionView>.broadcast();
  final List<String> actions = <String>[];

  void push(VideoAcquisitionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  VideoAcquisitionView get view => _view;

  @override
  Stream<VideoAcquisitionView> get views => _views.stream;

  @override
  Future<void> submitText(String text) async => actions.add('text:$text');

  @override
  Future<void> choose(
    VideoAcquisitionSlot slot,
    String optionId, {
    bool? remember,
  }) async =>
      actions.add('choose:${slot.name}:$optionId:$remember');

  @override
  Future<void> confirm() async => actions.add('confirm');

  @override
  Future<void> cancel() async => actions.add('cancel');

  @override
  Future<void> restart() async => actions.add('restart');

  @override
  Future<void> toggleFranchiseEntry(int index) async =>
      actions.add('toggle:$index');

  @override
  void dispose() {
    if (!_views.isClosed) _views.close();
  }
}
