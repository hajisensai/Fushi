import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';

/// 2026-10 体验优化：导入进行中取消键禁用、返回键不能关闭导入对话框。
class _Host extends StatefulWidget {
  const _Host({required this.gate});

  final Completer<void> gate;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with ImportFlowMixin<_Host> {
  @override
  Widget build(BuildContext context) {
    return buildImportPopGuard(
      child: Material(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            buildCancelAction(context),
            buildImportAction(
              context,
              onImport: () =>
                  runImport(logTag: 'test', action: () => widget.gate.future),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('cancel disabled and pop blocked while importing', (
    WidgetTester tester,
  ) async {
    final Completer<void> gate = Completer<void>();
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: nav,
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Center(child: _Host(gate: gate)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    ButtonStyleButton cancel() => tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(t.dialog_cancel),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    expect(cancel().onPressed, isNotNull);

    await tester.tap(find.text(t.dialog_import));
    await tester.pump();
    expect(cancel().onPressed, isNull, reason: '导入中取消键必须禁用');

    // 返回键（maybePop）被 PopScope 挡住，对话框仍在。
    // 导入键在转 spinner（无限动画），不能 pumpAndSettle。
    await nav.currentState!.maybePop();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(_Host), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(cancel().onPressed, isNotNull);
    await nav.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(_Host), findsNothing);
  });
}
