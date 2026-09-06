/// 插件往返延迟基准：小模型（silero-vad）连续 run 的平均耗时，用来量
/// `flutter_onnxruntime` 工作线程化前后的每次调用开销（FLUTTER_ONNXRUNTIME_SYNC=1
/// 时插件退回同步执行，可 A/B）。
///
///   ASR_MODEL_SEED=<含 silero_vad.onnx 的目录>
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('插件往返延迟', (WidgetTester tester) async {
    final String seed = Platform.environment['ASR_MODEL_SEED'] ?? '';
    expect(seed, isNotEmpty);
    final OrtOnnxSessionFactory factory = OrtOnnxSessionFactory();
    // ignore: avoid_print
    print(
      '[asr-latency] gpu budget=${await factory.deviceMemoryBudgetBytes()}',
    );
    final OnnxSession vad = await factory.createSession(
      p.join(seed, 'silero_vad.onnx'),
      providers: const <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
    );
    final Map<String, OnnxTensor> inputs = <String, OnnxTensor>{
      AsrModelIo.vadInputX: OnnxTensor.float32(
        Float32List(kAsrVadWindowSamples),
        <int>[1, kAsrVadWindowSamples],
      ),
      AsrModelIo.vadInputH: OnnxTensor.float32(Float32List(128), <int>[
        2,
        1,
        64,
      ]),
      AsrModelIo.vadInputC: OnnxTensor.float32(Float32List(128), <int>[
        2,
        1,
        64,
      ]),
    };
    for (int i = 0; i < 20; i++) {
      await vad.run(inputs);
    }
    const int n = 300;
    final Stopwatch sw = Stopwatch()..start();
    for (int i = 0; i < n; i++) {
      await vad.run(inputs);
    }
    sw.stop();
    // ignore: avoid_print
    print(
      '[asr-latency] sync=${Platform.environment['FLUTTER_ONNXRUNTIME_SYNC'] ?? '0'} '
      'runs=$n avg=${(sw.elapsedMicroseconds / n / 1000).toStringAsFixed(2)}ms',
    );
    await vad.close();
  });
}
