import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/windows_hwdec_capability.dart';

/// BUG-3315：`nvdec-copy` 只在显卡确认能硬解 H.264 High 10（NVIDIA Blackwell 及以后）时
/// 才进 `auto-safe` 候选表。判定是纯函数，按 DXGI 身份钉住各代显卡与混插情形。
DxgiAdapterIdentity _adapter(
  int vendorId,
  int deviceId, {
  String description = 'test adapter',
  bool isSoftware = false,
}) => DxgiAdapterIdentity(
  vendorId: vendorId,
  deviceId: deviceId,
  description: description,
  isSoftware: isSoftware,
);

const int _intel = 0x8086;
const int _amd = 0x1002;
const int _microsoft = 0x1414;

void main() {
  group('nvdecDecodesH264High10 (BUG-3315)', () {
    test('枚举失败 / 没有显卡 = 未知 = 不下发', () {
      expect(nvdecDecodesH264High10(null), isFalse);
      expect(nvdecDecodesH264High10(const <DxgiAdapterIdentity>[]), isFalse);
    });

    test('Blackwell 消费级与数据中心型号判为支持', () {
      for (final int device in <int>[
        0x2B85, // RTX 5090
        0x2C02, // RTX 5080
        0x2C05, // RTX 5070 Ti
        0x2F04, // RTX 5070
        0x2D04, // RTX 5060 Ti
        0x2D05, // RTX 5060
        0x2901, // B200
      ]) {
        expect(
          nvdecDecodesH264High10(<DxgiAdapterIdentity>[
            _adapter(kPciVendorNvidia, device),
          ]),
          isTrue,
          reason: 'device 0x${device.toRadixString(16)} 是 Blackwell',
        );
      }
    });

    test('Blackwell 之前的 NVIDIA 判为不支持（NVDEC 没有 H.264 High 10）', () {
      for (final int device in <int>[
        0x1E04, // RTX 2080 Ti (Turing)
        0x2204, // RTX 3090 (Ampere)
        0x2330, // H100 (Hopper)
        0x2684, // RTX 4090 (Ada)
        0x2882, // RTX 4060 (Ada)
        0x28E0, // RTX 4060 Laptop (Ada)
      ]) {
        expect(
          nvdecDecodesH264High10(<DxgiAdapterIdentity>[
            _adapter(kPciVendorNvidia, device),
          ]),
          isFalse,
          reason: 'device 0x${device.toRadixString(16)} 早于 Blackwell',
        );
      }
    });

    test('非 NVIDIA 显卡不触发 CUDA', () {
      expect(
        nvdecDecodesH264High10(<DxgiAdapterIdentity>[
          _adapter(_intel, 0x7D55),
          _adapter(_amd, 0x744C),
          // 数值上 ≥ Blackwell 阈值，但不是 NVIDIA：只认 vendor id。
          _adapter(_amd, 0x2B85),
        ]),
        isFalse,
      );
    });

    test('核显 + Blackwell 独显 → 支持；软件渲染器不参与判定', () {
      expect(
        nvdecDecodesH264High10(<DxgiAdapterIdentity>[
          _adapter(_intel, 0x7D55),
          _adapter(kPciVendorNvidia, 0x2B85),
          _adapter(_microsoft, 0x008C, isSoftware: true),
        ]),
        isTrue,
      );
    });

    test('NVIDIA 新老卡混插 → 不下发（mpv 选哪块做 CUDA 解码不由我们决定）', () {
      expect(
        nvdecDecodesH264High10(<DxgiAdapterIdentity>[
          _adapter(kPciVendorNvidia, 0x2B85),
          _adapter(kPciVendorNvidia, 0x2684),
        ]),
        isFalse,
      );
    });

    test('软件适配器即使标成 NVIDIA 也不算', () {
      expect(
        nvdecDecodesH264High10(<DxgiAdapterIdentity>[
          _adapter(kPciVendorNvidia, 0x2B85, isSoftware: true),
        ]),
        isFalse,
      );
    });
  });

  group('装配 (BUG-3315)', () {
    test('非 Windows 不枚举、不改装配值', () {
      installWindowsHwdecCapability(isWindows: false);
      expect(windowsNvdecHigh10Capable, isFalse);
    });

    test('非 Windows 宿主上枚举直接报未知，不加载 dxgi.dll', () {
      if (Platform.isWindows) return;
      final DxgiAdapterProbe probe = probeDxgiAdapters();
      expect(probe.adapters, isNull);
      expect(probe.failure, 'not-windows');
    });

    test('Windows 宿主上真实枚举不抛异常，失败必带原因，id 落在 PCI 范围', () {
      if (!Platform.isWindows) return;
      final DxgiAdapterProbe probe = probeDxgiAdapters();
      if (probe.adapters == null) {
        expect(probe.failure, isNotEmpty, reason: '枚举失败必须带原因');
      }
      // 只验证结构，不断言具体显卡（随跑测试的机器变）。
      for (final DxgiAdapterIdentity a
          in probe.adapters ?? const <DxgiAdapterIdentity>[]) {
        expect(a.vendorId, inInclusiveRange(0, 0xFFFF));
        expect(a.deviceId, inInclusiveRange(0, 0xFFFF));
      }
    });

    test('main() 在启动时装配显卡能力（resolvePlatformHwdec 读这份装配值）', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('installWindowsHwdecCapability();'));
      final String config = File(
        'lib/src/media/video/video_mpv_config.dart',
      ).readAsStringSync();
      expect(
        config,
        contains('nvdecHigh10Capable ?? windowsNvdecHigh10Capable'),
        reason: '未注入时必须取启动装配值，而不是在纯函数里懒枚举显卡',
      );
    });
  });
}
