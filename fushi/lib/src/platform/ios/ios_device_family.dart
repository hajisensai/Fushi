// iOS 设备是 iPhone 还是 iPad（拍板台 1tOPDqYm4V）。
//
// 「文件」App 侧栏里 app 自己的位置叫「我的 iPhone」/「我的 iPad」，指引文案要跟着设备走。
// 判据取 `uname().machine`（`iPhone15,2` / `iPad13,4`）：同步、零插件、启动后不变，
// 构建 UI 时直接能用；device_info_plus 的 `iosInfo` 是异步的，放进导入方式列表这种同步
// build 路径只能先渲染错的再刷新。模拟器上 machine 是宿主架构（`arm64` / `x86_64`），
// 改读模拟器注入的 `SIMULATOR_MODEL_IDENTIFIER`。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// iOS 设备大类。只区分「文件」App 文案用得到的两种。
enum IosDeviceFamily { iphone, ipad }

/// 机型标识 → 设备大类；认不出（含 iPod touch、空串）按 iPhone 处理，与改前文案一致。
///
/// [simulatorModel] 是模拟器的 `SIMULATOR_MODEL_IDENTIFIER`，真机为 null；非空时优先于
/// [machine]（模拟器的 machine 是宿主架构名）。
IosDeviceFamily iosDeviceFamilyFromMachine(
  String machine, {
  String? simulatorModel,
}) {
  final String id = (simulatorModel != null && simulatorModel.isNotEmpty)
      ? simulatorModel
      : machine;
  return id.startsWith('iPad') ? IosDeviceFamily.ipad : IosDeviceFamily.iphone;
}

IosDeviceFamily? _cached;

/// 当前 iOS 设备的大类（只在 iOS 上有意义，别的平台返回 [IosDeviceFamily.iphone]）。
IosDeviceFamily get currentIosDeviceFamily {
  if (!Platform.isIOS) return IosDeviceFamily.iphone;
  return _cached ??= iosDeviceFamilyFromMachine(
    _unameMachine(),
    simulatorModel: Platform.environment['SIMULATOR_MODEL_IDENTIFIER'],
  );
}

typedef _UnameNative = Int32 Function(Pointer<Uint8>);
typedef _UnameDart = int Function(Pointer<Uint8>);

/// Darwin `struct utsname`：5 个 `char[_SYS_NAMELEN]`（256），machine 是第 5 个。
const int _kUtsFieldLength = 256;
const int _kUtsMachineOffset = 4 * _kUtsFieldLength;

String _unameMachine() {
  final Pointer<Uint8> buf = calloc<Uint8>(5 * _kUtsFieldLength);
  try {
    final _UnameDart uname = DynamicLibrary.process()
        .lookupFunction<_UnameNative, _UnameDart>('uname');
    if (uname(buf) != 0) return '';
    final Pointer<Uint8> machine = buf + _kUtsMachineOffset;
    return machine.cast<Utf8>().toDartString(
      length: _strnlen(machine, _kUtsFieldLength),
    );
  } finally {
    calloc.free(buf);
  }
}

int _strnlen(Pointer<Uint8> p, int max) {
  int n = 0;
  while (n < max && p[n] != 0) {
    n++;
  }
  return n;
}
