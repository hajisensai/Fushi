import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 漫画页超分引擎的 Dart 绑定（`ffc_upscale_*`）：符号齐全、参数在碰 ORT 之前就被拒、没启动时如实报
/// 「未就绪」。真模型推理在 Rust 的 env 门控测试里（native/fushi_compute/src/upscale.rs）。
void main() {
  final FushiComputeUpscale engine = FushiComputeUpscale.instance;

  test('engine reports not-ready before start/configure', () {
    expect(engine.query('v1|l0|scope|page.jpg'), FfcUpscaleKeyState.notReady);
    expect(engine.cachedPath('v1|l0|scope|page.jpg'), isNull);
    expect(
      engine.submit(
        token: 1,
        key: 'v1|l0|scope|page.jpg',
        page: 0,
        data: Uint8List.fromList(<int>[1, 2, 3]),
      ),
      FfcUpscaleSubmit.notReady,
    );
    // ORT 还没接上：任何后端都不可用。
    expect(engine.backendAvailable(FfcUpscaleBackend.cpu), isFalse);
    engine.focus(3, 2);
    engine.clear();
  });

  test('submit rejects empty data and ragged boxes before crossing FFI', () {
    expect(
      () => engine.submit(token: 1, key: 'k', page: 0, data: Uint8List(0)),
      throwsArgumentError,
    );
    expect(
      () => engine.submit(
        token: 1,
        key: 'k',
        page: 0,
        data: Uint8List.fromList(<int>[1]),
        boxes: Float32List(3),
      ),
      throwsArgumentError,
    );
  });

  test('event kinds map from native codes', () {
    expect(FfcUpscaleEventKind.fromCode(1), FfcUpscaleEventKind.done);
    expect(FfcUpscaleEventKind.fromCode(5), FfcUpscaleEventKind.modelsFailed);
    expect(FfcUpscaleEventKind.fromCode(99), isNull);
  });

  // configure 交出配置代际（HBK-AUDIT-006：modelsFailed 的 token 就是失败那一代）：同配置不换代，
  // 换配置加一。不需要 ORT（模型在工作线程里才加载）。
  test('configure hands out the engine generation', () {
    ({int status, int generation}) light() => engine.configure(
      tier: FfcUpscaleTier.light,
      backend: FfcUpscaleBackend.cpu,
      insideModel: null,
      outsideModel: 'binding_test_light.onnx',
    );
    final ({int status, int generation}) first = light();
    expect(first.status, FfcStatus.ok);
    expect(first.generation, greaterThan(0));
    expect(light().generation, first.generation);
    final ({int status, int generation}) other = engine.configure(
      tier: FfcUpscaleTier.light,
      backend: FfcUpscaleBackend.cpu,
      insideModel: null,
      outsideModel: 'binding_test_other.onnx',
    );
    expect(other.status, FfcStatus.ok);
    expect(other.generation, first.generation + 1);
    expect(
      engine
          .configure(
            tier: FfcUpscaleTier.high,
            backend: FfcUpscaleBackend.cpu,
            insideModel: 'a.onnx',
            outsideModel: 'b.onnx',
          )
          .status,
      FfcUpscaleStatus.unsupported,
    );
  });
}
