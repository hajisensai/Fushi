import 'dart:async';

import 'package:material_ui/material_ui.dart';
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

  testWidgets('远端每次推来新对象时「以后默认」的勾选不被重置', (
    WidgetTester tester,
  ) async {
    final _FakeSession session = _FakeSession(_qualityQuestion());
    addTearDown(session.dispose);
    await tester.pumpWidget(harness(session));

    Checkbox remember() => tester.widget<Checkbox>(glassUnwrap<Checkbox>(find.byKey(const ValueKey<String>('ai-video-acquire-remember'))),);
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
          const ValueKey<String>('ai-video-acquire-option-quality-720p')),
    );
    await tester.pump();
    expect(session.actions, <String>['choose:quality:720p:false']);
  });

  testWidgets('连接中断的失败提示翻成人话，且远端不给「去配置下载后端」按钮', (
    WidgetTester tester,
  ) async {
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

VideoAcquisitionView _resourceQuestion() => const VideoAcquisitionView(
      stage: VideoAcquisitionStage.awaitingResourceConfirm,
      transcript: <VideoAcquisitionMessage>[
        VideoAcquisitionUserMessage('下 Show'),
        VideoAcquisitionAssistantMessage(
          VideoAcquisitionSay(VideoAcquisitionSayKind.question),
          question: VideoAcquisitionQuestion(
            slot: VideoAcquisitionSlot.resource,
            options: <VideoAcquisitionOption>[
              VideoAcquisitionOption(id: kVideoAcquisitionOptionConfirm),
              VideoAcquisitionOption(
                  id: '${kVideoAcquisitionOptionAltPrefix}0'),
            ],
          ),
        ),
      ],
      question: VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.resource,
        options: <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: kVideoAcquisitionOptionConfirm),
          VideoAcquisitionOption(id: '${kVideoAcquisitionOptionAltPrefix}0'),
        ],
      ),
      alternativeLabels: <String>['Group · 1080p · 1.2 GiB'],
    );

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
