import 'dart:io';

import 'package:flutter/gestures.dart' show HitTestEntry, HitTestResult;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

// 嵌套查词「玻璃叠玻璃」：Skia 后端（Windows / Linux）下子层的 BackdropFilter 采到的
// 是父层那块 88% 面板，第二层变成 ≈ 纯色板（用户 2026-10-05 截图）。修法是把下层被
// 上层查词卡覆盖的部分裁掉（[PopupOccluderClip]），上层模糊才采到正文。
void main() {
  const Rect lower = Rect.fromLTWH(100, 100, 400, 400);
  const Rect upper = Rect.fromLTWH(200, 300, 400, 400);

  Widget host(TargetPlatform platform) => MaterialApp(
    theme: ThemeData(platform: platform),
    home: const Stack(
      children: <Widget>[
        Positioned.fill(child: ColoredBox(color: Colors.white)),
        Positioned(
          left: 100,
          top: 100,
          width: 400,
          height: 400,
          child: PopupOccluderClip(
            layerRect: lower,
            occluders: <Rect>[upper],
            child: SizedBox.expand(
              key: ValueKey<String>('lower'),
              child: ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ],
    ),
  );

  testWidgets('Windows：下层被上层覆盖的区域裁掉，命中也落不到下层', (WidgetTester tester) async {
    await tester.pumpWidget(host(TargetPlatform.windows));
    expect(find.byType(ClipPath), findsOneWidget);
    final Finder lowerBox = find.byKey(const ValueKey<String>('lower'));
    // 上层覆盖区内的点（Stack 坐标 (350, 400)）：下层不再命中。
    final HitTestResult covered = tester.hitTestOnBinding(
      const Offset(350, 400),
    );
    expect(
      covered.path.any(
        (HitTestEntry e) => e.target == tester.renderObject(lowerBox),
      ),
      isFalse,
    );
    // 未覆盖区（(150, 150)）照常命中下层。
    final HitTestResult open = tester.hitTestOnBinding(const Offset(150, 150));
    expect(
      open.path.any(
        (HitTestEntry e) => e.target == tester.renderObject(lowerBox),
      ),
      isTrue,
    );
  });

  testWidgets('iOS / macOS / Android 不裁（原生材质 / 不透明面板）', (
    WidgetTester tester,
  ) async {
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      await tester.pumpWidget(host(p));
      expect(find.byType(ClipPath), findsNothing, reason: '$p');
    }
  });

  test('所有查词浮层宿主都把更上层卡的位置作为 occluders 传给 parkedPopupLayer', () {
    for (final String path in <String>[
      'lib/src/pages/base_source_page.dart',
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src, contains('occluders: <Rect>['), reason: path);
      expect(src, contains('j = index + 1'), reason: path);
    }
  });
}
