import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';

/// BUG-1703 守卫：扩展加载失败这类诊断错误必须**全文**可见并且能复制走。
///
/// 事故形态：错误消息里唯一可操作的信息（链式根因的最深一层，指明宿主缺哪个类）
/// 在消息尾部，而移动端的 toast 是系统原生 Toast，硬上限 2 行 + 省略号截断，用户
/// 看到的只有开头的 `Unable to instantiate extension source …`。诊断信息送不出去，
/// 用户报不了障，也就没人能修。
void main() {
  /// 真实形状：长到原生 toast 一定会截断，且可操作信息全在尾部。
  const String longError =
      'MihonRuntimeException(LOAD_FAILED): Unable to instantiate extension '
      'source eu.kanade.tachiyomi.extension.all.ahottie.ExtensionGenerated: '
      'InvocationTargetException ← ExceptionInInitializerError ← '
      'NoClassDefFoundError: Failed resolution of: Lkotlin/LazyKt;';

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: TextButton(
            onPressed: () => showErrorDetails(
              context,
              title: '扩展错误',
              error: longError,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('错误全文原样呈现，不截断', (WidgetTester tester) async {
    await openDialog(tester);

    final SelectableText body = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(body.data, longError,
        reason: '呈现的必须是完整错误，任何截断都会把可操作的根因切掉');
    // maxLines 为空 = 不设行数上限；这正是原生 toast 做不到的那一点。
    expect(body.maxLines, isNull);
  });

  testWidgets('复制按钮把完整错误写进剪贴板', (WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await openDialog(tester);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, longError,
        reason: '用户要能把根因整段贴给开发者，少一个字符都可能是缺失的那个类名');
  });
}
