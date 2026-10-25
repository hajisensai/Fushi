// Standalone JIT program for as_typed_list_deopt_canary_test.dart (run with the
// SDK's `dart`, not inside flutter_tester: the raw mode kills the process).
//
// Shape of fushi_compute's Utf16BatchBuffer.fill, where the crash was found:
// fill() gets optimized, the `lens` view is used only by index after the inner
// loop, so its allocation is sunk; alternating inputs make the inner loop
// deoptimize while the view is live. On Dart 3.13.5 / 3.15.0-57.0.dev the
// materialized view's data pointer is wrong and `lenView[i] = …` faults.
//
//   dart deopt_fill.dart raw        -> crashes while the VM bug exists
//   dart deopt_fill.dart outOfLine  -> prints "ok"
import 'dart:collection';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

final Pointer<Uint16> _units = malloc<Uint16>(4096);
final Pointer<Uint32> _lens = malloc<Uint32>(4096);

@pragma('vm:never-inline')
void fillRaw(List<String> values) {
  int total = 0;
  for (final String value in values) {
    total += value.length;
  }
  final Uint16List unitView = _units.asTypedList(total);
  final Uint32List lenView = _lens.asTypedList(values.length);
  int offset = 0;
  for (int i = 0; i < values.length; i++) {
    final String value = values[i];
    final int length = value.length;
    for (int j = 0; j < length; j++) {
      unitView[offset + j] = value.codeUnitAt(j);
    }
    lenView[i] = length;
    offset += length;
  }
}

@pragma('vm:never-inline')
void fillOutOfLine(List<String> values) {
  int total = 0;
  for (final String value in values) {
    total += value.length;
  }
  final Uint16List unitView = _units.asTypedListOutOfLine(total);
  final Uint32List lenView = _lens.asTypedListOutOfLine(values.length);
  int offset = 0;
  for (int i = 0; i < values.length; i++) {
    final String value = values[i];
    final int length = value.length;
    for (int j = 0; j < length; j++) {
      unitView[offset + j] = value.codeUnitAt(j);
    }
    lenView[i] = length;
    offset += length;
  }
}

void main(List<String> args) {
  final void Function(List<String>) fill = args.first == 'raw'
      ? fillRaw
      : fillOutOfLine;
  final List<List<String>> inputs = <List<String>>[
    <String>[''],
    UnmodifiableListView<String>(<String>['葬送のフリーレン', '03']),
  ];
  for (int i = 0; i < 400000; i++) {
    final List<String> values = inputs[i % 2];
    fill(values);
    for (int k = 0; k < values.length; k++) {
      if (_lens[k] != values[k].length) {
        throw StateError('iteration $i: lens[$k] = ${_lens[k]}');
      }
    }
  }
  print('ok');
}
