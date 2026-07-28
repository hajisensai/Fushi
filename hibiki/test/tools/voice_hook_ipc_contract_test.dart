import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host recognizes generic resource-audio readiness', () {
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
    expect(
      source,
      contains(
        'constexpr uint32_t kDiagVisualArtsOvkHooksReady = 0x00040000u;',
      ),
    );
    expect(
      source,
      contains(
        '(hook_diagnostics & kDiagVisualArtsOvkHooksReady) != 0',
      ),
    );
    expect(source, contains('constexpr uint32_t kSharedVersion = 12;'));
  });

  test('host mirrors the v12 thread preview region contract', () {
    final String source = File(
      'windows/runner/voice_hook_ipc.h',
    ).readAsStringSync();

    // 预览区的三个常量与 header 字段必须与 native 真相源同步；漏一个就会读到错位内存。
    expect(source, contains('constexpr uint32_t kThreadPreviewCount = 64;'));
    expect(
      source,
      contains('constexpr uint32_t kThreadPreviewTextChars = 192;'),
    );
    expect(
      source,
      contains(
        'constexpr uint32_t kThreadPreviewFlagArtifact = 0x00000001u;',
      ),
    );
    expect(source, contains('struct ThreadPreviewSlot {'));
    expect(source, contains('uint32_t thread_preview_offset;'));
    expect(source, contains('uint32_t thread_preview_slot_count;'));
    expect(
      source,
      contains('volatile uint64_t thread_preview_write_count;'),
    );
    // 预览槽必须带不受门控影响的行计数，否则跨会话记忆恢复没有消歧依据。
    expect(source, contains('uint64_t line_count;'));
    expect(source, contains('uint64_t artifact_count;'));
    expect(
      source,
      contains(
        'static_assert(sizeof(ThreadPreviewSlot) % 8 == 0,',
      ),
    );
  });
}
