import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ocr/screen_text_capture.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/pages/implementations/ai_agent_screen_text.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:material_ui/material_ui.dart';

/// AI 输入栏「附上屏幕文字」（spec §6.4）：截屏 → OCR → 全文，作为下一句的上下文
/// （`extra['screenText']`），输入栏上方一颗可删 chip；截图期间 AI 面板所在的弹层
/// 路由整层 offstage。
class _FakeOcr implements SystemOcrPlatform {
  _FakeOcr({this.lines = const <String>[], this.error});

  final List<String> lines;
  final Exception? error;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SystemOcrPageResult> recognize(
    Uint8List imageBytes, {
    required String language,
    List<Rect> tiles = const <Rect>[],
  }) async {
    final Exception? e = error;
    if (e != null) throw e;
    return SystemOcrPageResult(
      lines: <SystemOcrTextLine>[
        for (final String text in lines)
          SystemOcrTextLine(text: text, rect: Rect.zero, isVertical: false),
      ],
      imageWidth: 10,
      imageHeight: 10,
    );
  }
}

final Uint8List _png = Uint8List.fromList(<int>[1, 2, 3]);

/// 1×1 透明 PNG：chip 缩略图要能真解码。
final Uint8List _realPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  group('captureScreenText（截屏 → OCR → 全文）', () {
    test('按行拼成全文，去掉空行', () async {
      final ScreenTextCaptureResult result = await captureScreenText(
        capture: () async => _png,
        ocr: _FakeOcr(lines: <String>[' 第一行 ', '', '第二行']),
      );
      expect(result.status, ScreenTextCaptureStatus.ok);
      expect(result.text, '第一行\n第二行');
    });

    test('超长截到上限', () async {
      final ScreenTextCaptureResult result = await captureScreenText(
        capture: () async => _png,
        ocr: _FakeOcr(lines: <String>['あ' * 5000]),
      );
      expect(result.text.length, kScreenTextMaxChars);
    });

    test('不把代理对劈成半个', () {
      final String text = screenTextFromOcrLines(<SystemOcrTextLine>[
        const SystemOcrTextLine(
          text: 'ab😀',
          rect: Rect.zero,
          isVertical: false,
        ),
      ], maxChars: 3);
      expect(text, 'ab');
    });

    test('截不到图 = failed；没识别出字 = empty', () async {
      expect(
        (await captureScreenText(
          capture: () async => null,
          ocr: _FakeOcr(lines: <String>['x']),
        )).status,
        ScreenTextCaptureStatus.failed,
      );
      expect(
        (await captureScreenText(
          capture: () async => _png,
          ocr: _FakeOcr(),
        )).status,
        ScreenTextCaptureStatus.empty,
      );
    });

    test('要图：截图缩过后随结果带回；不要图不带', () async {
      final ScreenTextCaptureResult withImage = await captureScreenText(
        keepImage: true,
        capture: () async => _png,
        shrink: (Uint8List png) async => Uint8List.fromList(<int>[9]),
        ocr: _FakeOcr(lines: <String>['字']),
      );
      expect(withImage.status, ScreenTextCaptureStatus.ok);
      expect(withImage.image, <int>[9]);

      final ScreenTextCaptureResult without = await captureScreenText(
        capture: () async => _png,
        ocr: _FakeOcr(lines: <String>['字']),
      );
      expect(without.image, isNull);
    });

    test('本平台没有系统 OCR：不识字，只带回截图', () async {
      final ScreenTextCaptureResult result = await captureScreenText(
        keepImage: true,
        recognize: false,
        capture: () async => _png,
        shrink: (Uint8List png) async => png,
        ocr: _FakeOcr(error: Exception('不该被调用')),
      );
      expect(result.status, ScreenTextCaptureStatus.unavailable);
      expect(result.image, _png);
    });

    test('OCR 没认出字时截图照样带回', () async {
      final ScreenTextCaptureResult result = await captureScreenText(
        keepImage: true,
        capture: () async => _png,
        shrink: (Uint8List png) async => png,
        ocr: _FakeOcr(),
      );
      expect(result.status, ScreenTextCaptureStatus.empty);
      expect(result.image, _png);
    });

    test('系统 OCR 不可用时带原因（模型没就绪要带用户去配模型）', () async {
      final ScreenTextCaptureResult result = await captureScreenText(
        capture: () async => _png,
        ocr: _FakeOcr(
          error: const SystemOcrUnavailableException(
            kSystemOcrModelUnavailableReason,
          ),
        ),
      );
      expect(result.status, ScreenTextCaptureStatus.unavailable);
      expect(result.reason, kSystemOcrModelUnavailableReason);
    });
  });

  group('上下文合并', () {
    test('有页面上下文：并进 extra，原字段保留', () {
      final AgentUiContext? merged = aiAgentContextWithScreenText(
        const AgentUiContext(
          scene: 'video',
          itemTitle: '作品',
          extra: <String, Object?>{'episode': 3},
        ),
        '屏幕上的字',
      );
      expect(merged!.scene, 'video');
      expect(merged.itemTitle, '作品');
      expect(merged.extra, <String, Object?>{
        'episode': 3,
        kAiAgentScreenTextKey: '屏幕上的字',
      });
    });

    test('没有页面上下文时起一份 general；没附文字时原样返回', () {
      final AgentUiContext? merged = aiAgentContextWithScreenText(null, '字');
      expect(merged!.scene, 'general');
      expect(merged.extra[kAiAgentScreenTextKey], '字');
      expect(aiAgentContextWithScreenText(null, null), isNull);
    });
  });

  group('按钮与 chip', () {
    Widget controls(AiAgentScreenTextAttachment attachment) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AiAgentScreenTextChip(attachment: attachment),
        AiAgentScreenTextButton(attachment: attachment),
      ],
    );

    testWidgets('点按钮 → chip 出现（N 字）→ take 后消失；删掉也消失', (
      WidgetTester tester,
    ) async {
      final AiAgentScreenTextAttachment attachment =
          AiAgentScreenTextAttachment(
            capture: ({bool keepImage = false, bool recognize = true}) async =>
                const ScreenTextCaptureResult(
                  ScreenTextCaptureStatus.ok,
                  text: 'こんにちは',
                ),
          );
      addTearDown(attachment.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: controls(attachment))),
      );
      expect(find.byKey(kAiAgentScreenTextChipKey), findsNothing);

      await tester.tap(find.byKey(kAiAgentAttachScreenTextKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kAiAgentScreenTextChipKey), findsOneWidget);
      expect(find.text(t.ai_agent_screen_text_chip(n: '5')), findsOneWidget);

      // 发送：文字只跟这一句走，取走即清。
      expect(attachment.take().text, 'こんにちは');
      await tester.pumpAndSettle();
      expect(find.byKey(kAiAgentScreenTextChipKey), findsNothing);
      expect(attachment.take().text, isNull);

      // 再附一次，点 chip 的删除。
      await tester.tap(find.byKey(kAiAgentAttachScreenTextKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kAiAgentScreenTextChipKey), findsOneWidget);
      attachment.clear();
      await tester.pumpAndSettle();
      expect(find.byKey(kAiAgentScreenTextChipKey), findsNothing);
    });

    testWidgets('截图期间 AI 面板所在的弹层整层 offstage，截完恢复', (WidgetTester tester) async {
      ModalRoute<Object?>? panelRoute;
      bool? offstageDuringCapture;
      final AiAgentScreenTextAttachment attachment =
          AiAgentScreenTextAttachment(
            capture: ({bool keepImage = false, bool recognize = true}) async {
              offstageDuringCapture = panelRoute?.offstage;
              return const ScreenTextCaptureResult(
                ScreenTextCaptureStatus.ok,
                text: '下面那页的字',
              );
            },
          );
      addTearDown(attachment.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showGeneralDialog<void>(
                    context: context,
                    pageBuilder:
                        (
                          BuildContext dialogContext,
                          Animation<double> _,
                          Animation<double> __,
                        ) {
                          panelRoute = ModalRoute.of(dialogContext);
                          return Material(child: controls(attachment));
                        },
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(panelRoute, isA<PopupRoute<Object?>>());

      await tester.tap(find.byKey(kAiAgentAttachScreenTextKey));
      await tester.pumpAndSettle();
      expect(offstageDuringCapture, isTrue, reason: '截图时 AI 面板不能在画面里');
      expect(panelRoute!.offstage, isFalse, reason: '截完要把面板放回来');
      expect(find.byKey(kAiAgentScreenTextChipKey), findsOneWidget);
    });

    testWidgets('模型能收图：截图另起一颗 chip，可单独删；发送时一起取走', (WidgetTester tester) async {
      bool? askedForImage;
      final AiAgentScreenTextAttachment attachment =
          AiAgentScreenTextAttachment(
            capture: ({bool keepImage = false, bool recognize = true}) async {
              askedForImage = keepImage;
              return ScreenTextCaptureResult(
                ScreenTextCaptureStatus.ok,
                text: '台词',
                image: _realPng,
              );
            },
          );
      addTearDown(attachment.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AiAgentScreenTextChip(attachment: attachment),
                AiAgentScreenTextButton(
                  attachment: attachment,
                  keepImage: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(kAiAgentAttachScreenTextKey));
      await tester.pumpAndSettle();
      expect(askedForImage, isTrue);
      expect(find.byKey(kAiAgentScreenImageChipKey), findsOneWidget);
      expect(find.byKey(kAiAgentScreenTextChipKey), findsOneWidget);

      attachment.clearImage();
      await tester.pumpAndSettle();
      expect(find.byKey(kAiAgentScreenImageChipKey), findsNothing);
      expect(find.byKey(kAiAgentScreenTextChipKey), findsOneWidget);

      await tester.tap(find.byKey(kAiAgentAttachScreenTextKey));
      await tester.pumpAndSettle();
      final AiAgentScreenAttachments taken = attachment.take();
      expect(taken.text, '台词');
      expect(taken.image, _realPng);
      expect(aiAgentImagesFor(taken.image), hasLength(1));
      expect(aiAgentImagesFor(null), isEmpty);
    });

    testWidgets('模型不能收图：只附文字，截图不留', (WidgetTester tester) async {
      final AiAgentScreenTextAttachment attachment =
          AiAgentScreenTextAttachment(
            capture: ({bool keepImage = false, bool recognize = true}) async =>
                ScreenTextCaptureResult(
                  ScreenTextCaptureStatus.ok,
                  text: '台词',
                  image: keepImage ? _realPng : null,
                ),
          );
      addTearDown(attachment.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: controls(attachment))),
      );
      await tester.tap(find.byKey(kAiAgentAttachScreenTextKey));
      await tester.pumpAndSettle();
      expect(attachment.image, isNull);
      expect(find.byKey(kAiAgentScreenImageChipKey), findsNothing);
    });

    testWidgets('点文字 chip 能手改：改了就用改后的，清空等于不附', (WidgetTester tester) async {
      final AiAgentScreenTextAttachment attachment =
          AiAgentScreenTextAttachment(
            capture: ({bool keepImage = false, bool recognize = true}) async =>
                const ScreenTextCaptureResult(
                  ScreenTextCaptureStatus.ok,
                  text: '撹乱さ才ている',
                ),
          );
      addTearDown(attachment.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: controls(attachment))),
      );
      await tester.tap(find.byKey(kAiAgentAttachScreenTextKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAiAgentScreenTextChipKey));
      await tester.pumpAndSettle();
      expect(find.text(t.ai_agent_screen_text_edit_title), findsWidgets);
      await tester.enterText(find.byType(EditableText).last, '  撹乱されている  ');
      await tester.tap(find.text(t.dialog_ok).last);
      await tester.pumpAndSettle();
      expect(attachment.text, '撹乱されている');
      expect(find.text(t.ai_agent_screen_text_chip(n: '7')), findsOneWidget);

      attachment.editText('   ');
      await tester.pumpAndSettle();
      expect(attachment.text, isNull);
      expect(find.byKey(kAiAgentScreenTextChipKey), findsNothing);
    });
  });
}
