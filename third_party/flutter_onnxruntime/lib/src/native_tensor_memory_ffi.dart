// Fushi fork (PATCHES.md delta 19, BUG-5508).

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;

import 'native_tensor_memory_host.dart';

/// Whether this process's plugin takes tensor data as an address: only the
/// Android plugin implements it. Decided by the real OS, never by the UI target
/// platform (a desktop debug run that overrides the target platform to Android
/// still talks to the desktop plugin).
bool hostSupportsNativeTensorMemory() => resolveNativeTensorMemoryHost(Platform.isAndroid);

/// A malloc'd block holding one input tensor's dense bytes.
///
/// Android's plugin wraps it as a direct ByteBuffer that ONNX Runtime reads
/// zero-copy, so the tensor never gets a Java-heap copy. The block belongs to
/// the Dart `OrtValue`: it is freed only after `releaseOrtValue` has closed the
/// native tensor that points into it.
class NativeTensorMemory {
  NativeTensorMemory._(this._pointer, this.byteLength);

  Pointer<Uint8> _pointer;

  /// Size of the block in bytes (always > 0).
  final int byteLength;

  /// Copies [data]'s bytes into a fresh block. [data] must be non-empty.
  static NativeTensorMemory copyOf(TypedData data) {
    final int byteLength = data.lengthInBytes;
    if (byteLength == 0) {
      throw ArgumentError.value(data, 'data', 'empty tensors have no native block');
    }
    final Pointer<Uint8> pointer = ffi.malloc<Uint8>(byteLength);
    pointer.asTypedList(byteLength).setAll(0, data.buffer.asUint8List(data.offsetInBytes, byteLength));
    return NativeTensorMemory._(pointer, byteLength);
  }

  /// Copies [byteLength] bytes of [dataType] elements at [address] (memory the
  /// native side owns, valid until the value is released) into a Dart list.
  static TypedData readCopy(String dataType, int address, int byteLength) {
    final Uint8List bytes = Uint8List(byteLength);
    if (byteLength > 0) {
      bytes.setAll(0, Pointer<Uint8>.fromAddress(address).asTypedList(byteLength));
    }
    final ByteBuffer buffer = bytes.buffer;
    switch (dataType) {
      case 'float32':
        return buffer.asFloat32List();
      case 'int32':
        return buffer.asInt32List();
      case 'int64':
        return buffer.asInt64List();
      case 'uint8':
        return bytes;
      case 'int8':
        return buffer.asInt8List();
    }
    throw ArgumentError.value(dataType, 'dataType', 'not readable as raw tensor memory');
  }

  /// Address of the block, or 0 once freed.
  int get address => _pointer.address;

  /// Frees the block; later calls are no-ops.
  void free() {
    if (_pointer == nullptr) return;
    ffi.malloc.free(_pointer);
    _pointer = nullptr;
  }
}
