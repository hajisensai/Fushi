import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/sentence_context_dialog.dart';

/// BUG-2196 ②：「制卡前调整 · 选择句子上下文」里的试听按钮。
///
/// 用户诉求原文：「这里加个试听？有时候断句在很奇怪的地方，可能会漏词，制卡压没念」。
/// 也就是说这颗按钮要能回答的问题是「**这次制卡压出来的那段音频，念全了吗**」，
/// 而不是「这句话有没有音频」。所以下面的用例钉的是：
///   * 宿主不支持时整颗按钮不渲染（视频页等没有句级音频区间的表面）；
///   * 每次点都**重新问宿主要一次**区间（用户在这个对话框里加减上下文句的目的
///     就是改变那段区间，缓存会让试听放的是上一次的范围）；
///   * 宿主说「这句没音频」时如实提示，不留一个「像在放但没声音」的按钮；
///   * 关窗（取消 / 确认制卡）都必须停播——对话框没了之后用户没有任何入口能停。
void main() {
  late int previewCalls;
  late int stopCalls;
  late bool previewSucceeds;
  late int confirmCalls;

  Map<String, Object?> preview() => <String, Object?>{
        'prev': <String>[],
        'current': 'shepherds abiding in the field, keeping watch.',
        'currentOffset': 10,
        'next': <String>[],
        'total': 0,
      };

  Widget harness({required bool withPreview}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => SentenceContextDialog(
                  matched: 'abiding',
                  fetchPreview: () async => preview(),
                  setContext: (int p, int n) async => p + n,
                  onConfirm: () => confirmCalls++,
                  previewAudio: withPreview
                      ? () async {
                          previewCalls++;
                          return previewSucceeds;
                        }
                      : null,
                  stopAudioPreview: withPreview
                      ? () async {
                          stopCalls++;
                        }
                      : null,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    previewCalls = 0;
    stopCalls = 0;
    previewSucceeds = true;
    confirmCalls = 0;
  });

  Future<void> open(WidgetTester tester, {bool withPreview = true}) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness(withPreview: withPreview));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('宿主不支持试听时整颗按钮不渲染', (WidgetTester tester) async {
    await open(tester, withPreview: false);
    expect(find.text(t.popup_ctx_preview_audio), findsNothing);
    expect(find.text(t.popup_ctx_preview_stop), findsNothing);
  });

  testWidgets('宿主支持时显示试听按钮，点一下开始播并变成停止', (WidgetTester tester) async {
    await open(tester);
    expect(find.text(t.popup_ctx_preview_audio), findsOneWidget);
    await tester.tap(find.text(t.popup_ctx_preview_audio));
    await tester.pumpAndSettle();
    expect(previewCalls, 1);
    expect(find.text(t.popup_ctx_preview_stop), findsOneWidget,
        reason: '正在播时按钮必须变成「停止」，否则用户再点会以为是重放');
  });

  testWidgets('再点一下停止，并真的调到宿主的停播', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_preview_audio));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.popup_ctx_preview_stop));
    await tester.pumpAndSettle();
    expect(stopCalls, 1);
    expect(find.text(t.popup_ctx_preview_audio), findsOneWidget);
  });

  testWidgets('每次试听都重新问宿主要区间，不缓存', (WidgetTester tester) async {
    await open(tester);
    for (int i = 0; i < 3; i++) {
      await tester.tap(find.text(t.popup_ctx_preview_audio));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.popup_ctx_preview_stop));
      await tester.pumpAndSettle();
    }
    expect(previewCalls, 3, reason: '加减上下文句就是为了改变那段区间；缓存会让试听放上一次的范围');
  });

  testWidgets('这句没有可试听音频时按钮弹回，不停在「停止」态', (WidgetTester tester) async {
    previewSucceeds = false;
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_preview_audio));
    await tester.pumpAndSettle();
    expect(previewCalls, 1);
    expect(find.text(t.popup_ctx_preview_audio), findsOneWidget,
        reason: '没声音却停在「停止」态，用户会以为在播、只是听不见');
    expect(find.text(t.popup_ctx_preview_stop), findsNothing);
  });

  testWidgets('取消关窗时停播', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_preview_audio));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.popup_ctx_cancel));
    await tester.pumpAndSettle();
    expect(stopCalls, 1, reason: '对话框关了之后用户没有任何入口能停下这段音频');
  });

  testWidgets('确认制卡时也停播，且制卡照常发生', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_preview_audio));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.popup_ctx_confirm));
    await tester.pumpAndSettle();
    expect(stopCalls, 1);
    expect(confirmCalls, 1, reason: '停播不得挡住制卡');
  });

  testWidgets('没点过试听就关窗，不该去打扰宿主的播放器', (WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.text(t.popup_ctx_cancel));
    await tester.pumpAndSettle();
    expect(stopCalls, 0);
  });
}
