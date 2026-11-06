import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';
import 'package:test/test.dart';

void main() {
  test('every element type views the same native memory as asTypedList', () {
    final Pointer<Uint8> block = calloc<Uint8>(64);
    addTearDown(() => calloc.free(block));
    final int address = block.address;

    void sameMemory(TypedData view, int elementSize) {
      expect(view.lengthInBytes, 4 * elementSize);
    }

    sameMemory(block.cast<Int8>().asTypedListOutOfLine(4), 1);
    sameMemory(block.cast<Int16>().asTypedListOutOfLine(4), 2);
    sameMemory(block.cast<Int32>().asTypedListOutOfLine(4), 4);
    sameMemory(block.cast<Int64>().asTypedListOutOfLine(4), 8);
    sameMemory(block.asTypedListOutOfLine(4), 1);
    sameMemory(block.cast<Uint16>().asTypedListOutOfLine(4), 2);
    sameMemory(block.cast<Uint32>().asTypedListOutOfLine(4), 4);
    sameMemory(block.cast<Uint64>().asTypedListOutOfLine(4), 8);
    sameMemory(block.cast<Float>().asTypedListOutOfLine(4), 4);
    sameMemory(block.cast<Double>().asTypedListOutOfLine(4), 8);

    // Writes through the view land in the pointer's memory and vice versa.
    final Uint32List u32 = block.cast<Uint32>().asTypedListOutOfLine(4);
    u32[1] = 0xdeadbeef;
    expect(block.cast<Uint32>()[1], 0xdeadbeef);
    block.cast<Int64>()[3] = -7;
    expect(block.cast<Int64>().asTypedListOutOfLine(4)[3], -7);
    final Float64List f64 = block.cast<Double>().asTypedListOutOfLine(4);
    f64[0] = 1.5;
    expect(block.cast<Double>().value, 1.5);
    expect(block.address, address);
  });
}
