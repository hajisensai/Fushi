// BUG-2906：系统 OCR 报「模型未就绪」时不能只丢一句提示——要带用户去配置
// （查状态 / 请 Play 服务立即下载 / 修 Play 服务）。
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/ocr/system_ocr_setup_dialog.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;

class _FakeSetup implements SystemOcrModelSetup {
  _FakeSetup(this.statuses);

  /// 每次 modelStatus 依次取一个；取完重复最后一个。
  final List<SystemOcrModelStatus> statuses;
  int statusCalls = 0;
  final List<String> installed = <String>[];
  int resolveCalls = 0;
  Completer<void>? installGate;
  Exception? installError;

  @override
  Future<SystemOcrModelStatus> modelStatus(String language) async {
    final int index = statusCalls < statuses.length
        ? statusCalls
        : statuses.length - 1;
    statusCalls++;
    return statuses[index];
  }

  @override
  Future<void> installModel(String language) async {
    installed.add(language);
    await installGate?.future;
    final Exception? error = installError;
    if (error != null) throw error;
  }

  @override
  Future<bool> resolvePlayServices() async {
    resolveCalls++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelSystemOcr 模型配置面', () {
    const MethodChannel channel = MethodChannel('test/system_ocr_setup');
    final List<MethodCall> calls = <MethodCall>[];

    void handle(Future<Object?> Function(MethodCall call)? handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            handler == null
                ? null
                : (MethodCall call) {
                    calls.add(call);
                    return handler(call);
                  },
          );
    }

    setUp(calls.clear);
    tearDown(() => handle(null));

    test('modelStatus 按线上值映射，并带上语言', () async {
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      const Map<String, SystemOcrModelStatus> wire =
          <String, SystemOcrModelStatus>{
            'ready': SystemOcrModelStatus.ready,
            'missing': SystemOcrModelStatus.missing,
            'play_services_resolvable':
                SystemOcrModelStatus.playServicesResolvable,
            'play_services_unavailable':
                SystemOcrModelStatus.playServicesUnavailable,
          };
      for (final MapEntry<String, SystemOcrModelStatus> e in wire.entries) {
        handle((MethodCall call) async => e.key);
        expect(await ocr.modelStatus('ja'), e.value);
      }
      expect(calls.last.method, 'modelStatus');
      expect(calls.last.arguments, <String, Object?>{'language': 'ja'});
    });

    test('平台没实现（非 Android）= 没有模型可缺', () async {
      handle(null);
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      expect(await ocr.modelStatus('ja'), SystemOcrModelStatus.ready);
    });

    test('未知状态值不能被当成就绪', () async {
      handle((MethodCall call) async => 'weird');
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      await expectLater(
        ocr.modelStatus('ja'),
        throwsA(isA<PlatformException>()),
      );
    });

    test('installModel 带语言调用，失败照实抛出', () async {
      handle((MethodCall call) async => 'ready');
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      await ocr.installModel('ja');
      expect(calls.single.method, 'installModel');
      expect(calls.single.arguments, <String, Object?>{'language': 'ja'});

      handle((MethodCall call) async {
        throw PlatformException(code: 'INSTALL_FAILED', message: 'boom');
      });
      await expectLater(
        ocr.installModel('ja'),
        throwsA(isA<PlatformException>()),
      );
    });

    test('recognize 报 MODEL_UNAVAILABLE → 带模型未就绪原因的异常', () async {
      handle((MethodCall call) async {
        throw PlatformException(code: 'MODEL_UNAVAILABLE');
      });
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      await expectLater(
        ocr.recognize(Uint8List(4), language: 'ja'),
        throwsA(
          isA<SystemOcrUnavailableException>().having(
            (SystemOcrUnavailableException e) => e.reason,
            'reason',
            kSystemOcrModelUnavailableReason,
          ),
        ),
      );
    });
  });

  group('系统 OCR 模型配置弹窗', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    Future<void> open(WidgetTester tester, SystemOcrModelSetup setup) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => unawaited(
                  showSystemOcrSetupDialog(
                    context,
                    language: 'ja',
                    setup: setup,
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
    }

    Finder message(String text) => find.descendant(
      of: find.byKey(const ValueKey<String>('system_ocr_setup_message')),
      matching: find.text(text),
      // Text 自己就挂着这个 key。
      matchRoot: true,
    );

    testWidgets('缺模型：点「下载」请 Play 服务下载，下完显示就绪', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelStatus>[
        SystemOcrModelStatus.missing,
      ])..installGate = Completer<void>();
      await open(tester, setup);
      expect(message(t.ocr_system_model_missing), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('system_ocr_setup_download')),
      );
      await tester.pump();
      expect(setup.installed, <String>['ja']);
      expect(message(t.ocr_system_model_downloading), findsOneWidget);
      expect(find.byType(FushiCircularProgressIndicator), findsOneWidget);

      setup.installGate!.complete();
      await tester.pumpAndSettle();
      expect(message(t.ocr_system_model_ready), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('system_ocr_setup_download')),
        findsNothing,
      );
    });

    testWidgets('下载失败：显示原因，可重试（重新查状态）', (WidgetTester tester) async {
      final _FakeSetup setup =
          _FakeSetup(<SystemOcrModelStatus>[
              SystemOcrModelStatus.missing,
              SystemOcrModelStatus.ready,
            ])
            ..installError = PlatformException(
              code: 'INSTALL_FAILED',
              message: 'no network',
            );
      await open(tester, setup);
      await tester.tap(
        find.byKey(const ValueKey<String>('system_ocr_setup_download')),
      );
      await tester.pumpAndSettle();
      expect(
        message(t.ocr_system_model_failed(error: 'no network')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('system_ocr_setup_retry')),
      );
      await tester.pumpAndSettle();
      expect(setup.statusCalls, 2);
      expect(message(t.ocr_system_model_ready), findsOneWidget);
    });

    testWidgets('Play 服务可修：给修复入口，修完重新查状态', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelStatus>[
        SystemOcrModelStatus.playServicesResolvable,
        SystemOcrModelStatus.missing,
      ]);
      await open(tester, setup);
      expect(
        message(t.ocr_system_model_play_services_resolvable),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('system_ocr_setup_fix_play_services'),
        ),
      );
      await tester.pumpAndSettle();
      expect(setup.resolveCalls, 1);
      expect(message(t.ocr_system_model_missing), findsOneWidget);
    });

    testWidgets('没有 Play 服务：如实说明，不给下载按钮', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelStatus>[
        SystemOcrModelStatus.playServicesUnavailable,
      ]);
      await open(tester, setup);
      expect(
        message(t.ocr_system_model_play_services_unavailable),
        findsOneWidget,
      );
      expect(find.byType(FilledButton), findsNothing);
    });
  });
}
