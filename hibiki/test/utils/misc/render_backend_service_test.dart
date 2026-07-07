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
}
