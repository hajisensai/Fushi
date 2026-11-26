// Fushi fork (PATCHES.md delta 19): web stand-in for native_tensor_memory_ffi.dart.

import 'dart:typed_data';

/// Web has no process memory to hand out.
bool hostSupportsNativeTensorMemory() => false;

/// Web has no process memory to hand out; never constructed there.
class NativeTensorMemory {
  NativeTensorMemory._();

  /// Unsupported without `dart:ffi`.
  static NativeTensorMemory copyOf(TypedData data) => throw UnsupportedError('Native tensor memory needs dart:ffi');

  /// Unsupported without `dart:ffi`.
  static TypedData readCopy(String dataType, int address, int byteLength) =>
      throw UnsupportedError('Native tensor memory needs dart:ffi');

  /// Address of the block.
  int get address => throw UnsupportedError('Native tensor memory needs dart:ffi');

  /// Size of the block in bytes.
  int get byteLength => throw UnsupportedError('Native tensor memory needs dart:ffi');

  /// Frees the block.
  void free() => throw UnsupportedError('Native tensor memory needs dart:ffi');
}
