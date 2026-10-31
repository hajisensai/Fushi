import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';

import 'widget_test_helpers.dart';
import '../helpers/glass_unwrap.dart';

void main() {
  group('FushiIconButton', () {
    testWidgets('renders icon and tooltip via Semantics', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const FushiIconButton(icon: Icons.play_arrow, tooltip: 'Play'),
        ),
      );

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
    });

    testWidgets('calls onTap when enabled and tapped', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        buildTestApp(
          FushiIconButton(
            icon: Icons.add,
            tooltip: 'Add',
            onTap: () => tapped = true,
          ),
        ),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('disabled button does not fire onTap', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        buildTestApp(
          FushiIconButton(
            icon: Icons.delete,
            tooltip: 'Delete',
            enabled: false,
            onTap: () => tapped = true,
          ),
        ),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tapped, isFalse);
    });

    testWidgets('busy mode disables during async onTap', (tester) async {
      final completer = Completer<void>();
      int tapCount = 0;

      await tester.pumpWidget(
        buildTestApp(
          FushiIconButton(
            icon: Icons.sync,
            tooltip: 'Sync',
            busy: true,
            onTap: () async {
              tapCount++;
              await completer.future;
            },
          ),
        ),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pump();

      // Second tap should be ignored (busy)
      await tester.tap(find.byType(InkWell));
      await tester.pump();

      expect(tapCount, 1);

      completer.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('isWideTapArea uses IconButton instead of InkWell', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          const FushiIconButton(
            icon: Icons.settings,
            tooltip: 'Settings',
            isWideTapArea: true,
          ),
        ),
      );

      expect(find.byType(IconButton), findsOneWidget);
    });

    // BUG-807：纯图标按钮（如批量操作栏）以前只把 tooltip 喂给 Semantics，屏幕上
    // 悬停不弹说明。现用 Material [Tooltip] 包裹，鼠标悬停 / 长按可见用途。
    testWidgets('plain icon button wraps in a Material Tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          FushiIconButton(
            icon: Icons.playlist_add,
            tooltip: 'Combine',
            onTap: () {},
          ),
        ),
      );

      final Tooltip tip = tester.widget<Tooltip>(
        glassUnwrap<Tooltip>(find.byType(Tooltip)),
      );
      expect(tip.message, 'Combine');
    });

    testWidgets('wide tap area icon button also wraps in a Material Tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          const FushiIconButton(
            icon: Icons.settings,
            tooltip: 'Settings',
            isWideTapArea: true,
          ),
        ),
      );

      final Tooltip tip = tester.widget<Tooltip>(
        glassUnwrap<Tooltip>(find.byType(Tooltip)),
      );
      expect(tip.message, 'Settings');
    });

    testWidgets('empty tooltip adds no Tooltip wrapper (no empty hover box)', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          FushiIconButton(icon: Icons.add, tooltip: '', onTap: () {}),
        ),
      );

      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('registers with the focus root and activates on Enter', (
      tester,
    ) async {
      bool tapped = false;
      await tester.pumpWidget(
        buildTestApp(
          FushiFocusRoot(
            child: FushiIconButton(
              focusId: const FushiFocusId('play-button'),
              icon: Icons.play_arrow,
              tooltip: 'Play',
              onTap: () => tapped = true,
            ),
          ),
        ),
      );
      await tester.pump();

      final FushiFocusController root = FushiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.play_arrow)),
      );
      expect(root.requestById(const FushiFocusId('play-button')), isTrue);
      await tester.pump();
      expect(root.activeId, const FushiFocusId('play-button'));

      Actions.maybeInvoke<ActivateIntent>(
        root.activeContext!,
        const ActivateIntent(),
      );
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });

    // 2026-10-23：MD3 图标按钮换成官方 M3E IconButton 后，官方标准 toggle 选中
    // 只染 primary、不加容器；用户拍板保留选中态的 secondaryContainer 浅色底，
    // 叠在官方按钮上。换官方实现时不得再把它丢掉。
    testWidgets('selected MD3 icon button keeps the tonal selected container', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          FushiIconButton(
            icon: Icons.checklist,
            tooltip: 'Select',
            selected: true,
            onTap: () {},
          ),
        ),
      );
      final IconButton button = tester.widget<IconButton>(
        find.byType(IconButton),
      );
      final ColorScheme cs = Theme.of(
        tester.element(find.byType(IconButton)),
      ).colorScheme;
      expect(button.isSelected, isTrue);
      expect(
        button.style?.backgroundColor?.resolve(<WidgetState>{
          WidgetState.selected,
        }),
        cs.secondaryContainer,
      );
      expect(
        button.style?.foregroundColor?.resolve(<WidgetState>{
          WidgetState.selected,
        }),
        cs.onSecondaryContainer,
      );
      // 未选中不叠底，交回官方默认。
      expect(button.style?.backgroundColor?.resolve(<WidgetState>{}), isNull);
    });

    // 2026-10-24（批量合并 #2457 后 srs_pages_test 牌组设置页三条红）：MD3 图标
    // 按钮换官方 IconButton 后，外层又包了 Tooltip + Semantics(label:)，在官方的
    // Semantics(container: true) 之上多出一个语义节点。按钮落在滚动视图缓存区
    // 之外（长表单底部输入框的粘贴钮）时，官方容器节点的矩形算成空的，框架断言
    // 「Invisible SemanticsNodes should not be added to the tree」。名称 / 提示 /
    // 按钮语义必须都在官方那一个容器节点上。
    testWidgets(
      'MD3 icon button far below the scroll cache adds no invisible semantics node',
      (tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        Widget field() => TextField(
          decoration: InputDecoration(
            labelText: 'Field',
            suffixIcon: FushiIconButton(
              icon: Icons.content_paste,
              tooltip: 'Paste',
              onTap: () {},
            ),
          ),
        );
        await tester.pumpWidget(
          buildTestApp(
            ListView(
              children: <Widget>[
                const SizedBox(height: 700),
                Column(
                  children: <Widget>[
                    const SizedBox(height: 500),
                    field(),
                    const SizedBox(height: 300),
                  ],
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        // 滚到可见处：名称与提示落在同一个按钮节点上。
        await tester.drag(find.byType(ListView), const Offset(0, -900));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSemantics(find.byType(IconButton)),
          containsSemantics(label: 'Paste', tooltip: 'Paste', isButton: true),
        );
        semantics.dispose();
      },
    );
  });
}
