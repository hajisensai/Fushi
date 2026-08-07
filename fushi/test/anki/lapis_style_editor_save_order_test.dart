// PR#574 复核必修 1：可视化编辑器保存时把用户写在托管区段**之后**的 CSS 搬到
// 了前面。托管区段整块 `!important`（必须压过 Lapis 自己的 `#lapis[...]` 高特异性
// 规则），所以位置一换，用户刻意写的覆盖就被静默推翻——UI 上没有任何提示。
//
// 这条测试走真实页面：装载既有 CSS → 改一个可视参数 → 点保存 → 断言弹回的
// 字符串里用户那段 CSS 仍然排在托管区段之后。纯函数层的对应守卫在
// packages/fushi_anki/test/lapis_styling_test.dart。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/lapis_style_editor_page.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'lapis_style_editor_harness.dart';

const String _userOverride = '.main-def {\n'
    '  background-color: #101010 !important;\n'
    '}';

Future<String?> _openEditorAndSave(
  WidgetTester tester, {
  required String initialCustomCss,
}) async {
  final LapisVisualEditorResult? result = await openEditorAndSave(
    tester,
    initialCustomCss: initialCustomCss,
  );
  return result?.customCss;
}

void main() {
  testWidgets('保存不把托管区段之后的用户 CSS 搬到前面', (WidgetTester tester) async {
    useWideWindow(tester);

    final String managedOnly = composeLapisVisualStyleSheet(
      freeformCss: '',
      rules: const <LapisVisualField, LapisVisualRule>{
        LapisVisualField.definitionBox:
            LapisVisualRule(backgroundColorHex: '#FFF0A6'),
      },
    );
    final String? saved = await _openEditorAndSave(
      tester,
      initialCustomCss: '$managedOnly\n\n$_userOverride',
    );

    expect(saved, isNotNull);
    expect(saved, contains(_userOverride));
    expect(
      saved!.indexOf(lapisVisualCssEndMarker),
      lessThan(saved.indexOf(_userOverride)),
      reason: '用户写在托管区段之后的覆盖被搬到了前面，会被 !important 静默推翻',
    );
  });

  testWidgets('保存保留托管区段之前的用户 CSS 位置', (WidgetTester tester) async {
    useWideWindow(tester);

    const String freeform = '.custom { line-height: 1.8; }';
    final String stored = composeLapisVisualStyleSheet(
      freeformCss: freeform,
      rules: const <LapisVisualField, LapisVisualRule>{
        LapisVisualField.definitionBox:
            LapisVisualRule(backgroundColorHex: '#FFF0A6'),
      },
    );
    final String? saved =
        await _openEditorAndSave(tester, initialCustomCss: stored);

    expect(saved, isNotNull);
    expect(saved, startsWith(freeform));
    expect(
      saved!.indexOf(freeform),
      lessThan(saved.indexOf(lapisVisualCssBeginMarker)),
    );
  });
}
