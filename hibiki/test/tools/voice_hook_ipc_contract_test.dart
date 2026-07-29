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

  test('host and native share the v12 thread preview seqlock contract', () {
    final String hostHeader = File(
      'windows/runner/voice_hook_ipc.h',
    ).readAsStringSync();
    final String nativeHeader = File(
      '../native/galgame_hook/include/voice_hook_ipc.h',
    ).readAsStringSync();
    final String sharedHeader = File(
      '../native/galgame_hook/include/thread_preview_ipc.h',
    ).readAsStringSync();
    final String reader = File(
      'windows/runner/voice_hook_reader.cpp',
    ).readAsStringSync();

    // 布局只定义一次，host 直接包含 native 共用头，避免镜像漂移和重复代码。
    expect(
      hostHeader,
      contains(
        '#include "../../../native/galgame_hook/include/thread_preview_ipc.h"',
      ),
    );
    expect(nativeHeader, contains('#include "thread_preview_ipc.h"'));
    expect(
      sharedHeader,
      contains('constexpr uint32_t kThreadPreviewCount = 64;'),
    );
    expect(
      sharedHeader,
      contains('constexpr uint32_t kThreadPreviewTextChars = 192;'),
    );
    expect(
      sharedHeader,
      contains(
        'constexpr uint32_t kThreadPreviewFlagArtifact = 0x00000001u;',
      ),
    );
    expect(sharedHeader, contains('struct ThreadPreviewSlot {'));
    expect(hostHeader, contains('uint32_t thread_preview_offset;'));
    expect(hostHeader, contains('uint32_t thread_preview_slot_count;'));
    expect(
      hostHeader,
      contains('volatile uint64_t thread_preview_write_count;'),
    );
    // 预览槽必须带不受门控影响的行计数，否则跨会话记忆恢复没有消歧依据。
    expect(sharedHeader, contains('uint64_t line_count;'));
    expect(sharedHeader, contains('uint64_t artifact_count;'));
    expect(
      sharedHeader,
      contains(
        'static_assert(offsetof(ThreadPreviewSlot, seq) == 0,',
      ),
    );
    // reader 只发布 odd/even 原子双读后的稳定快照，write_count 同样不能在 x86 裸读。
    expect(reader, contains('TryReadThreadPreviewSnapshot(slot, &snapshot)'));
    expect(reader, contains('AtomicLoadPreview64('));
  });
}
