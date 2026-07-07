import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/render_backend_service.dart';

/// TODO-1232 A3：渲染后端（关 Impeller）实验开关的 Dart 侧接线守卫。
/// 真机切换后端需 realme 8 复测；这里只锁「channel 方法名 / 参数 / 缓存 / 平台
/// 缺失静默降级」这层可离屏验证的契约，防接线漂移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final RenderBackendService service = RenderBackendService.instance;
  const MethodChannel testChannel = MethodChannel('test/render');

  setUp(() {
    service.channel = testChannel;
    // 单例 instance 跨用例复用；重置「本次运行后端」快照，让每个用例从确定初态起跑。
    service.debugResetForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(testChannel, null);
  });

  test('init reads persisted impellerDisabled from native', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(testChannel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'isImpellerDisabled') return true;
      return null;
    });

    await service.init();

    expect(calls.single.method, 'isImpellerDisabled');
    expect(service.impellerDisabled, isTrue);
    expect(service.isSupported, isTrue);
  });

  test('setImpellerDisabled forwards the bool arg and caches the value',
      () async {
    MethodCall? last;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(testChannel, (MethodCall call) async {
      last = call;
      return null;
    });

    final bool ok = await service.setImpellerDisabled(true);
    expect(ok, isTrue);
    expect(last?.method, 'setImpellerDisabled');
    expect(last?.arguments, true);
    expect(service.impellerDisabled, isTrue);

    await service.setImpellerDisabled(false);
    expect(service.impellerDisabled, isFalse);
  });

  test('missing native channel degrades to unsupported without throwing',
      () async {
    // A channel with no mock handler surfaces MissingPluginException in tests;
    // the service must swallow it (non-Android platforms) rather than crash.
    service.channel = const MethodChannel('test/render_absent');

    await service.init();
    expect(service.isSupported, isFalse);
    expect(await service.setImpellerDisabled(true), isFalse);
  });

  group('TODO-1232 本次运行后端快照（诊断日志自证测的是哪个后端）', () {
    Future<void> initWith(bool disabled) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, (MethodCall call) async {
        if (call.method == 'isImpellerDisabled') return disabled;
        return null;
      });
      await service.init();
    }

    test('启动即关 Impeller → activeBackendLabel=skia', () async {
      await initWith(true);
      expect(service.activeImpellerDisabled, isTrue);
      expect(service.activeBackendLabel, 'skia');
    });

    test('启动跑 Impeller → activeBackendLabel=impeller', () async {
      await initWith(false);
      expect(service.activeImpellerDisabled, isFalse);
      expect(service.activeBackendLabel, 'impeller');
    });

    test('本次运行内翻开关只改「下次意图」，不动「本次实际后端」快照', () async {
      // 本运行跑 Impeller（activeImpellerDisabled=false），用户在设置里打开「关
      // Impeller」——只影响下次启动。诊断日志据 activeBackendLabel 仍报 impeller，
      // 绝不把「已翻但未重启」误报成 skia（否则关 Impeller 复测结论会假阳性）。
      await initWith(false);
      final bool ok = await service.setImpellerDisabled(true);
      expect(ok, isTrue);
      expect(service.impellerDisabled, isTrue); // 下次启动意图已翻。
      expect(service.activeImpellerDisabled, isFalse); // 本次运行后端不变。
      expect(service.activeBackendLabel, 'impeller');
    });

    test('非 Android（channel 未接线）→ activeBackendLabel=n/a', () async {
      service.channel = const MethodChannel('test/render_absent_active');
      await service.init();
      expect(service.isSupported, isFalse);
      expect(service.activeBackendLabel, 'n/a');
    });
  });
}
