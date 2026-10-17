import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/gpu_acceleration.dart';
import 'package:fushi/src/asr_host/gpu_runtime_pack.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';

CudaProbe _probe({int? driver, int major = 8, int minor = 9}) => CudaProbe(
  driverVersion: driver,
  devices: driver == null
      ? const <CudaDevice>[]
      : <CudaDevice>[
          CudaDevice(
            index: 0,
            name: 'NVIDIA GeForce RTX 4070 Ti',
            computeMajor: major,
            computeMinor: minor,
            totalMemBytes: 12 << 30,
          ),
        ],
);

const GpuDetection _nvidia = GpuDetection(
  cuda: CudaProbe(
    driverVersion: 13000,
    devices: <CudaDevice>[
      CudaDevice(
        index: 0,
        name: 'NVIDIA GeForce RTX 4070 Ti',
        computeMajor: 8,
        computeMinor: 9,
        totalMemBytes: 12 << 30,
      ),
    ],
  ),
  hasHardwareAdapter: true,
);

final GpuDetection _otherGpu = GpuDetection(
  cuda: _probe(),
  hasHardwareAdapter: true,
);

final GpuDetection _noGpu = GpuDetection(
  cuda: _probe(),
  hasHardwareAdapter: false,
);

void main() {
  group('isCudaEligible', () {
    test('驱动 ≥ 13000 且 sm_75+ 才算', () {
      expect(isCudaEligible(_probe(driver: 13000)), isTrue);
      expect(isCudaEligible(_probe(driver: 12080)), isFalse);
      expect(
        isCudaEligible(_probe(driver: 13000, major: 6, minor: 1)),
        isFalse,
      );
      expect(isCudaEligible(_probe(driver: 13000, major: 7, minor: 5)), isTrue);
      expect(isCudaEligible(_probe()), isFalse);
    });
  });

  group('detectGpuRuntime / resolveGpuRuntime', () {
    test('自动：达标 N 卡 CUDA，其它硬件显卡 DirectML，没有显卡 CPU', () {
      expect(detectGpuRuntime(_nvidia), GpuRuntimeKind.cuda);
      expect(detectGpuRuntime(_otherGpu), GpuRuntimeKind.directml);
      expect(detectGpuRuntime(_noGpu), isNull);
    });

    test('显式选择不会落到跑不起来的环境上', () {
      expect(
        resolveGpuRuntime(GpuRuntimePreference.cuda, _otherGpu),
        isNull,
        reason: '不达标的卡不该下 0.9 GB 的 CUDA',
      );
      expect(
        resolveGpuRuntime(GpuRuntimePreference.directml, _nvidia),
        GpuRuntimeKind.directml,
      );
      expect(resolveGpuRuntime(GpuRuntimePreference.directml, _noGpu), isNull);
      expect(resolveGpuRuntime(GpuRuntimePreference.off, _nvidia), isNull);
    });
  });

  group('effectiveGpuRuntime（只在已装好的里挑）', () {
    test('目标装好了就用目标', () {
      expect(
        effectiveGpuRuntime(
          GpuRuntimePreference.auto,
          _nvidia,
          <GpuRuntimeKind>{GpuRuntimeKind.cuda, GpuRuntimeKind.directml},
        ),
        GpuRuntimeKind.cuda,
      );
    });

    test('N 卡老用户：自动档只补了 DirectML，先用 DirectML 而不是 CPU', () {
      expect(
        effectiveGpuRuntime(
          GpuRuntimePreference.auto,
          _nvidia,
          <GpuRuntimeKind>{GpuRuntimeKind.directml},
        ),
        GpuRuntimeKind.directml,
      );
    });

    test('显式 CUDA 不偷偷换成 DirectML；关闭就是 CPU', () {
      expect(
        effectiveGpuRuntime(
          GpuRuntimePreference.cuda,
          _nvidia,
          <GpuRuntimeKind>{GpuRuntimeKind.directml},
        ),
        isNull,
      );
      expect(
        effectiveGpuRuntime(GpuRuntimePreference.off, _nvidia, <GpuRuntimeKind>{
          GpuRuntimeKind.cuda,
          GpuRuntimeKind.directml,
        }),
        isNull,
      );
    });

    test('什么都没装：CPU', () {
      expect(
        effectiveGpuRuntime(
          GpuRuntimePreference.auto,
          _otherGpu,
          const <GpuRuntimeKind>{},
        ),
        isNull,
      );
    });
  });

  group('GpuAccelerationStatus.restartRequired', () {
    test('该生效的已装好却没生效才要重启', () {
      const GpuAccelerationStatus pending = GpuAccelerationStatus(
        supportedPlatform: true,
        preference: GpuRuntimePreference.auto,
        effective: GpuRuntimeKind.directml,
        installed: <GpuRuntimeKind>{GpuRuntimeKind.directml},
      );
      expect(pending.restartRequired, isTrue);
      const GpuAccelerationStatus live = GpuAccelerationStatus(
        supportedPlatform: true,
        preference: GpuRuntimePreference.auto,
        effective: GpuRuntimeKind.directml,
        installed: <GpuRuntimeKind>{GpuRuntimeKind.directml},
        active: GpuRuntimeKind.directml,
      );
      expect(live.restartRequired, isFalse);
      const GpuAccelerationStatus failed = GpuAccelerationStatus(
        supportedPlatform: true,
        preference: GpuRuntimePreference.auto,
        effective: GpuRuntimeKind.cuda,
        installed: <GpuRuntimeKind>{GpuRuntimeKind.cuda},
        error: 'cudnn missing',
      );
      expect(failed.restartRequired, isFalse, reason: '失败要显示原因，不是重启');
    });
  });
}
