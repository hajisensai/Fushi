// 可视化编辑器 widget 测试的共用装载器：把页面推进真实 Navigator、执行一段
// 交互、再点保存，返回弹回的 [LapisVisualEditorResult]。
//
// 页面在 >=820 宽时走左右分栏、控件列固定 340——窄屏 Column 布局会溢出，所以
// 用例统一先放大逻辑窗口（[useWideWindow]），再用 addTearDown 还原，不泄漏给
// 同进程其它测试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/lapis_style_editor_page.dart';
import 'package:fushi_anki/fushi_anki.dart';

void useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 默认交互：改一个可视参数（加粗），让保存按钮从 disabled 变成可点。
///
/// 先 ensureVisible：控件列是个滚动区，展开「自定义区域」之类的折叠块会把粗体
/// 开关挤出视口，直接 tap 会静默 miss（不报错，只是什么都没发生）。
Future<void> toggleBold(WidgetTester tester) async {
  final Finder bold = find.byType(SwitchListTile).first;
  await tester.ensureVisible(bold);
  await tester.pumpAndSettle();
  await tester.tap(bold);
  await tester.pumpAndSettle();
}

/// [pumpEditor] 的句柄：[popped] 在页面被 pop 后完成。
class EditorSession {
  const EditorSession(this.popped);

  final Future<void> popped;
}

/// 只装载页面、不保存：给几何/布局类用例用（它们不需要弹回结果，也不该被
/// 「保存按钮此刻是否可点」绑架）。
Future<EditorSession> pumpEditor(
  WidgetTester tester, {
  required String initialCustomCss,
  List<String> noteTypeFields = const <String>[],
  Map<String, String> initialFieldMappings = const <String, String>{},
  List<LapisCustomBlock> initialBlocks = const <LapisCustomBlock>[],
  LapisHandlebarPicker? pickHandlebar,
  void Function(LapisVisualEditorResult? result)? onResult,
}) async {
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
        initialBlocks: initialBlocks,
        pickHandlebar: pickHandlebar,
        previewBuilder: (_, __, ___) => const SizedBox.expand(),
      ),
    ),
  )
      .then((LapisVisualEditorResult? value) {
    onResult?.call(value);
  });
  await tester.pumpAndSettle();
  return EditorSession(pushed);
}

Future<LapisVisualEditorResult?> openEditorAndSave(
  WidgetTester tester, {
  required String initialCustomCss,
  List<String> noteTypeFields = const <String>[],
  Map<String, String> initialFieldMappings = const <String, String>{},
  List<LapisCustomBlock> initialBlocks = const <LapisCustomBlock>[],
  LapisHandlebarPicker? pickHandlebar,
  Future<void> Function(WidgetTester tester)? interact,
}) async {
  LapisVisualEditorResult? result;
  final EditorSession session = await pumpEditor(
    tester,
    initialCustomCss: initialCustomCss,
    noteTypeFields: noteTypeFields,
    initialFieldMappings: initialFieldMappings,
    initialBlocks: initialBlocks,
    pickHandlebar: pickHandlebar,
    onResult: (LapisVisualEditorResult? value) => result = value,
  );

  await (interact ?? toggleBold)(tester);

  await tester.tap(find.byIcon(Icons.save_outlined));
  await tester.pumpAndSettle();
  await session.popped;
  return result;
}
