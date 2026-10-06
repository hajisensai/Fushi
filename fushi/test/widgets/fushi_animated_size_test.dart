import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';

Widget _host(Duration duration, Widget child, {VoidCallback? onEnd}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: FushiAnimatedSize(
          duration: duration,
          curve: Curves.linear,
          onEnd: onEnd,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('zero duration expands and shrinks in the current layout', (
    WidgetTester tester,
  ) async {
    int completed = 0;
    for (final double height in <double>[80, 180, 40]) {
      await tester.pumpWidget(
        _host(
          Duration.zero,
          SizedBox(width: 200, height: height),
          onEnd: () => completed++,
        ),
      );
      expect(tester.getSize(find.byType(FushiAnimatedSize)), Size(200, height));
      expect(tester.takeException(), isNull);
      expect(find.byType(AnimatedSize), findsNothing);
    }
    expect(
      completed,
      0,
      reason: 'Immediate layout is not animation completion.',
    );
  });

  testWidgets('nonzero duration retains intermediate frames and onEnd', (
    WidgetTester tester,
  ) async {
    int completed = 0;
    const Duration duration = Duration(milliseconds: 200);
    await tester.pumpWidget(
      _host(duration, const SizedBox(width: 200, height: 80)),
    );
    await tester.pumpWidget(
      _host(
        duration,
        const SizedBox(width: 200, height: 180),
        onEnd: () => completed++,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final double midway = tester.getSize(find.byType(FushiAnimatedSize)).height;
    expect(midway, greaterThan(80));
    expect(midway, lessThan(180));
    expect(completed, 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FushiAnimatedSize)).height, 180);
    expect(completed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changing motion mid-animation preserves child Element and State',
    (WidgetTester tester) async {
      const Duration duration = Duration(milliseconds: 200);
      await tester.pumpWidget(_host(duration, const _Editor(height: 80)));
      final Element element = tester.element(find.byType(_Editor));
      final _EditorState state = tester.state<_EditorState>(
        find.byType(_Editor),
      );
      await tester.enterText(find.byType(TextField), 'unsaved draft');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await tester.pumpWidget(_host(duration, const _Editor(height: 180)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.getSize(find.byType(FushiAnimatedSize)).height,
        lessThan(180),
      );
      await tester.pumpWidget(_host(Duration.zero, const _Editor(height: 180)));
      expect(tester.getSize(find.byType(FushiAnimatedSize)).height, 180);
      expect(tester.element(find.byType(_Editor)), same(element));
      expect(tester.state<_EditorState>(find.byType(_Editor)), same(state));
      expect(state.controller.text, 'unsaved draft');
      expect(state.disposed, isFalse);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_host(duration, const _Editor(height: 180)));
      expect(tester.element(find.byType(_Editor)), same(element));
      expect(tester.state<_EditorState>(find.byType(_Editor)), same(state));
      expect(state.controller.text, 'unsaved draft');
      expect(state.disposed, isFalse);
      await tester.pumpWidget(_host(duration, const _Editor(height: 80)));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(FushiAnimatedSize)).height, 80);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Editor extends StatefulWidget {
  const _Editor({required this.height});

  final double height;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final TextEditingController controller = TextEditingController();
  bool disposed = false;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 200,
    height: widget.height,
    child: TextField(controller: controller),
  );

  @override
  void dispose() {
    disposed = true;
    controller.dispose();
    super.dispose();
  }
}
