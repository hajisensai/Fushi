import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_history_source_corpus.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// BUG-038：桌面端书架卡片只能长按才弹上下文菜单，PC 用户惯例是鼠标右键。
/// 根因 = `HibikiCard`/`_bookCardShell` 从不配线 secondary tap（右键），
/// 仅有 `onTap` / `onLongPress` / 手柄长按。
void main() {
  group('HibikiCard secondary tap (BUG-038 桌面右键上下文菜单)', () {
    testWidgets('右键触发 onSecondaryTap，且不误触 onTap', (WidgetTester tester) async {
      int taps = 0;
      int secondaryTaps = 0;
      int longPresses = 0;
      await tester.pumpWidget(MaterialApp(
        home: HibikiFocusRoot(
          child: Center(
            child: HibikiCard(
              focusId: const HibikiFocusId('book-card'),
              onTap: () => taps += 1,
              onLongPress: () => longPresses += 1,
              onSecondaryTap: () => secondaryTaps += 1,
              child: const SizedBox(width: 120, height: 160),
            ),
          ),
        ),
      ));
      await tester.pump();

      // 鼠标右键 = secondary button tap。
      await tester.tap(find.byType(HibikiCard), buttons: kSecondaryButton);
      await tester.pump();

      expect(secondaryTaps, 1, reason: '右键应触发上下文菜单回调');
      expect(taps, 0, reason: '右键不应误触主点击（打开书）');
      expect(longPresses, 0);
    });

    testWidgets('未提供 onSecondaryTap 时右键无副作用（向后兼容）',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: HibikiFocusRoot(
          child: Center(
            child: HibikiCard(
              focusId: const HibikiFocusId('plain-card'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 120, height: 160),
            ),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(HibikiCard), buttons: kSecondaryButton);
      await tester.pump();

      expect(taps, 0, reason: '右键不触发 onTap，且不抛异常');
    });
  });

  test('书架卡片外壳把 onSecondaryTap 配线到长按回调（源码守卫）', () {
    // TODO-587: reader_hibiki_history_page 拆成主壳 + reader_history/*.part.dart；
    // _bookCardShell 现落在 card_widgets.part.dart，故读合并语料。
    final String text = readReaderHistorySource();
    expect(
      text.contains('onSecondaryTap: _selectionMode ? null : onLongPress'),
      isTrue,
      reason: '_bookCardShell 必须把右键映射到与长按相同的上下文菜单回调，否则桌面右键回归无效',
    );
  });
}
