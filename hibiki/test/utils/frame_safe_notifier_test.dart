import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/frame_safe_notifier.dart';

class _TestNotifier extends ChangeNotifier with FrameSafeNotifier {}

// Calls [onPaint] from inside the paint phase — the exact window where
// FlutterError.onError fires for a RenderFlex overflow indicator and routes into
// an error-log notifier.
class _NotifyOnPaint extends CustomPainter {
  _NotifyOnPaint(this.onPaint);
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) => onPaint();
  @override
  bool shouldRepaint(covariant _NotifyOnPaint oldDelegate) => false;
}

void main() {
  testWidgets(
    'notifyListenersFrameSafe during paint does not throw '
    '"Build scheduled during frame"',
    (WidgetTester tester) async {
      final _TestNotifier notifier = _TestNotifier();
      addTearDown(notifier.dispose);
      int builds = 0;

      await tester.pumpWidget(MaterialApp(
        home: Column(
          children: <Widget>[
            // A listener that rebuilds on notify (mirrors SettingsHomePage's
            // setState-on-log listener).
            ListenableBuilder(
              listenable: notifier,
              builder: (BuildContext _, Widget? __) {
                builds++;
                return const SizedBox.shrink();
              },
            ),
            // Emits a notification from within the paint phase, where a
            // synchronous notifyListeners would rebuild the listener mid-frame
            // and trigger "Build scheduled during frame".
            CustomPaint(
              painter: _NotifyOnPaint(notifier.notifyListenersFrameSafe),
              size: const Size(10, 10),
            ),
          ],
        ),
      ));

      final int buildsAfterMount = builds;
      expect(tester.takeException(), isNull,
          reason: 'a mid-paint notify must not raise a framework error');

      // The deferred notify still reaches listeners, just after the frame.
      await tester.pump();
      expect(builds, greaterThan(buildsAfterMount),
          reason: 'the listener still rebuilds, on the next frame');
    },
  );

  testWidgets('notifyListenersFrameSafe notifies synchronously when idle',
      (WidgetTester tester) async {
    final _TestNotifier notifier = _TestNotifier();
    addTearDown(notifier.dispose);
    int notifications = 0;
    notifier.addListener(() => notifications++);

    // Outside any frame it behaves exactly like notifyListeners.
    expect(SchedulerBinding.instance.schedulerPhase, SchedulerPhase.idle);
    notifier.notifyListenersFrameSafe();
    expect(notifications, 1);
  });
}
