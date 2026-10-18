import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/underlay_composition.dart';

/// 播放器页在 dispose 里归还底层合成（树锁着的 finalizeTree 阶段）：标题栏监听
/// [underlayCompositionActive]，此刻直接改值会抛「setState() called when widget tree was locked」，
/// release 下标题栏就停在透明底。
void main() {
  final List<bool> engineCalls = <bool>[];

  setUp(() {
    engineCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kUnderlayCompositionChannel, (
          MethodCall call,
        ) async {
          if (call.method == 'setUnderlayComposition') {
            engineCalls.add(call.arguments as bool);
          }
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kUnderlayCompositionChannel, null);
  });

  testWidgets('dispose 里归还：不在锁树时通知，帧后标题栏回到不透明', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: <Widget>[
            ValueListenableBuilder<bool>(
              valueListenable: underlayCompositionActive,
              builder: (BuildContext _, bool on, Widget? __) =>
                  Text(on ? 'clear' : 'opaque'),
            ),
            const _Holder(),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(underlayCompositionActive.value, isTrue);
    expect(find.text('clear'), findsOneWidget);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<bool>(
          valueListenable: underlayCompositionActive,
          builder: (BuildContext _, bool on, Widget? __) =>
              Text(on ? 'clear' : 'opaque'),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(underlayCompositionActive.value, isFalse);
    expect(find.text('opaque'), findsOneWidget);
    expect(engineCalls, <bool>[true, false]);
    debugDefaultTargetPlatformOverride = null;
  });
}

class _Holder extends StatefulWidget {
  const _Holder();

  @override
  State<_Holder> createState() => _HolderState();
}

class _HolderState extends State<_Holder> {
  @override
  void initState() {
    super.initState();
    unawaited(acquireUnderlayComposition());
  }

  @override
  void dispose() {
    unawaited(releaseUnderlayComposition());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
