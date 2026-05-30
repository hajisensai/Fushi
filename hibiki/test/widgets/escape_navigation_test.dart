import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';

// On desktop, Escape should exit the current navigation level. The framework
// only wires Escape -> dismiss for `barrierDismissible` modal routes
// (dialogs/popups); full-page routes get nothing. wrapWithGlobalNavigation adds
// the page-route fallback while leaving popups (and PopScope guards / in-page
// Escape handlers) authoritative.

Widget _app(GlobalKey<NavigatorState> navKey, Widget home) {
  return MaterialApp(
    navigatorKey: navKey,
    builder: (context, child) => wrapWithGlobalNavigation(
      navigatorKey: navKey,
      child: child!,
    ),
    home: home,
  );
}

void main() {
  testWidgets('Escape pops a full-page route', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _app(
        navKey,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: Center(child: Text('PAGE2')),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('PAGE2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('PAGE2'), findsNothing,
        reason: 'Escape should pop the pushed full-page route');
  });

  testWidgets('Escape still closes a barrierDismissible dialog',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _app(
        navKey,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(content: Text('DIALOG')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('DIALOG'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('DIALOG'), findsNothing);
  });

  testWidgets('Escape in a dialog sub-page goes back one level, not closed', (
    tester,
  ) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _app(
        navKey,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _SubPageDialog(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('go sub'));
    await tester.pumpAndSettle();
    expect(find.text('SUB'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('SUB'), findsNothing);
    expect(find.text('go sub'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('go sub'), findsNothing);
  });

  testWidgets('a page that consumes Escape itself is not overridden', (
    tester,
  ) async {
    final navKey = GlobalKey<NavigatorState>();
    int escapes = 0;
    await tester.pumpWidget(
      _app(
        navKey,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Focus(
                    autofocus: true,
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        escapes++;
                        return KeyEventResult.handled; // reader-like consumer
                      }
                      return KeyEventResult.ignored;
                    },
                    child: const Scaffold(body: Center(child: Text('READER'))),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('READER'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(escapes, 1, reason: 'the in-page Escape handler runs first');
    expect(find.text('READER'), findsOneWidget,
        reason: 'page consumed Escape -> global fallback must not pop it');
  });

  testWidgets('Escape on a page respects PopScope(canPop:false)', (
    tester,
  ) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _app(
        navKey,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PopScope(
                    canPop: false,
                    child: Scaffold(body: Center(child: Text('GUARDED'))),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('GUARDED'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('GUARDED'), findsOneWidget,
        reason: 'maybePop honours PopScope(canPop:false)');
  });
}

class _SubPageDialog extends StatefulWidget {
  const _SubPageDialog();
  @override
  State<_SubPageDialog> createState() => _SubPageDialogState();
}

class _SubPageDialogState extends State<_SubPageDialog> {
  bool _sub = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_sub,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _sub = false);
      },
      child: Dialog(
        child: SizedBox(
          width: 200,
          height: 120,
          child: _sub
              ? const Center(child: Text('SUB'))
              : Center(
                  child: TextButton(
                    onPressed: () => setState(() => _sub = true),
                    child: const Text('go sub'),
                  ),
                ),
        ),
      ),
    );
  }
}
