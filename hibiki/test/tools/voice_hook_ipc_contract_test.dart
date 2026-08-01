import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 契约头的唯一真相源。host 读侧曾有一份手抄副本（`windows/runner/voice_hook_ipc.h`），
/// 本文件当时就是对着副本断言的——而副本的 `HasReadyGameResourceAudio` 漏掉了 Tyrano /
/// BGI / Artemis / CatSystem2 / Malie 五个引擎的 ready 位，本测试却绿着：断言只手点了
/// ffmpeg 与 VisualArts 两条，漏的那五条不在名单里。副本已删（host 直接编真相源），
/// 断言也一并搬到真相源，并把丢过的五条补进名单。
const String kIpcHeaderPath = '../native/galgame_hook/include/voice_hook_ipc.h';

void main() {
  test('资源音频就绪判据覆盖每个有资源 hook 的引擎（含副本漏掉的五个）', () {
    final String source = File(kIpcHeaderPath).readAsStringSync();
    final int at = source.indexOf('bool HasReadyGameResourceAudio(');
    expect(at, greaterThan(0), reason: '扫不到就绪判据函数 —— 判红，别让空集假绿');
    final int end = source.indexOf('\n}', at);
    expect(end, greaterThan(at), reason: '扫不到函数体结尾 —— 判红');
    final String body = source.substring(at, end);

    // 少一条 = 该引擎资源 hook 装好了，host 仍判「没有逐句语音」→ 退回整机混音。
    for (final String bit in <String>[
      'kDiagKirikiriVoiceStreamHookReady',
      'kDiagSiglusOvkHooksReady',
      'kDiagFfmpegResourceHooksReady',
      'kDiagVisualArtsOvkHooksReady',
      'kDiagTyranoAsarHooksReady',
      'kDiagBgiArcHooksReady',
      'kDiagArtemisPfsHooksReady',
      'kDiagCatSystem2PcmHooksReady',
      'kDiagMalieLibpHooksReady',
      'kDiagUnityResourceExtractorReady',
    ]) {
      expect(body, contains(bit), reason: '$bit 不在资源音频就绪判据里');
      expect(source, contains('constexpr uint32_t $bit ='),
          reason: '$bit 没在契约头里定义');
    }
    expect(source, contains('constexpr uint32_t kSharedVersion = 12;'));
  });

  test('host and native share the v12 thread preview seqlock contract', () {
    final String nativeHeader = File(kIpcHeaderPath).readAsStringSync();
    final String sharedHeader = File(
      '../native/galgame_hook/include/thread_preview_ipc.h',
    ).readAsStringSync();
    final String reader = File(
      'windows/runner/voice_hook_reader.cpp',
    ).readAsStringSync();

    // 布局只定义一次：契约头自己包含预览区共用头，host 读侧直接编这份契约头
    // （host 不得再有副本，守卫见 test/mining/gal_ipc_contract_single_source_test.dart）。
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
      contains('constexpr uint32_t kLunaThreadPreviewCount = 48;'),
    );
    expect(
      sharedHeader,
      contains(
        'constexpr uint32_t kNativeThreadPreviewStart = kLunaThreadPreviewCount;',
      ),
    );
    expect(
      sharedHeader,
      contains(
        'constexpr uint32_t kThreadPreviewFlagArtifact = 0x00000001u;',
      ),
    );
    expect(sharedHeader, contains('struct ThreadPreviewSlot {'));
    expect(nativeHeader, contains('uint32_t thread_preview_offset;'));
    expect(nativeHeader, contains('uint32_t thread_preview_slot_count;'));
    expect(
      nativeHeader,
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
    expect(
      sharedHeader,
      contains('inline void PublishThreadPreviewChange('),
    );
  });

  test('native profile prefer cannot bypass v12 explicit thread selection', () {
    final String injector = File(
      '../native/galgame_hook/injector/injector_main.cpp',
    ).readAsStringSync();
    final int functionStart = injector.indexOf('bool LunaShouldWriteLine(');
    final int functionEnd = injector.indexOf(
      '\n}\n\n// ── Luna_Start',
      functionStart,
    );
    expect(functionStart, greaterThanOrEqualTo(0));
    expect(functionEnd, greaterThan(functionStart));
    final String functionBody = injector.substring(functionStart, functionEnd);

    // hookcode/prefer 不能再进入准入函数；唯一真值必须是共享内存里的显式 thread id。
    expect(
      functionBody,
      isNot(contains('preferred_hook_codes')),
    );
    expect(functionBody, isNot(contains('const wchar_t* hookcode')));
    expect(functionBody, contains('SelectedTextThreadId(g_luna.header)'));
    expect(
      functionBody,
      contains(
        'AcceptsLine(\n      thread_id, is_artifact, manually_selected, face_id)',
      ),
    );
  });

  test('Unity native text uses preview first and the same explicit gate', () {
    final String source = File(
      '../native/galgame_hook/hook/adapters/unity_adapter.inc',
    ).readAsStringSync();
    final int functionStart = source.indexOf('void PublishUnityText(');
    final int functionEnd = source.indexOf(
      '\n}\n\nvoid RecordUnityTmpText',
      functionStart,
    );
    expect(functionStart, greaterThanOrEqualTo(0));
    expect(functionEnd, greaterThan(functionStart));
    final String body = source.substring(functionStart, functionEnd);

    expect(body, contains('WriteUnityThreadPreview('));
    expect(body, contains('IsExactTextThreadSelected(g_header, thread_id)'));
    expect(
      body.indexOf('WriteUnityThreadPreview('),
      lessThan(body.indexOf('IsExactTextThreadSelected(')),
    );
    expect(
      body.indexOf('IsExactTextThreadSelected('),
      lessThan(body.indexOf('WriteUnityTextEvent(')),
    );
  });
}
