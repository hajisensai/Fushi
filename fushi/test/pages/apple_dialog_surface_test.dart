// Apple（Cupertino）下对话框级工作面（捕获设置 / 校准）的呈现：macOS 档窗口
// sheet、iOS 档整页；M3E 照旧是对话框（用户 2026-11-24 拍板）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/gal_capture_setup_dialog.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/src/utils/adaptive/fushi_apple_surface.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme({required bool glass, required TargetPlatform platform}) =>
    buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      textTheme: Typography.material2021().black,
      glassDesign: glass,
    ).copyWith(platform: platform);

class _Probe {
  bool closed = false;
  Object? result;
}

/// 起一个只有「打开」按钮的宿主；点按钮经 [showAdaptiveDialogSurface] 推 [builder]。
Future<_Probe> _host(
  WidgetTester tester, {
  required WidgetBuilder builder,
  required Size size,
  bool glass = true,
  TargetPlatform platform = TargetPlatform.windows,
  bool barrierDismissible = true,
}) async {
  // MediaQuery 的宽（档位判据）跟 view 走，setSurfaceSize 改不到它。
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final _Probe probe = _Probe();
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(glass: glass, platform: platform),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey<String>('open-surface'),
              onPressed: () async {
                probe.result = await showAdaptiveDialogSurface<Object>(
                  context: context,
                  barrierDismissible: barrierDismissible,
                  builder: builder,
                );
                probe.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open-surface')));
  await tester.pumpAndSettle();
  return probe;
}

Widget _sample(BuildContext context) => FushiAppleSurfaceFrame(
  title: 'Sample surface',
  actions: <Widget>[
    FushiFilledButton(
      key: const ValueKey<String>('sample-ok'),
      onPressed: () => Navigator.of(context).pop('ok'),
      child: const Text('OK'),
    ),
  ],
  body: const Text('sample body', key: ValueKey<String>('sample-body')),
);

Finder _inside(Finder of, Type type) =>
    find.ancestor(of: of, matching: find.byType(type));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('showAdaptiveDialogSurface', () {
    testWidgets('macOS 档（桌面宽窗）是窗口 sheet，返回值照对话框语义', (
      WidgetTester tester,
    ) async {
      final _Probe probe = await _host(
        tester,
        builder: _sample,
        size: const Size(1400, 900),
      );
      final Finder body = find.byKey(const ValueKey<String>('sample-body'));
      expect(_inside(body, FushiModalSheetFrame), findsOneWidget);
      expect(_inside(body, FushiMastheadScaffold), findsNothing);
      expect(
        tester
            .widget<FushiAppleSurfaceScope>(
              _inside(body, FushiAppleSurfaceScope),
            )
            .form,
        FushiAppleSurfaceForm.sheet,
      );
      expect(find.text('Sample surface'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('sample-ok')));
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
      expect(probe.result, 'ok');
    });

    testWidgets('不可点外部关的 sheet 点遮罩不关', (WidgetTester tester) async {
      final _Probe probe = await _host(
        tester,
        builder: _sample,
        size: const Size(1400, 900),
        barrierDismissible: false,
      );
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('sample-body')), findsOneWidget);
      expect(probe.closed, isFalse);
    });

    for (final (String label, Size size, TargetPlatform platform)
        in <(String, Size, TargetPlatform)>[
          ('桌面窄窗', const Size(500, 900), TargetPlatform.windows),
          ('iOS 平台宽屏', const Size(1400, 900), TargetPlatform.iOS),
        ]) {
      testWidgets('iOS 档（$label）是整页，返回 = 取消（null）', (
        WidgetTester tester,
      ) async {
        final _Probe probe = await _host(
          tester,
          builder: _sample,
          size: size,
          platform: platform,
        );
        final Finder body = find.byKey(const ValueKey<String>('sample-body'));
        expect(_inside(body, FushiMastheadScaffold), findsOneWidget);
        expect(_inside(body, FushiModalSheetFrame), findsNothing);
        expect(find.byKey(const ValueKey<String>('sample-ok')), findsOneWidget);
        await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
        await tester.pumpAndSettle();
        expect(probe.closed, isTrue);
        expect(probe.result, isNull);
      });
    }

    testWidgets('M3E 仍是对话框，不进 Apple 工作面', (WidgetTester tester) async {
      FushiAppleSurfaceForm? seen = FushiAppleSurfaceForm.page;
      await _host(
        tester,
        glass: false,
        size: const Size(1400, 900),
        builder: (BuildContext context) {
          seen = FushiAppleSurfaceScope.maybeFormOf(context);
          return const AlertDialog(content: Text('m3e'));
        },
      );
      expect(find.text('m3e'), findsOneWidget);
      expect(seen, isNull);
      expect(find.byType(FushiMastheadScaffold), findsNothing);
    });
  });

  group('捕获设置', () {
    late GalHookSessionController session;
    late GalAttachedTextController attachedText;
    late ValueNotifier<int> endpointSignal;

    setUp(() {
      endpointSignal = ValueNotifier<int>(0);
      session = GalHookSessionController(
        textService: TexthookerService.test(),
        isWindows: false,
        endpointListenable: endpointSignal,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );
      attachedText = GalAttachedTextController(
        preferenceReader: (_) => null,
        preferenceWriter: (_, __) async {},
      );
    });

    tearDown(() async {
      await attachedText.detach();
      attachedText.dispose();
      session.dispose();
      endpointSignal.dispose();
    });

    Widget dialog(BuildContext context) => GalCaptureSetupDialog(
      session: session,
      attachedText: attachedText,
      onSelectThread: (_) async => true,
    );

    testWidgets('macOS 档：sheet，标题在头部、「关闭」在底部', (WidgetTester tester) async {
      final _Probe probe = await _host(
        tester,
        builder: dialog,
        size: const Size(1400, 900),
      );
      final Finder setup = find.byType(GalCaptureSetupDialog);
      expect(
        find.descendant(of: setup, matching: find.byType(FushiModalSheetFrame)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: setup, matching: find.byType(FushiAlertDialog)),
        findsNothing,
      );
      expect(find.text(t.game_capture_setup_title), findsOneWidget);
      expect(find.text(t.game_text_thread), findsOneWidget);
      await tester.tap(find.text(t.dialog_close));
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('iOS 档：整页，没有「关闭」，返回即关', (WidgetTester tester) async {
      final _Probe probe = await _host(
        tester,
        builder: dialog,
        size: const Size(430, 900),
        platform: TargetPlatform.iOS,
      );
      final Finder setup = find.byType(GalCaptureSetupDialog);
      expect(
        find.descendant(
          of: setup,
          matching: find.byType(FushiMastheadScaffold),
        ),
        findsOneWidget,
      );
      expect(find.text(t.dialog_close), findsNothing);
      expect(find.text(t.game_audio_tracks), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });

    testWidgets('M3E：仍是 FushiAlertDialog', (WidgetTester tester) async {
      await _host(
        tester,
        builder: dialog,
        size: const Size(1400, 900),
        glass: false,
      );
      expect(
        find.descendant(
          of: find.byType(GalCaptureSetupDialog),
          matching: find.byType(FushiAlertDialog),
        ),
        findsOneWidget,
      );
      expect(find.byType(FushiModalSheetFrame), findsNothing);
    });
  });
}
