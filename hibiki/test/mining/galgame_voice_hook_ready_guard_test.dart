import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('voice hook signals IPC readiness before installing engine hooks', () {
    final File sourceFile =
        File('../native/galgame_voice_hook/hook/dll_main.cpp');
    expect(
      sourceFile.existsSync(),
      isTrue,
      reason: 'native galgame voice-hook source must be available',
    );

    final String worker = _functionSource(
      sourceFile.readAsStringSync(),
      'DWORD WINAPI HookWorker(LPVOID)',
      '}  // namespace',
    );
    final int contractIndex = worker.indexOf(
      'g_header->version == kSharedVersion',
    );
    final int hookedIndex = worker.indexOf('g_header->hooked = 1;');
    final int readyIndex = worker.indexOf('SignalReady(pid)');
    final int minHookIndex = worker.indexOf('MH_Initialize()');

    expect(contractIndex, isNonNegative);
    expect(hookedIndex, greaterThan(contractIndex));
    expect(readyIndex, greaterThan(hookedIndex));
    expect(
      readyIndex,
      lessThan(minHookIndex),
      reason: 'proof-of-life must not wait for potentially blocking hooks',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
