// 内存采样探针（[PreviousExitLog.startMemorySampling]）：Android 原生堆（malloc）当前分配量。
//
// BUG-4075：停在复习页不动时进程 RSS 3 分钟从 1.1 GB 涨到 3 GB 闪退，SRS 原生计数（SQLite 堆 / 连接数）
// 全程不变。malloc 的分配量把匿名内存分成两半：涨在 malloc 里 = Rust / SQLite / 引擎 C++ 侧；涨在 malloc
// 外（`anon` 涨、`malloc` 不涨）= Dart 堆或图形映射。bionic（含 Scudo）的 `mallinfo()` 字段是 size_t，
// `uordblks` 是当前已分配字节。

import 'dart:ffi';
import 'dart:io';

/// bionic `struct mallinfo`（10 个 size_t）。
final class _MallInfo extends Struct {
  @Size()
  external int arena;
  @Size()
  external int ordblks;
  @Size()
  external int smblks;
  @Size()
  external int hblks;
  @Size()
  external int hblkhd;
  @Size()
  external int usmblks;
  @Size()
  external int fsmblks;
  @Size()
  external int uordblks;
  @Size()
  external int fordblks;
  @Size()
  external int keepcost;
}

typedef _MallInfoNative = _MallInfo Function();

_MallInfo Function()? _mallinfo;
bool _resolved = false;

_MallInfo Function()? _resolveMallinfo() {
  if (_resolved) return _mallinfo;
  _resolved = true;
  if (!Platform.isAndroid) return null;
  try {
    _mallinfo = DynamicLibrary.process()
        .lookupFunction<_MallInfoNative, _MallInfoNative>('mallinfo');
  } on Object {
    _mallinfo = null;
  }
  return _mallinfo;
}

/// `malloc=…MB`：Android 上 malloc 当前已分配的字节；别的平台或取不到返回 null。
String? nativeHeapProbe() {
  final _MallInfo Function()? f = _resolveMallinfo();
  if (f == null) return null;
  return 'malloc=${f().uordblks >> 20}MB';
}
