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
}
