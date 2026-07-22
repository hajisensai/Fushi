import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host recognizes generic FFmpeg resource-audio readiness', () {
    final String source = File(
      'windows/runner/voice_hook_ipc.h',
    ).readAsStringSync();

    expect(
      source,
      contains(
        'constexpr uint32_t kDiagFfmpegResourceHooksReady = 0x00010000u;',
      ),
    );
    expect(
      source,
      contains(
        '(hook_diagnostics & kDiagFfmpegResourceHooksReady) != 0',
      ),
    );
    expect(source, contains('constexpr uint32_t kSharedVersion = 11;'));
  });
}
