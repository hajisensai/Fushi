// 可视化编辑器 widget 测试的共用装载器：把页面推进真实 Navigator、执行一段
// 交互、再点保存，返回弹回的 [LapisVisualEditorResult]。
//
// 页面在 >=820 宽时走左右分栏、控件列固定 340——窄屏 Column 布局会溢出，所以
// 用例统一先放大逻辑窗口（[useWideWindow]），再用 addTearDown 还原，不泄漏给
// 同进程其它测试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/anki/lapis_style_editor_page.dart';

void useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 默认交互：改一个可视参数（加粗），让保存按钮从 disabled 变成可点。
Future<void> toggleBold(WidgetTester tester) async {
  await tester.tap(find.byType(SwitchListTile).first);
  await tester.pumpAndSettle();
}

Future<LapisVisualEditorResult?> openEditorAndSave(
  WidgetTester tester, {
  required String initialCustomCss,
  List<String> noteTypeFields = const <String>[],
  Map<String, String> initialFieldMappings = const <String, String>{},
  LapisHandlebarPicker? pickHandlebar,
  Future<void> Function(WidgetTester tester)? interact,
}) async {
  LapisVisualEditorResult? result;
  late BuildContext hostContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) {
          hostContext = context;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );

  final Future<void> pushed = Navigator.of(hostContext)
      .push<LapisVisualEditorResult>(
    MaterialPageRoute<LapisVisualEditorResult>(
      builder: (_) => LapisStyleEditorPage(
        initialCustomCss: initialCustomCss,
        fontScalePercent: 100,
        noteTypeFields: noteTypeFields,
        initialFieldMappings: initialFieldMappings,
        pickHandlebar: pickHandlebar,
        previewBuilder: (_, __, ___) => const SizedBox.expand(),
      ),
    ),
  )
      .then((LapisVisualEditorResult? value) {
    result = value;
  });
  await tester.pumpAndSettle();

  await (interact ?? toggleBold)(tester);

  await tester.tap(find.byIcon(Icons.save_outlined));
  await tester.pumpAndSettle();
  await pushed;
  return result;
}
