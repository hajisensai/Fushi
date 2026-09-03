import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';
import 'package:fushi/src/pages/implementations/dict_style_preview.dart';
import 'package:integration_test/integration_test.dart';

/// BUG-1918 端到端验证：JS 调一个 Dart 侧**没注册**的 handler 名不再打死进程，
/// 且真实的「词典样式 → 可视化」预览能跑完 popup.js 而不闪退。
///
/// 为什么必须端到端：崩点在 C++（`flutter_inappwebview_windows` 的
/// `CallJsHandlerCallback::decodeResult` 把 Dart 的 null 答复当非空指针解引用），
/// `flutter test` 根本加载不到那段代码；崩溃又是**进程级** 0xC0000005，Dart 侧
/// 连异常都收不到。唯一能回答「还崩不崩」的只有真 WebView2 + 真插件。
///
/// 两个用例是一对：
///   ① 最小复现——裸 WebView、一个 handler 都不注册，JS 调一个不存在的名字。
///      修前：答复回到平台线程那一刻整个进程消失。修后：promise 正常 resolve 成
///      null，进程活着（用「之后还能再跑一次 JS」来证明活着，而不是靠没抛异常）。
///   ② 真实入口——直接挂生产的 [DictStylePreview]，等真 popup.js 渲染出词条，
///      再触发它的全局错误上报（`reportJsError`，正是原先漏注册的名字之一）。
///
/// 跑法（仓库 fushi/ 下，离屏、不抢焦点、隔离 WebView2 profile）：
///   .\tool\run_windows_itest.ps1 integration_test\dict_style_preview_null_reply_crash_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 轮询读一个**同步**的 window 变量。不能直接 return promise：
  /// `evaluateJavascript` 不 await Promise，拿到的只是序列化后的 `{}`。
  Future<String> pollProbe(
    WidgetTester tester,
    InAppWebViewController controller,
    String variable, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      final Object? value =
          await controller.evaluateJavascript(source: 'String($variable)');
      final String text = value?.toString() ?? 'null';
      if (text != 'pending' && text != 'null' && text != 'undefined') {
        return text;
      }
    }
    return 'timeout';
  }

  testWidgets('调用未注册的 JS handler 不再打死进程（BUG-1918 最小复现）',
      (WidgetTester tester) async {
    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InAppWebView(
            initialData: InAppWebViewInitialData(
              data: '<!DOCTYPE html><html><head><meta charset="utf-8">'
                  '</head><body>bug1918</body></html>',
            ),
            // 故意一个 addJavaScriptHandler 都不注册：插件的 Dart 侧
            // `_handleMethod` 查不到名字就走末尾 `return null`，于是原生侧收到
            // 的是无参 `Success()` → value == nullptr，正是崩溃入口。
            onLoadStop: (InAppWebViewController controller, _) {
              if (!ready.isCompleted) ready.complete(controller);
            },
          ),
        ),
      ),
    );

    final InAppWebViewController controller =
        await ready.future.timeout(const Duration(seconds: 60));
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    await controller.evaluateJavascript(source: '''
      window.__fushiCrashProbe = 'pending';
      window.flutter_inappwebview
        .callHandler('bug1918_definitely_not_registered', 1, 2)
        .then(function (v) {
          window.__fushiCrashProbe = 'resolved:' + JSON.stringify(v);
        })
        .catch(function (e) {
          window.__fushiCrashProbe = 'rejected:' + e;
        });
    ''');

    final String probe =
        await pollProbe(tester, controller, 'window.__fushiCrashProbe');
    // 修前这里根本走不到——答复到达平台线程即 0xC0000005，测试进程一起没。
    expect(probe, 'resolved:null',
        reason: '未注册的 handler 应当让 JS 侧 promise 正常 resolve 成 null');

    // 「进程还活着」得由一次**新的**往返来证明，而不是靠上一句没抛异常。
    final Object? alive = await controller.evaluateJavascript(source: '1 + 1');
    expect(alive.toString(), '2');
  });

  testWidgets('真 DictStylePreview 跑完 popup.js 且 reportJsError 不闪退',
      (WidgetTester tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    DictStylePreviewDebug.lastController = null;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 500,
            child: DictStylePreview(
              css: '.expression { color: rgb(1, 2, 3) !important; }',
              highlightPart: DictStylePart.expression,
              onPickPart: (DictStylePart _) {},
            ),
          ),
        ),
      ),
    );

    // 冷启动 WebView2 + 载入内联 popup.html + 手动 renderPopup()。
    InAppWebViewController? controller;
    for (int i = 0; i < 240 && controller == null; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      // ignore: invalid_use_of_visible_for_testing_member
      controller = DictStylePreviewDebug.lastController;
    }
    expect(controller, isNotNull, reason: '预览的 WebView 没被创建出来');

    // ① 真 popup.js 真的渲染出了样例词条（不是白屏）。这一步能为真，说明
    //    favoriteCheck / duplicateCheck / popupRendered / resolveWordAudio
    //    这些渲染期就会发的桥调用全都往返过了。
    String entryCount = '0';
    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final Object? value = await controller!.evaluateJavascript(
        source: 'String(document.querySelectorAll(".entry").length)',
      );
      entryCount = value?.toString() ?? '0';
      if (entryCount != '0' && entryCount != 'null') break;
    }
    expect(int.tryParse(entryCount) ?? 0, greaterThan(0),
        reason: '预览应渲染出样例词条；0 说明 popup.js 中途挂了');

    // ② 触发全局错误上报 —— `reportJsError` 正是修前漏注册、一调即崩的那个名字。
    await controller!.evaluateJavascript(source: '''
      window.__fushiStyleProbe = 'pending';
      window.__fushiReportJsError('bug1918-itest', 'probe', '');
      window.__fushiStyleProbe = 'sent';
    ''');
    final String sent =
        await pollProbe(tester, controller, 'window.__fushiStyleProbe');
    expect(sent, 'sent');

    // 答复要走完平台线程那一趟才谈得上「没崩」，多等几拍再做一次新的往返。
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final Object? alive = await controller.evaluateJavascript(source: '2 + 3');
    expect(alive.toString(), '5', reason: '上报之后进程必须还活着');
    expect(tester.takeException(), isNull);
  });
}
