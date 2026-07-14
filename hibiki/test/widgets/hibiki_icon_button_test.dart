import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiIconButton', () {
    testWidgets('renders icon and tooltip via Semantics', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiIconButton(
          icon: Icons.play_arrow,
          tooltip: 'Play',
        ),
      ));

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
    });

    testWidgets('calls onTap when enabled and tapped', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.add,
          tooltip: 'Add',
          onTap: () => tapped = true,
        ),
      ));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('disabled button does not fire onTap', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.delete,
          tooltip: 'Delete',
          enabled: false,
          onTap: () => tapped = true,
        ),
      ));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tapped, isFalse);
    });

    testWidgets('busy mode disables during async onTap', (tester) async {
      final completer = Completer<void>();
      int tapCount = 0;

      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.sync,
          tooltip: 'Sync',
          busy: true,
          onTap: () async {
            tapCount++;
            await completer.future;
          },
        ),
      ));

      await tester.tap(find.byType(InkWell));
      await tester.pump();

      // Second tap should be ignored (busy)
      await tester.tap(find.byType(InkWell));
      await tester.pump();

      expect(tapCount, 1);

      completer.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('isWideTapArea uses IconButton instead of InkWell',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiIconButton(
          icon: Icons.settings,
          tooltip: 'Settings',
          isWideTapArea: true,
        ),
      ));

      expect(find.byType(IconButton), findsOneWidget);
    });

    // BUG-807：纯图标按钮（如批量操作栏）以前只把 tooltip 喂给 Semantics，屏幕上
    // 悬停不弹说明。现用 Material [Tooltip] 包裹，鼠标悬停 / 长按可见用途。
    testWidgets('plain icon button wraps in a Material Tooltip',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.playlist_add,
          tooltip: 'Combine',
          onTap: () {},
        ),
      ));

      final Tooltip tip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tip.message, 'Combine');
    });

    testWidgets('wide tap area icon button also wraps in a Material Tooltip',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiIconButton(
          icon: Icons.settings,
          tooltip: 'Settings',
          isWideTapArea: true,
        ),
      ));

      final Tooltip tip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tip.message, 'Settings');
    });

    testWidgets('empty tooltip adds no Tooltip wrapper (no empty hover box)',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.add,
          tooltip: '',
          onTap: () {},
        ),
      ));

      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('registers with the focus root and activates on Enter',
        (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: HibikiIconButton(
            focusId: const HibikiFocusId('play-button'),
            icon: Icons.play_arrow,
            tooltip: 'Play',
            onTap: () => tapped = true,
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController root = HibikiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.play_arrow)),
      );
      expect(root.requestById(const HibikiFocusId('play-button')), isTrue);
      await tester.pump();
      expect(root.activeId, const HibikiFocusId('play-button'));

      Actions.maybeInvoke<ActivateIntent>(
        root.activeContext!,
        const ActivateIntent(),
      );
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });
}
