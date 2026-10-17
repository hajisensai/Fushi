import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:material_ui/material_ui.dart';

// Actual title bar and semantics/actions; only OS window operations are mocked.
// A bare MaterialApp is supported by the existing title-bar widget contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final Object fullscreenOwner = Object();
  bool maximized = false;
  final List<String> actions = <String>[];
  final List<MethodCall> captionCalls = <MethodCall>[];

  Finder buttons() => find.descendant(
    of: find.byType(FushiDesktopTitleBar),
    matching: find.byWidgetPredicate(
      (Widget widget) =>
          widget is Semantics && widget.properties.button == true,
    ),
  );

  List<String> labels(WidgetTester tester) => <String>[
    for (int i = 0; i < 3; ++i) tester.getSemantics(buttons().at(i)).label,
  ];

  Future<void> mount(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const <Locale>[Locale('en'), Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const FushiDesktopTitleBar(
          title: Text('Fushi'),
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(buttons(), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  }

  Future<void> withSemantics(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await body();
    } finally {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        // Must precede flutter_test's end-of-test verification.
        handle.dispose();
      }
    }
  }

  Future<void> nativeMaximized(WidgetTester tester, bool value) async {
    maximized = value;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'window_manager',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onEvent', <String, Object?>{
          'eventName': value ? 'maximize' : 'unmaximize',
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  Future<void> activateSemantics(WidgetTester tester, int index) async {
    final SemanticsNode node = tester.getSemantics(buttons().at(index));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.tap,
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    maximized = false;
    actions.clear();
    captionCalls.clear();
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        case 'isFullScreen':
          return false;
        case 'isFocused':
          return true;
        case 'maximize':
          maximized = true;
          actions.add(call.method);
        case 'unmaximize':
          maximized = false;
          actions.add(call.method);
        case 'minimize':
        case 'close':
          actions.add(call.method);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.fushi/window'),
      (MethodCall call) async {
        captionCalls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    FushiDesktopTitleBar.setContentFullscreen(
      owner: fullscreenOwner,
      enabled: false,
    );
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.fushi/window'),
      null,
    );
  });

  for (final bool chinese in <bool>[false, true]) {
    testWidgets(
      'HBK056 caption names and maximize state, Chinese=$chinese',
      (WidgetTester tester) => withSemantics(tester, () async {
        await mount(
          tester,
          chinese ? const Locale('zh', 'CN') : const Locale('en'),
        );
        expect(
          labels(tester),
          chinese
              ? <String>['最小化', '最大化', '关闭']
              : <String>['Minimize', 'Maximize', 'Close'],
        );
        await nativeMaximized(tester, true);
        expect(labels(tester)[1], chinese ? '还原' : 'Restore');
        await nativeMaximized(tester, false);
        expect(labels(tester)[1], chinese ? '最大化' : 'Maximize');
      }),
      skip: Platform.isMacOS,
    );
  }

  testWidgets(
    'HBK056 locale change updates the existing caption state',
    (WidgetTester tester) => withSemantics(tester, () async {
      await mount(tester, const Locale('en'));
      final Object state = tester.state(find.byType(FushiDesktopTitleBar));
      await mount(tester, const Locale('zh', 'CN'));
      expect(tester.state(find.byType(FushiDesktopTitleBar)), same(state));
      expect(labels(tester), <String>['最小化', '最大化', '关闭']);
    }),
    skip: Platform.isMacOS,
  );

  testWidgets(
    'HBK056 named caption controls keep semantic and keyboard actions',
    (WidgetTester tester) => withSemantics(tester, () async {
      await mount(tester, const Locale('en'));
      await activateSemantics(tester, 0);
      await activateSemantics(tester, 1);
      expect(labels(tester)[1], 'Restore');
      await activateSemantics(tester, 1);
      expect(labels(tester)[1], 'Maximize');
      await activateSemantics(tester, 2);
      expect(actions, <String>['minimize', 'maximize', 'unmaximize', 'close']);

      final BuildContext target = tester.element(
        find
            .descendant(
              of: buttons().first,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      Focus.of(target).requestFocus();
      await tester.pump();
      expect(Focus.of(target).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(actions.last, 'minimize');
      expect(actions, hasLength(5));
    }),
    skip: Platform.isMacOS,
  );

  testWidgets(
    'HBK056 caption names preserve DPR2 Snap and fullscreen clearing',
    (WidgetTester tester) => withSemantics(tester, () async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await mount(tester, const Locale('en'));
      final Rect logical = tester.getRect(buttons().at(1));
      expect(
        captionCalls
            .lastWhere(
              (MethodCall call) => call.method == 'setCaptionMaxButtonRect',
            )
            .arguments,
        <String, int>{
          'left': (logical.left * 2).round(),
          'top': (logical.top * 2).round(),
          'right': (logical.right * 2).round(),
          'bottom': (logical.bottom * 2).round(),
        },
      );
      FushiDesktopTitleBar.setContentFullscreen(
        owner: fullscreenOwner,
        enabled: true,
      );
      await tester.pumpAndSettle();
      expect(buttons(), findsNothing);
      expect(
        captionCalls
            .lastWhere(
              (MethodCall call) => call.method == 'setCaptionMaxButtonRect',
            )
            .arguments,
        <String, int>{'left': 0, 'top': 0, 'right': 0, 'bottom': 0},
      );
    }),
    skip: !Platform.isWindows,
  );
}
