import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// Windows 显卡解码能力判定（BUG-3315）：本机是否确认能用 NVDEC 硬解 H.264 High 10。
//
// 只回答一个问题——[resolvePlatformHwdec] 要不要在 `auto-safe` 候选表末尾加
// `nvdec-copy`。CUDA 初始化就是 BUG-1639 的崩溃现场（`nvcuda64!cuCtxCreate`，根因未
// 追清），而 NVDEC 从 Blackwell 起才支持 H.264 High 10：老一代 NVIDIA 显卡上加了它，
// 每部 D3D11 解不了的片源都会先初始化 CUDA、再因 profile 不支持回落软解，白走一趟雷区。
// 所以判定是保守的：**只有确认支持才下发**，枚举失败 / 不确定一律当不支持。
//
// 判据只读 DXGI 的显卡身份（`IDXGIFactory1::EnumAdapters1` + `GetDesc1`），不加载
// `nvcuda64.dll`、不建任何设备，在 app 进程里做是安全的。

/// PCI vendor id：NVIDIA。
const int kPciVendorNvidia = 0x10DE;

/// NVIDIA 的 Blackwell 起始 device id。NVIDIA 按芯片代际递增分配 PCI device id：
/// Ampere GA10x 在 `0x22xx`–`0x25xx`，Hopper GH100 在 `0x23xx`，Ada AD10x 在
/// `0x26xx`–`0x28xx`；Blackwell 数据中心 GB100 从 `0x29xx` 起，消费级 GB20x 在
/// `0x2Bxx`–`0x2Fxx`（RTX 5090 = `0x2B85`、5080 = `0x2C02`、5070 = `0x2F04`、
/// 5060 = `0x2D05`）。低于它的一律视为不支持 H.264 High 10 的 NVDEC。
const int kNvidiaBlackwellFirstDeviceId = 0x2900;

/// 一块 DXGI 显卡里判定解码能力用得到的身份字段（`DXGI_ADAPTER_DESC1` 的子集）。
@immutable
class DxgiAdapterIdentity {
  const DxgiAdapterIdentity({
    required this.vendorId,
    required this.deviceId,
    required this.description,
    required this.isSoftware,
  });

  final int vendorId;
  final int deviceId;
  final String description;

  /// `DXGI_ADAPTER_FLAG_SOFTWARE`（如 Microsoft Basic Render Driver）。
  final bool isSoftware;

  @override
  String toString() {
    final String vendor = vendorId.toRadixString(16).padLeft(4, '0');
    final String device = deviceId.toRadixString(16).padLeft(4, '0');
    return '$description [$vendor:$device]${isSoftware ? ' (software)' : ''}';
  }
}

/// 一次 DXGI 显卡枚举的结果：[adapters] 为 null 表示枚举本身失败，原因在 [failure]。
typedef DxgiAdapterProbe = ({
  List<DxgiAdapterIdentity>? adapters,
  String? failure,
});

/// 这组显卡上的 NVDEC 是否确认能硬解 H.264 High 10。纯函数。
///
/// 规则：至少有一块硬件 NVIDIA 显卡，且**每一块**硬件 NVIDIA 显卡都是 Blackwell 及以后
/// （device id ≥ [kNvidiaBlackwellFirstDeviceId]）。多块 NVIDIA 卡混插时 mpv 选哪块做
/// CUDA 解码不由我们决定，只要有一块老卡就不下发。[adapters] 为 null（枚举失败）= 未知 =
/// 不支持。
bool nvdecDecodesH264High10(List<DxgiAdapterIdentity>? adapters) {
  if (adapters == null) return false;
  final List<DxgiAdapterIdentity> nvidia = adapters
      .where(
        (DxgiAdapterIdentity a) =>
            !a.isSoftware && a.vendorId == kPciVendorNvidia,
      )
      .toList(growable: false);
  return nvidia.isNotEmpty &&
      nvidia.every(
        (DxgiAdapterIdentity a) => a.deviceId >= kNvidiaBlackwellFirstDeviceId,
      );
}

bool _nvdecHigh10Capable = false;

/// 启动时装配的判定结果；未装配（单测、弹窗词典等副入口、非 Windows）恒为 false。
bool get windowsNvdecHigh10Capable => _nvdecHigh10Capable;

/// 在 Windows 上枚举 DXGI 显卡并装配 [windowsNvdecHigh10Capable]；其它平台不动。
///
/// 放在 `main()` 而不是懒求值：[resolvePlatformHwdec] 是同步纯函数，单测在 Windows 宿主上
/// 也会走 Windows 分支，懒求值会让测试结果随跑测试那台机器的显卡变。装配一次即可——
/// 显卡身份在进程生命周期内不变。
void installWindowsHwdecCapability({bool? isWindows}) {
  if (!(isWindows ?? Platform.isWindows)) return;
  final DxgiAdapterProbe probe = probeDxgiAdapters();
  _nvdecHigh10Capable = nvdecDecodesH264High10(probe.adapters);
  debugPrint(
    '[video-hwdec] adapters=${probe.adapters ?? probe.failure} '
    'nvdec-h264-high10=$_nvdecHigh10Capable',
  );
}

// ---------------------------------------------------------------------------
// DXGI FFI（裸 COM vtable 调用，与本仓其它 Win32 FFI 一样不引 win32 包）。
// ---------------------------------------------------------------------------

typedef _CreateFactoryNative =
    Int32 Function(Pointer<Uint8> riid, Pointer<Pointer<Void>> factory);
typedef _CreateFactoryDart =
    int Function(Pointer<Uint8> riid, Pointer<Pointer<Void>> factory);
typedef _ReleaseNative = Uint32 Function(Pointer<Void> self);
typedef _ReleaseDart = int Function(Pointer<Void> self);
typedef _EnumAdapters1Native =
    Int32 Function(
      Pointer<Void> self,
      Uint32 index,
      Pointer<Pointer<Void>> adapter,
    );
typedef _EnumAdapters1Dart =
    int Function(Pointer<Void> self, int index, Pointer<Pointer<Void>> adapter);
typedef _GetDesc1Native =
    Int32 Function(Pointer<Void> self, Pointer<Uint8> desc);
typedef _GetDesc1Dart = int Function(Pointer<Void> self, Pointer<Uint8> desc);

/// `IID_IDXGIFactory1` = {770aae78-f26f-4dba-a829-253c83d1b387}，按 GUID 内存布局。
const List<int> _iidDxgiFactory1 = <int>[
  0x78, 0xae, 0x0a, 0x77, 0x6f, 0xf2, 0xba, 0x4d, //
  0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87,
];

/// vtable 槽位：IUnknown(3) + IDXGIObject(4) + IDXGIFactory(5) → EnumAdapters1 = 12；
/// IUnknown(3) + IDXGIObject(4) + IDXGIAdapter(3) → GetDesc1 = 10。
const int _kReleaseSlot = 2;
const int _kEnumAdapters1Slot = 12;
const int _kGetDesc1Slot = 10;

/// `DXGI_ADAPTER_DESC1`（x64）：WCHAR Description[128] @0，VendorId @256，DeviceId @260，
/// ……，Flags @304，总长 312。
const int _kAdapterDesc1Size = 312;
const int _kDescriptionChars = 128;
const int _kVendorIdWord = 256 ~/ 4;
const int _kDeviceIdWord = 260 ~/ 4;
const int _kFlagsWord = 304 ~/ 4;
const int _kAdapterFlagSoftware = 0x2;

const int _kDxgiErrorNotFound = 0x887A0002;
const int _kMaxAdapters = 64;

/// COM 对象 [self] 的 vtable 第 [slot] 项（函数地址）。
int _vtableEntry(Pointer<Void> self, int slot) =>
    self.cast<Pointer<IntPtr>>().value[slot];

void _release(Pointer<Void> self) {
  final _ReleaseDart release =
      Pointer<NativeFunction<_ReleaseNative>>.fromAddress(
        _vtableEntry(self, _kReleaseSlot),
      ).asFunction<_ReleaseDart>();
  release(self);
}

/// 枚举本机全部 DXGI 显卡。非 Windows / `dxgi.dll` 不可用 / COM 调用失败时
/// `adapters` 为 null，`failure` 写明原因（调用方据此保守判定为不支持）。
DxgiAdapterProbe probeDxgiAdapters() {
  if (!Platform.isWindows) return (adapters: null, failure: 'not-windows');
  final DynamicLibrary dxgi;
  try {
    dxgi = DynamicLibrary.open('dxgi.dll');
  } on ArgumentError catch (error) {
    return (adapters: null, failure: 'dxgi.dll unavailable: $error');
  }
  final _CreateFactoryDart createFactory = dxgi
      .lookupFunction<_CreateFactoryNative, _CreateFactoryDart>(
        'CreateDXGIFactory1',
      );
  final Pointer<Uint8> iid = calloc<Uint8>(_iidDxgiFactory1.length);
  final Pointer<Pointer<Void>> out = calloc<Pointer<Void>>();
  try {
    for (int i = 0; i < _iidDxgiFactory1.length; i++) {
      iid[i] = _iidDxgiFactory1[i];
    }
    final int hr = createFactory(iid, out);
    if (hr != 0) {
      return (adapters: null, failure: 'CreateDXGIFactory1 hr=${_hex(hr)}');
    }
    final Pointer<Void> factory = out.value;
    try {
      return _enumerateAdapters(factory);
    } finally {
      _release(factory);
    }
  } finally {
    calloc.free(iid);
    calloc.free(out);
  }
}

DxgiAdapterProbe _enumerateAdapters(Pointer<Void> factory) {
  final _EnumAdapters1Dart enumAdapters =
      Pointer<NativeFunction<_EnumAdapters1Native>>.fromAddress(
        _vtableEntry(factory, _kEnumAdapters1Slot),
      ).asFunction<_EnumAdapters1Dart>();
  final Pointer<Pointer<Void>> out = calloc<Pointer<Void>>();
  final List<DxgiAdapterIdentity> adapters = <DxgiAdapterIdentity>[];
  try {
    for (int index = 0; index < _kMaxAdapters; index++) {
      final int hr = enumAdapters(factory, index, out);
      if (hr.toUnsigned(32) == _kDxgiErrorNotFound) break;
      if (hr != 0) {
        return (adapters: null, failure: 'EnumAdapters1 hr=${_hex(hr)}');
      }
      final DxgiAdapterIdentity? identity = _describeAdapter(out.value);
      if (identity == null) {
        return (adapters: null, failure: 'GetDesc1 failed at adapter $index');
      }
      adapters.add(identity);
    }
  } finally {
    calloc.free(out);
  }
  return (adapters: adapters, failure: null);
}

DxgiAdapterIdentity? _describeAdapter(Pointer<Void> adapter) {
  final Pointer<Uint8> desc = calloc<Uint8>(_kAdapterDesc1Size);
  try {
    final _GetDesc1Dart getDesc1 =
        Pointer<NativeFunction<_GetDesc1Native>>.fromAddress(
          _vtableEntry(adapter, _kGetDesc1Slot),
        ).asFunction<_GetDesc1Dart>();
    final int hr = getDesc1(adapter, desc);
    if (hr != 0) return null;
    final Pointer<Uint32> words = desc.cast<Uint32>();
    return DxgiAdapterIdentity(
      vendorId: words[_kVendorIdWord],
      deviceId: words[_kDeviceIdWord],
      description: _readWideString(desc.cast<Uint16>(), _kDescriptionChars),
      isSoftware: (words[_kFlagsWord] & _kAdapterFlagSoftware) != 0,
    );
  } finally {
    calloc.free(desc);
    _release(adapter);
  }
}

String _readWideString(Pointer<Uint16> chars, int capacity) {
  final List<int> units = <int>[];
  for (int i = 0; i < capacity && chars[i] != 0; i++) {
    units.add(chars[i]);
  }
  return String.fromCharCodes(units);
}

String _hex(int hr) => '0x${hr.toUnsigned(32).toRadixString(16)}';
