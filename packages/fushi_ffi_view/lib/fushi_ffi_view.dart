/// 原生内存的 typed data 视图：本仓唯一允许调用 `Pointer.asTypedList` 的地方
/// （守卫 `fushi/test/build/ffi_typed_list_view_guard_test.dart`）。
///
/// 为什么不直接 `ptr.asTypedList(n)`：Dart VM（JIT，3.13.5 与 3.15.0-57.0.dev 实测）
/// 会把只在本函数里按下标读写、不逃逸的 asTypedList 视图做分配下沉（allocation
/// sinking）；函数在视图存活期间去优化时，deopt 物化出来的 `_External*Array` 的数据
/// 指针是 Smi 标记过的地址（真地址 × 2），下一次 `view[i] = …` 写进非法地址，
/// 进程 SIGSEGV。最小复现见本包 `test/as_typed_list_deopt_canary_test.dart`。
///
/// 本仓实际撞上的路径：`--experimental-faster-testing` 下所有 suite 共用一个 isolate
/// group 的 JIT 代码与类型反馈，`Utf16BatchBuffer.fill`（fushi_compute）被优化后又在
/// 某个 suite 里去优化，flutter_tester 随机 exit 245（PR #2422 撤回 faster-testing 的
/// 原因）。单 suite、调试版 app、`dart run` 工具同样可能撞上，只是概率低。AOT（发布版、
/// `dart build cli`）没有去优化，不受影响。
///
/// 这里的扩展方法标了 `vm:never-inline`：视图在被调函数里创建并作为返回值逃逸，调用方
/// 拿到的是已物化的对象，没有可下沉的分配。代价是每次建视图多一次普通调用。
///
/// 清理条件：Dart SDK 修掉这个去优化物化错误后（本包 canary 测试在新 SDK 上不再崩，
/// 它会变红提醒），把各处改回 `asTypedList`、删掉本包与守卫。
library;

import 'dart:ffi';
import 'dart:typed_data';

extension Int8OutOfLineView on Pointer<Int8> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Int8List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension Int16OutOfLineView on Pointer<Int16> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Int16List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension Int32OutOfLineView on Pointer<Int32> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Int32List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension Int64OutOfLineView on Pointer<Int64> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Int64List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension Uint8OutOfLineView on Pointer<Uint8> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Uint8List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension Uint16OutOfLineView on Pointer<Uint16> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Uint16List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension Uint32OutOfLineView on Pointer<Uint32> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Uint32List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension Uint64OutOfLineView on Pointer<Uint64> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Uint64List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension FloatOutOfLineView on Pointer<Float> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Float32List asTypedListOutOfLine(int length) => asTypedList(length);
}

extension DoubleOutOfLineView on Pointer<Double> {
  /// 同 `asTypedList(length)`，但不让 JIT 下沉视图分配（见库注释）。
  @pragma('vm:never-inline')
  Float64List asTypedListOutOfLine(int length) => asTypedList(length);
}
