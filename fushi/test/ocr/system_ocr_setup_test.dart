// BUG-2906：系统 OCR 报「模型未就绪」时不能只丢一句提示——要带用户去配置
// （查状态 / 请 Play 服务立即下载 / 修 Play 服务）。
// BUG-4127：Play 服务的问题按原始 ConnectionResult 码分开说，给对应出路，并把
// 原始码与版本号显示出来；不再把所有异常合成「缺失、被停用或版本过旧」一句。
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
  _FakeSetup(this.reports);

  /// 每次 modelStatus 依次取一个；取完重复最后一个。
  final List<SystemOcrModelReport> reports;
  int statusCalls = 0;
  final List<String> installed = <String>[];
  int resolveCalls = 0;
  int openSettingsCalls = 0;
  Completer<void>? installGate;
  Exception? installError;

  @override
  Future<SystemOcrModelReport> modelStatus(String language) async {
    final int index = statusCalls < reports.length
        ? statusCalls
        : reports.length - 1;
    statusCalls++;
    return reports[index];
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

  @override
  Future<void> openPlayServicesSettings() async {
    openSettingsCalls++;
  }
}

const SystemOcrModelReport _ready = SystemOcrModelReport(
  SystemOcrModelStatus.ready,
);
const SystemOcrModelReport _missing = SystemOcrModelReport(
  SystemOcrModelStatus.missing,
);

/// 原生侧 Play 服务出问题时回传的载荷（字段名 = SystemOcrChannel.KEY_*）。
Map<String, Object?> _problemWire(
  int code, {
  int? installedCode = 241000,
  String? installedName = '24.10.00',
  int required = 250000,
}) => <String, Object?>{
  'status': 'play_services_problem',
  'connectionResult': code,
  'installedVersionCode': installedCode,
  'installedVersionName': installedName,
  'requiredVersionCode': required,
};

SystemOcrModelReport _problem(int code) =>
    parseSystemOcrModelReport(_problemWire(code))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectionResult 原始码 → 状态（BUG-4127）', () {
    test('可区分的码各自独立成一个状态', () {
      const Map<int, SystemOcrModelStatus> expected =
          <int, SystemOcrModelStatus>{
            1: SystemOcrModelStatus.playServicesMissing,
            2: SystemOcrModelStatus.playServicesUpdateRequired,
            3: SystemOcrModelStatus.playServicesDisabled,
            9: SystemOcrModelStatus.playServicesInvalid,
            18: SystemOcrModelStatus.playServicesUpdating,
          };
      for (final MapEntry<int, SystemOcrModelStatus> e in expected.entries) {
        expect(
          systemOcrStatusForConnectionResult(e.key),
          e.value,
          reason: 'ConnectionResult ${e.key}',
        );
      }
    });

    test('其它码一律是「用不了」，不会被当成可修', () {
      for (final int code in <int>[4, 5, 6, 7, 8, 10, 11, 16, 19, 20, 99, -1]) {
        expect(
          systemOcrStatusForConnectionResult(code),
          SystemOcrModelStatus.playServicesUnavailable,
          reason: 'ConnectionResult $code',
        );
      }
    });
  });

  group('parseSystemOcrModelReport', () {
    test('ready / missing 不带诊断', () {
      expect(
        parseSystemOcrModelReport(<String, Object?>{'status': 'ready'}),
        _ready,
      );
      expect(
        parseSystemOcrModelReport(<String, Object?>{'status': 'missing'}),
        _missing,
      );
    });

    test('Play 服务问题：按原始码定状态，并保留码与两边版本号', () {
      expect(
        parseSystemOcrModelReport(_problemWire(2)),
        const SystemOcrModelReport(
          SystemOcrModelStatus.playServicesUpdateRequired,
          playServices: SystemOcrPlayServicesDiagnostics(
            connectionResult: 2,
            requiredVersionCode: 250000,
            installedVersionCode: 241000,
            installedVersionName: '24.10.00',
          ),
        ),
      );
      final SystemOcrModelReport notInstalled = parseSystemOcrModelReport(
        _problemWire(1, installedCode: null, installedName: null),
      )!;
      expect(notInstalled.status, SystemOcrModelStatus.playServicesMissing);
      expect(notInstalled.playServices!.installedVersionCode, isNull);
      expect(notInstalled.playServices!.installedVersionName, isNull);
    });

    test('看不懂的载荷返回 null（调用方必须报错，不能当成就绪）', () {
      expect(parseSystemOcrModelReport(null), isNull);
      expect(parseSystemOcrModelReport('ready'), isNull);
      expect(
        parseSystemOcrModelReport(<String, Object?>{'status': 'weird'}),
        isNull,
      );
      expect(
        parseSystemOcrModelReport(<String, Object?>{
          'status': 'play_services_problem',
          'requiredVersionCode': 1,
        }),
        isNull,
      );
    });
  });

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

    test('modelStatus 解析载荷，并带上语言', () async {
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      handle((MethodCall call) async => <String, Object?>{'status': 'missing'});
      expect(await ocr.modelStatus('ja'), _missing);
      handle((MethodCall call) async => _problemWire(3));
      final SystemOcrModelReport report = await ocr.modelStatus('ja');
      expect(report.status, SystemOcrModelStatus.playServicesDisabled);
      expect(report.playServices!.connectionResult, 3);
      expect(calls.last.method, 'modelStatus');
      expect(calls.last.arguments, <String, Object?>{'language': 'ja'});
    });

    test('平台没实现（非 Android）= 没有模型可缺', () async {
      handle(null);
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      expect(await ocr.modelStatus('ja'), _ready);
    });

    test('未知状态值不能被当成就绪', () async {
      handle((MethodCall call) async => <String, Object?>{'status': 'weird'});
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

    test('installModel 遇到 Play 服务问题 → 带诊断的专用异常', () async {
      handle((MethodCall call) async {
        throw PlatformException(
          code: 'PLAY_SERVICES_UNAVAILABLE',
          message: 'Google Play services ConnectionResult 18',
          details: _problemWire(18),
        );
      });
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      await expectLater(
        ocr.installModel('ja'),
        throwsA(
          isA<SystemOcrPlayServicesException>().having(
            (SystemOcrPlayServicesException e) => e.report,
            'report',
            _problem(18),
          ),
        ),
      );
    });

    test('openPlayServicesSettings 走同名平台方法', () async {
      handle((MethodCall call) async => true);
      const MethodChannelSystemOcr ocr = MethodChannelSystemOcr(
        channel: channel,
      );
      await ocr.openPlayServicesSettings();
      expect(calls.single.method, 'openPlayServicesSettings');
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

  test('systemOcrSetupPhaseFor：每个状态各有一个阶段', () {
    const Map<SystemOcrModelStatus, SystemOcrSetupPhase> expected =
        <SystemOcrModelStatus, SystemOcrSetupPhase>{
          SystemOcrModelStatus.ready: SystemOcrSetupPhase.ready,
          SystemOcrModelStatus.missing: SystemOcrSetupPhase.missing,
          SystemOcrModelStatus.playServicesMissing:
              SystemOcrSetupPhase.playServicesMissing,
          SystemOcrModelStatus.playServicesDisabled:
              SystemOcrSetupPhase.playServicesDisabled,
          SystemOcrModelStatus.playServicesUpdateRequired:
              SystemOcrSetupPhase.playServicesUpdateRequired,
          SystemOcrModelStatus.playServicesUpdating:
              SystemOcrSetupPhase.playServicesUpdating,
          SystemOcrModelStatus.playServicesInvalid:
              SystemOcrSetupPhase.playServicesInvalid,
          SystemOcrModelStatus.playServicesUnavailable:
              SystemOcrSetupPhase.playServicesUnavailable,
        };
    expect(expected.keys, unorderedEquals(SystemOcrModelStatus.values));
    for (final MapEntry<SystemOcrModelStatus, SystemOcrSetupPhase> e
        in expected.entries) {
      expect(systemOcrSetupPhaseFor(e.key), e.value, reason: '${e.key}');
    }
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

    Finder byKey(String key) => find.byKey(ValueKey<String>(key));

    String diagnosticsText(WidgetTester tester) =>
        tester
            .widget<SelectableText>(byKey('system_ocr_setup_diagnostics'))
            .data ??
        '';

    const List<String> playServicesActions = <String>[
      'system_ocr_setup_install_play_services',
      'system_ocr_setup_update_play_services',
      'system_ocr_setup_open_play_services',
      'system_ocr_setup_recheck',
      'system_ocr_setup_download',
    ];

    void expectOnlyActions(Set<String> present) {
      for (final String key in playServicesActions) {
        expect(
          byKey(key),
          present.contains(key) ? findsOneWidget : findsNothing,
          reason: key,
        );
      }
    }

    testWidgets('缺模型：点「下载」请 Play 服务下载，下完显示就绪', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[_missing])
        ..installGate = Completer<void>();
      await open(tester, setup);
      expect(message(t.ocr_system_model_missing), findsOneWidget);
      expect(byKey('system_ocr_setup_diagnostics'), findsNothing);

      await tester.tap(byKey('system_ocr_setup_download'));
      await tester.pump();
      expect(setup.installed, <String>['ja']);
      expect(message(t.ocr_system_model_downloading), findsOneWidget);
      expect(find.byType(FushiCircularProgressIndicator), findsOneWidget);

      setup.installGate!.complete();
      await tester.pumpAndSettle();
      expect(message(t.ocr_system_model_ready), findsOneWidget);
      expect(byKey('system_ocr_setup_download'), findsNothing);
    });

    testWidgets('下载失败：显示原因，可重试（重新查状态）', (WidgetTester tester) async {
      final _FakeSetup setup =
          _FakeSetup(<SystemOcrModelReport>[_missing, _ready])
            ..installError = PlatformException(
              code: 'INSTALL_FAILED',
              message: 'no network',
            );
      await open(tester, setup);
      await tester.tap(byKey('system_ocr_setup_download'));
      await tester.pumpAndSettle();
      expect(
        message(t.ocr_system_model_failed(error: 'no network')),
        findsOneWidget,
      );

      await tester.tap(byKey('system_ocr_setup_retry'));
      await tester.pumpAndSettle();
      expect(setup.statusCalls, 2);
      expect(message(t.ocr_system_model_ready), findsOneWidget);
    });

    testWidgets('下载时撞上 Play 服务问题：切到对应状态并显示原始码', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[_missing])
        ..installError = SystemOcrPlayServicesException(_problem(18));
      await open(tester, setup);
      await tester.tap(byKey('system_ocr_setup_download'));
      await tester.pumpAndSettle();
      expect(
        message(t.ocr_system_model_play_services_updating),
        findsOneWidget,
      );
      expect(diagnosticsText(tester), contains('18'));
    });

    testWidgets('版本过旧（已是最新也会遇到）：说清楚，给更新入口，显示两边版本号', (
      WidgetTester tester,
    ) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[
        _problem(2),
        _missing,
      ]);
      await open(tester, setup);
      expect(
        message(t.ocr_system_model_play_services_update_required),
        findsOneWidget,
      );
      expect(
        diagnosticsText(tester),
        t.ocr_system_model_play_services_diagnostics(
          code: '2',
          installed: '24.10.00 (241000)',
          required: '250000',
        ),
      );
      expectOnlyActions(<String>{'system_ocr_setup_update_play_services'});

      await tester.tap(byKey('system_ocr_setup_update_play_services'));
      await tester.pumpAndSettle();
      expect(setup.resolveCalls, 1);
      expect(message(t.ocr_system_model_missing), findsOneWidget);
      expect(byKey('system_ocr_setup_diagnostics'), findsNothing);
    });

    testWidgets('没装 Play 服务：给安装入口，版本显示「未安装」', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[
        parseSystemOcrModelReport(
          _problemWire(1, installedCode: null, installedName: null),
        )!,
        _missing,
      ]);
      await open(tester, setup);
      expect(message(t.ocr_system_model_play_services_missing), findsOneWidget);
      expect(
        diagnosticsText(tester),
        contains(t.ocr_system_model_play_services_version_not_found),
      );
      expectOnlyActions(<String>{'system_ocr_setup_install_play_services'});

      await tester.tap(byKey('system_ocr_setup_install_play_services'));
      await tester.pumpAndSettle();
      expect(setup.resolveCalls, 1);
      expect(message(t.ocr_system_model_missing), findsOneWidget);
    });

    testWidgets('被停用：去应用设置启用，回来由用户点「重新检查」', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[
        _problem(3),
        _missing,
      ]);
      await open(tester, setup);
      expect(
        message(t.ocr_system_model_play_services_disabled),
        findsOneWidget,
      );
      expectOnlyActions(<String>{
        'system_ocr_setup_open_play_services',
        'system_ocr_setup_recheck',
      });

      await tester.tap(byKey('system_ocr_setup_open_play_services'));
      await tester.pumpAndSettle();
      expect(setup.openSettingsCalls, 1);
      expect(setup.resolveCalls, 0);
      // 打开设置本身不重查：状态没变之前不该替用户下结论。
      expect(setup.statusCalls, 1);

      await tester.tap(byKey('system_ocr_setup_recheck'));
      await tester.pumpAndSettle();
      expect(setup.statusCalls, 2);
      expect(message(t.ocr_system_model_missing), findsOneWidget);
    });

    testWidgets('正在更新：提示稍后，只给「重新检查」', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[
        _problem(18),
        _missing,
      ]);
      await open(tester, setup);
      expect(
        message(t.ocr_system_model_play_services_updating),
        findsOneWidget,
      );
      expectOnlyActions(<String>{'system_ocr_setup_recheck'});
      expect(setup.statusCalls, 1);

      await tester.tap(byKey('system_ocr_setup_recheck'));
      await tester.pumpAndSettle();
      expect(setup.statusCalls, 2);
      expect(setup.resolveCalls, 0);
      expect(message(t.ocr_system_model_missing), findsOneWidget);
    });

    testWidgets('不是正版 / 已损坏：如实说明，不给修复按钮，显示原始码', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[_problem(9)]);
      await open(tester, setup);
      expect(message(t.ocr_system_model_play_services_invalid), findsOneWidget);
      expectOnlyActions(<String>{});
      expect(find.byType(FilledButton), findsNothing);
      expect(diagnosticsText(tester), contains('9'));
    });

    testWidgets('其它原因用不了：如实说明，不给按钮，显示原始码', (WidgetTester tester) async {
      final _FakeSetup setup = _FakeSetup(<SystemOcrModelReport>[_problem(16)]);
      await open(tester, setup);
      expect(
        message(t.ocr_system_model_play_services_unavailable),
        findsOneWidget,
      );
      expectOnlyActions(<String>{});
      expect(find.byType(FilledButton), findsNothing);
      expect(
        diagnosticsText(tester),
        t.ocr_system_model_play_services_diagnostics(
          code: '16',
          installed: '24.10.00 (241000)',
          required: '250000',
        ),
      );
    });
  });
}
