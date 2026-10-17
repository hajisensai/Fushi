/// Windows ORT 运行时端到端，两种模式（一个进程只能绑定一个 onnxruntime core，
/// 所以分两次跑）：
///
/// * `ASR_ORT_MODE=cuda`（默认）：随包的最新 CPU core（1.31）上 probeCuda ->
///   registerCudaRuntime -> CUDA 会话跑一批真实 Kitsune 特征 -> 与 CPU 参考 ids
///   比对；同时断言随包 core 不含 DirectML（DirectML 改为按需下载）。
/// * `ASR_ORT_MODE=dml`：任何 ORT 调用前 selectOrtRuntime(下载的 DirectML
///   core) -> 断言绑定的就是它（1.24.x）-> DirectML 会话跑同一批 -> 比对。
///
/// 参数走环境变量（run_windows_itest.ps1 不透传 dart-define）：
///   ASR_CUDA_RT_DIR   cuda 模式：含 onnxruntime_providers_cuda.dll + cuBLAS/cuDNN
///   ASR_DML_CORE      dml 模式：DirectML 版 onnxruntime.dll（同目录放 DirectML.dll）
///   ASR_CUDA_MODEL    Kitsune model.mixed16b.onnx
///   ASR_CUDA_BATCH    批文件：int64[3] (B, 80, T) + float32 特征 + int64[B] lengths
///   ASR_CUDA_REF_IDS  CPU EP 对同一批算出的 ids（int64，按 ids 输出展平）
/// 缺参数则跳过（这是本机实测用例，CI 没有 N 卡也没有运行库）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';

String _env(String key) => Platform.environment[key] ?? '';

// ignore: avoid_print
void _log(String line) => print('[cuda-ep] $line');

Future<String> _gpuSnapshot() async {
  try {
    final ProcessResult r = await Process.run('nvidia-smi', <String>[
      '--query-gpu=name,driver_version,memory.used,utilization.gpu',
      '--format=csv,noheader',
    ]);
    final ProcessResult apps = await Process.run('nvidia-smi', <String>[
      '--query-compute-apps=pid,process_name,used_memory',
      '--format=csv,noheader',
    ]);
    return '${(r.stdout as String).trim()} | compute-apps: '
        '${(apps.stdout as String).trim().replaceAll('\n', ' ; ')}';
  } catch (e) {
    return 'nvidia-smi unavailable: $e';
  }
}

class _Batch {
  _Batch(this.features, this.lengths, this.b, this.t);
  final Float32List features;
  final Int64List lengths;
  final int b;
  final int t;
}

_Batch _readBatch(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  final ByteData data = ByteData.sublistView(bytes);
  final int b = data.getInt64(0, Endian.little);
  final int mel = data.getInt64(8, Endian.little);
  final int t = data.getInt64(16, Endian.little);
  final int n = b * mel * t;
  final Float32List features = Float32List(n);
  int off = 24;
  for (int i = 0; i < n; i++, off += 4) {
    features[i] = data.getFloat32(off, Endian.little);
  }
  final Int64List lengths = Int64List(b);
  for (int i = 0; i < b; i++, off += 8) {
    lengths[i] = data.getInt64(off, Endian.little);
  }
  return _Batch(features, lengths, b, t);
}

Future<(List<int> ids, List<double> runSeconds)> _runBatch(
  OnnxSession session,
  _Batch batch,
  int runs,
) async {
  final Map<String, OnnxTensor> inputs = <String, OnnxTensor>{
    'features': OnnxTensor.float32(batch.features, <int>[batch.b, 80, batch.t]),
    'lengths': OnnxTensor.int64(batch.lengths, <int>[batch.b]),
  };
  List<int> ids = const <int>[];
  final List<double> times = <double>[];
  for (int i = 0; i < runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    final Map<String, OnnxTensor> out = await session.run(inputs);
    times.add(sw.elapsedMicroseconds / 1e6);
    ids = out['ids']!.floatData!.map((double v) => v.round()).toList();
  }
  return (ids, times);
}

int _diff(List<int> a, Int64List ref) {
  int d = 0;
  for (int i = 0; i < a.length && i < ref.length; i++) {
    if (a[i] != ref[i]) d++;
  }
  return d + (a.length - ref.length).abs();
}

Future<void> _runCuda(
  OrtOnnxSessionFactory factory,
  String rtDir,
  String model,
  _Batch batch,
  Int64List? ref,
) async {
  // 1. 驱动探测：不依赖运行库，也不绑定 ORT。
  final CudaProbe probe = await factory.probeCuda();
  _log('probe: $probe');
  expect(probe.driverVersion, isNotNull);
  expect(probe.devices, isNotEmpty);

  // 2. 注册前：随包 core 只有 CPU（DirectML 已改为按需下载）；请求 CUDA 必须
  //    显式失败（不能静默跑到别处）。
  final Set<OnnxExecutionProvider> before = await factory
      .availableAcceleratedProviders();
  final OrtRuntimeInfo info = await factory.runtimeInfo();
  _log('runtime: $info; providers before register: $before');
  expect(info.loaded, isTrue);
  expect(info.selectedPath, isEmpty);
  expect(info.version, startsWith('1.31.'));
  expect(before, isNot(contains(OnnxExecutionProvider.cuda)));
  expect(before, isNot(contains(OnnxExecutionProvider.directml)));
  Object? unregisteredError;
  try {
    await factory.createSession(
      model,
      providers: const <OnnxExecutionProvider>[OnnxExecutionProvider.cuda],
    );
  } catch (e) {
    unregisteredError = e;
  }
  _log('CUDA before register -> $unregisteredError');
  expect(unregisteredError, isA<PlatformException>());
  expect((unregisteredError! as PlatformException).code, 'PROVIDER_ERROR');

  // 3. 注册：坏目录失败且可重试；好目录成功；同目录幂等；换目录被拒。
  final CudaRegistration bad = await factory.registerCudaRuntime(
    '$rtDir\\__missing__',
  );
  _log('register(bad dir): $bad');
  expect(bad.ok, isFalse);
  final String gpuBefore = await _gpuSnapshot();
  final Stopwatch regWatch = Stopwatch()..start();
  final CudaRegistration reg = await factory.registerCudaRuntime(rtDir);
  _log('register: $reg in ${regWatch.elapsedMilliseconds}ms');
  expect(reg.ok, isTrue, reason: reg.error);
  expect(reg.deviceCount, greaterThan(0));
  final CudaRegistration again = await factory.registerCudaRuntime('$rtDir\\');
  _log('register(again): $again');
  expect(again.ok, isTrue);
  final CudaRegistration other = await factory.registerCudaRuntime(
    'C:\\Windows',
  );
  _log('register(other dir): $other');
  expect(other.ok, isFalse);

  final Set<OnnxExecutionProvider> after = await factory
      .availableAcceleratedProviders();
  _log('providers after register: $after');
  expect(after, contains(OnnxExecutionProvider.cuda));

  // 4. CUDA 会话 + 推理。
  OnnxProviderResolution? resolution;
  final Stopwatch sw = Stopwatch()..start();
  final OnnxSession cuda = await factory.createSession(
    model,
    providers: const <OnnxExecutionProvider>[
      OnnxExecutionProvider.cuda,
      OnnxExecutionProvider.cpu,
    ],
    onProviderResolved: (OnnxProviderResolution r) => resolution = r,
  );
  _log('CUDA session ${sw.elapsedMilliseconds}ms: $resolution');
  expect(resolution?.effective, OnnxExecutionProvider.cuda);
  expect(resolution?.didFallBack, isFalse);
  final (List<int> ids, List<double> times) = await _runBatch(cuda, batch, 6);
  _log('CUDA runs(s): ${times.map((t) => t.toStringAsFixed(4))}');
  _log('gpu before register: $gpuBefore');
  _log('gpu after CUDA runs: ${await _gpuSnapshot()}');
  if (ref != null) {
    _log('CUDA ids diff vs CPU ref: ${_diff(ids, ref)}/${ref.length}');
    expect(_diff(ids, ref), lessThanOrEqualTo(ref.length ~/ 100));
  }
  await cuda.close();
}

Future<void> _runDml(
  OrtOnnxSessionFactory factory,
  String core,
  String model,
  _Batch batch,
  Int64List? ref,
) async {
  // 1. 选 core 之前：ORT 尚未绑定（probe / info 都不绑定）。
  final OrtRuntimeInfo before = await factory.runtimeInfo();
  _log('runtime before select: $before');
  expect(before.loaded, isFalse);

  final OrtRuntimeSelection missing = await selectOrtRuntime(
    '$core.__missing__.dll',
  );
  _log('select(missing): $missing');
  expect(missing.ok, isFalse);
  final OrtRuntimeSelection selection = await selectOrtRuntime(core);
  _log('select: $selection');
  expect(selection.ok, isTrue, reason: selection.error);

  // 2. 首次真正用 ORT：绑定的必须是选中的 DirectML core。
  final Set<OnnxExecutionProvider> providers = await factory
      .availableAcceleratedProviders();
  final OrtRuntimeInfo info = await factory.runtimeInfo();
  _log('runtime: $info; providers: $providers');
  expect(info.loaded, isTrue);
  expect(info.version, startsWith('1.24.'));
  expect(providers, contains(OnnxExecutionProvider.directml));

  // 绑定后换 core 被拒，同一路径仍 ok。
  final OrtRuntimeSelection same = await selectOrtRuntime(core);
  expect(same.ok, isTrue, reason: same.error);
  final OrtRuntimeSelection other = await selectOrtRuntime(
    'C:\\Windows\\System32\\onnxruntime.dll',
  );
  _log('select(other after bind): $other');
  expect(other.ok, isFalse);

  // 3. DirectML 会话 + 推理。
  OnnxProviderResolution? resolution;
  final Stopwatch sw = Stopwatch()..start();
  final OnnxSession dml = await factory.createSession(
    model,
    providers: const <OnnxExecutionProvider>[
      OnnxExecutionProvider.directml,
      OnnxExecutionProvider.cpu,
    ],
    onProviderResolved: (OnnxProviderResolution r) => resolution = r,
  );
  _log('DML session ${sw.elapsedMilliseconds}ms: $resolution');
  expect(resolution?.effective, OnnxExecutionProvider.directml);
  expect(resolution?.didFallBack, isFalse);
  final (List<int> ids, List<double> times) = await _runBatch(dml, batch, 6);
  _log('DML runs(s): ${times.map((t) => t.toStringAsFixed(4))}');
  if (ref != null) {
    _log('DML ids diff vs CPU ref: ${_diff(ids, ref)}/${ref.length}');
    expect(_diff(ids, ref), lessThanOrEqualTo(ref.length ~/ 100));
  }
  await dml.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ORT 运行时：随包 core + CUDA 插件 / 下载的 DirectML core', (
    WidgetTester tester,
  ) async {
    final String mode = _env('ASR_ORT_MODE').isEmpty
        ? 'cuda'
        : _env('ASR_ORT_MODE');
    final String rtDir = _env('ASR_CUDA_RT_DIR');
    final String dmlCore = _env('ASR_DML_CORE');
    final String model = _env('ASR_CUDA_MODEL');
    final String batchPath = _env('ASR_CUDA_BATCH');
    final String refPath = _env('ASR_CUDA_REF_IDS');
    final bool haveRuntime = mode == 'dml'
        ? dmlCore.isNotEmpty
        : rtDir.isNotEmpty;
    if (!haveRuntime || model.isEmpty || batchPath.isEmpty) {
      markTestSkipped('ASR_ORT_MODE=$mode parameters not set');
      return;
    }
    await tester.runAsync(() async {
      final OrtOnnxSessionFactory factory = OrtOnnxSessionFactory();
      final _Batch batch = _readBatch(batchPath);
      final Int64List? ref = refPath.isEmpty
          ? null
          : Int64List.sublistView(File(refPath).readAsBytesSync());
      _log('mode=$mode batch B=${batch.b} T=${batch.t}');
      if (mode == 'dml') {
        await _runDml(factory, dmlCore, model, batch, ref);
      } else {
        await _runCuda(factory, rtDir, model, batch, ref);
      }
      _log('done');
    });
  });
}
