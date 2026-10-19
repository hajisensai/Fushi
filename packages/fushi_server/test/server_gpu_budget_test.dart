import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_server/src/server_gpu_budget.dart';
import 'package:test/test.dart';

class _Inner implements asr.OnnxSessionFactory {
  _Inner(this.providers, {this.budget});

  final Set<asr.OnnxExecutionProvider> providers;
  final int? budget;

  @override
  Future<Set<asr.OnnxExecutionProvider>>
  availableAcceleratedProviders() async => providers;

  @override
  Future<int?> deviceMemoryBudgetBytes() async => budget;

  @override
  Future<asr.OnnxSession> createSession(
    String modelPath, {
    required List<asr.OnnxExecutionProvider> providers,
    void Function(asr.OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) => throw UnimplementedError();
}

/// FFI 后端查不到显存预算 → 带显存门槛的 Parakeet 有 N 卡也规划成 CPU int8
/// （2026-10-19 基准验收暴露）。服务端补一层 nvidia-smi 查询。
void main() {
  test('nvidia-smi 的 memory.free（MiB）→ 字节；看不懂为 null', () {
    expect(parseNvidiaSmiFreeMib('30120\n'), 30120 * 1024 * 1024);
    expect(parseNvidiaSmiFreeMib('[N/A]\n'), isNull);
    expect(parseNvidiaSmiFreeMib(''), isNull);
  });

  test('ORT 有 CUDA EP 时补上 nvidia-smi 的预算；内层查得到就用内层的', () async {
    final List<int> asked = <int>[];
    Future<int?> query(int device) async {
      asked.add(device);
      return 8 << 30;
    }

    expect(
      await ServerGpuBudgetOnnxFactory(
        _Inner(<asr.OnnxExecutionProvider>{asr.OnnxExecutionProvider.cuda}),
        query: query,
      ).deviceMemoryBudgetBytes(),
      8 << 30,
    );
    expect(asked, <int>[0]);
    expect(
      await ServerGpuBudgetOnnxFactory(
        _Inner(<asr.OnnxExecutionProvider>{
          asr.OnnxExecutionProvider.cuda,
        }, budget: 123),
        query: query,
      ).deviceMemoryBudgetBytes(),
      123,
    );
    expect(asked, hasLength(1));
  });

  test('没有 CUDA EP（CPU 版 ORT）：不查、仍是未知', () async {
    bool called = false;
    expect(
      await ServerGpuBudgetOnnxFactory(
        _Inner(const <asr.OnnxExecutionProvider>{}),
        query: (int _) async {
          called = true;
          return 1;
        },
      ).deviceMemoryBudgetBytes(),
      isNull,
    );
    expect(called, isFalse);
  });

  test('有了预算，Parakeet 这类带 4 GB 门槛的包在 CUDA 上规划成 fp32', () {
    expect(
      asr.recommendAsrEncoderVariant(
        platform: asr.AsrPlatform.windows,
        available: const <asr.OnnxExecutionProvider>{
          asr.OnnxExecutionProvider.cuda,
        },
        preference: asr.AsrAccelerationPreference.auto,
        fp32GpuMinBudgetBytes: 4 << 30,
        budgetBytes: 8 << 30,
      ),
      asr.AsrEncoderVariant.fp32,
    );
    expect(
      asr.recommendAsrEncoderVariant(
        platform: asr.AsrPlatform.windows,
        available: const <asr.OnnxExecutionProvider>{
          asr.OnnxExecutionProvider.cuda,
        },
        preference: asr.AsrAccelerationPreference.auto,
        fp32GpuMinBudgetBytes: 4 << 30,
      ),
      asr.AsrEncoderVariant.int8,
    );
  });
}
