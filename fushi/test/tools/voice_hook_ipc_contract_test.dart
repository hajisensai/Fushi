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
    // v15：保留 v14 的 hit/input/frame 查词区，并只追加截图抑制 applied-seq 确认。
    expect(source, contains('constexpr uint32_t kSharedVersion = 15;'));
  });

  test('v15：截图抑制必须 exact-match，且普通帧不能推进 applied ack', () {
    final String header = File(kIpcHeaderPath).readAsStringSync();
    expect(
      header,
      contains(
        'constexpr uint32_t kLookupFrameCaptureSuppress = 0x00000004u;',
      ),
      reason: 'CaptureSuppress 是 wire identity，不能漂移或复用 dismiss/highlight 位',
    );
    expect(
      header,
      contains('volatile uint64_t lookup_frame_applied_seq;'),
      reason: 'v15 必须有 hook→host 的截图抑制完成序，发布帧本身不是渲染屏障',
    );

    final String adapter = File(
      '../native/galgame_hook/hook/adapters/kirikiri_adapter.inc',
    ).readAsStringSync();
    final int presentAt = adapter.indexOf('void PresentKirikiriLookupFrame()');
    final int presentEnd = adapter.indexOf(
      'void DrainKirikiriLookupInput()',
      presentAt,
    );
    expect(
      presentAt,
      greaterThanOrEqualTo(0),
      reason: '扫不到游戏线程帧消费入口',
    );
    expect(presentEnd, greaterThan(presentAt), reason: '扫不到帧消费入口结尾');
    final String presentBody = adapter.substring(presentAt, presentEnd);
    final RegExp exactSuppressBranch = RegExp(
      r'if\s*\(staged\.flags\s*==\s*'
      r'fushi_voice_hook::kLookupFrameCaptureSuppress\s*\)',
    );
    final RegExpMatch? exactSuppressMatch =
        exactSuppressBranch.firstMatch(presentBody);
    expect(
      exactSuppressMatch,
      isNotNull,
      reason: '必须精确匹配 CaptureSuppress；按位命中会让混合/普通帧冒充抑制事务',
    );
    expect(
      presentBody,
      isNot(
        contains(
          'staged.flags & fushi_voice_hook::kLookupFrameCaptureSuppress',
        ),
      ),
      reason: 'CaptureSuppress 不能用 bit-test 识别',
    );

    // 非零 pending ack 只能由上面的 exact 分支排入；普通 present/dismiss/highlight
    // 不得借一个更晚的发布序让 host 误判“popup 已经从游戏窗口消失”。
    final List<RegExpMatch> pendingAssignments = RegExp(
      r'g_lookup_capture_suppress_pending_ack_seq\s*=\s*best_seq\s*;',
    ).allMatches(adapter).toList();
    expect(pendingAssignments, hasLength(1));
    final int exactSuppressAt = presentAt + exactSuppressMatch!.start;
    // CaptureSuppress 分支之后的下一个控制分支。highlight-only 帧在扫描阶段就分流
    // 到 best_highlight（只在没有结构帧时才处理），所以这里的下一道闸是"未知/组合
    // flag 一律 Drop"，不再是当年的 highlight 分支。
    final int nextControlBranchAt = adapter.indexOf(
      'if (staged.flags != 0) {',
      exactSuppressAt,
    );
    expect(nextControlBranchAt, greaterThan(exactSuppressAt));
    expect(pendingAssignments.single.start, greaterThan(exactSuppressAt));
    expect(
      pendingAssignments.single.start,
      lessThan(nextControlBranchAt),
      reason: '只有 exact CaptureSuppress 分支可以排入非零 pending ack',
    );

    final int commitAt = adapter.indexOf(
      'void CommitKirikiriLookupCaptureSuppressAck()',
    );
    final int commitEnd = adapter.indexOf(
      'bool BlitLookupFrameGuarded(',
      commitAt,
    );
    expect(
      commitAt,
      greaterThanOrEqualTo(0),
      reason: '扫不到 applied ack 提交入口',
    );
    expect(commitEnd, greaterThan(commitAt), reason: '扫不到 applied ack 提交入口结尾');
    final List<RegExpMatch> appliedSeqReferences = RegExp(
      r'lookup_frame_applied_seq',
    ).allMatches(adapter).toList();
    expect(appliedSeqReferences, isNotEmpty);
    expect(
      appliedSeqReferences.every(
        (RegExpMatch match) =>
            match.start >= commitAt && match.start < commitEnd,
      ),
      isTrue,
      reason: 'applied seq 只能在专用 commit 中读写；普通帧路径不得碰它',
    );
    final List<RegExpMatch> appliedSeqWrites = RegExp(
      r'WriteKirikiriSharedU64\(\s*'
      r'&g_header->lookup_frame_applied_seq\s*,',
    ).allMatches(adapter).toList();
    expect(
      appliedSeqWrites,
      hasLength(1),
      reason: 'hook→host applied ack 必须只有一个生产写点',
    );
    expect(appliedSeqWrites.single.start, greaterThan(commitAt));
    expect(appliedSeqWrites.single.start, lessThan(commitEnd));

    final int pumpAt = adapter.indexOf('void PumpKirikiriLookup()');
    final int commitCallAt = adapter.indexOf(
      'CommitKirikiriLookupCaptureSuppressAck();',
      pumpAt,
    );
    final int enabledGateAt = adapter.indexOf(
      'const bool enabled_now = LookupEnabledNow() != 0;',
      pumpAt,
    );
    expect(
      pumpAt,
      greaterThanOrEqualTo(0),
      reason: '扫不到 continuous callback 入口',
    );
    expect(commitCallAt, greaterThan(pumpAt));
    expect(
      commitCallAt,
      lessThan(enabledGateAt),
      reason: 'ack 必须跨过下一次 callback，并在禁用/故障 early-return 前提交',
    );
  });

  test('卡片位图预算：Dart 侧镜像常量必须等于契约头', () {
    // 漂了不会报错，只会**静默裁卡片**：Dart 按自己的数排版，runner 按头里的数裁，
    // Dart 的数大一点，超出的部分就被 BGRA 解码链直接切掉。用户看到半张卡，日志里
    // 只有一行 CLAMPED——这正是最难倒推回"两个常量不一致"的那类症状。
    final String header = File(kIpcHeaderPath).readAsStringSync();
    final RegExp headerRe = RegExp(
      r'constexpr uint32_t kLookupBitmapBytes = (\d+)u \* 1024u \* 1024u;',
    );
    final RegExpMatch? headerMatch = headerRe.firstMatch(header);
    expect(headerMatch, isNotNull,
        reason: '扫不到契约头的 kLookupBitmapBytes —— 判红，别让空集假绿');

    final String dart = File(
      'lib/src/lookup/gal_ingame_lookup_controller.dart',
    ).readAsStringSync();
    final RegExp dartRe = RegExp(r'_kCardBitmapBytes = (\d+) \* 1024 \* 1024;');
    final RegExpMatch? dartMatch = dartRe.firstMatch(dart);
    expect(dartMatch, isNotNull, reason: '扫不到 Dart 侧镜像常量 —— 判红');

    expect(dartMatch!.group(1), headerMatch!.group(1),
        reason: '两侧位图预算必须一致（单位 MiB）；改一处就要改另一处');
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

  test('v13：lane_seq 是完成标记，必须 volatile + 原子发布 + 最后写', () {
    // 完成标记是跨进程可见性的分界线。普通写有两个真实风险：编译器把它提到 payload
    // 之前（reader 读到半写槽），x86 上 64 位普通写被拆成两次 32 位写而撕裂。
    // 同文件里 VoiceClip::seq / LoopbackMarker::seq / ThreadPreviewSlot::seq 全是 volatile，
    // lane_seq 没有理由例外。
    final String header = File(kIpcHeaderPath).readAsStringSync();
    expect(header, contains('volatile uint64_t lane_seq;'),
        reason: 'lane_seq 是完成标记，必须 volatile');

    final int writeAt = header.indexOf('inline uint64_t WriteTextLaneEvent(');
    expect(writeAt, greaterThan(0), reason: '扫不到写侧实现 —— 判红，别让空集假绿');
    final int writeEnd = header.indexOf('\n}', writeAt);
    expect(writeEnd, greaterThan(writeAt));
    final String writeBody = header.substring(writeAt, writeEnd);
    final int publishAt =
        writeBody.indexOf('AtomicStorePreview64(&ts->lane_seq');
    expect(publishAt, greaterThan(0),
        reason: 'lane_seq 必须用 Interlocked 发布（全栅栏 + 不可撕裂），不能裸写');
    // 最后写：payload 的任意一处写都必须排在发布之前。取 byte_len 作代表——它决定
    // reader 读多少字节，排在发布之后就是最直接的半写窗口。
    expect(writeBody.indexOf('ts->byte_len = byte_len;'), lessThan(publishAt),
        reason: '完成标记必须是**最后**写，否则 reader 会读到半写槽');

    final int readAt = header.indexOf('inline uint32_t CollectTextSlotsBySeq(');
    expect(readAt, greaterThan(0), reason: '扫不到读侧归并 —— 判红');
    final int readEnd = header.indexOf('\n}', readAt);
    expect(readEnd, greaterThan(readAt));
    expect(header.substring(readAt, readEnd),
        contains('AtomicLoadPreview64(&slot->lane_seq)'),
        reason: '读侧同样不能裸读 64 位标记（x86 会撕裂）');
  });

  test('v13：道用尽必须可降级且可观测，不得静默丢弃', () {
    // 道满的症状与 v13 要根治的 256 槽挤压完全同形；而放开非胜出线程本身抬高了道满
    // 概率。静默丢弃 = 把要修的病换个地方藏起来。
    final String header = File(kIpcHeaderPath).readAsStringSync();
    expect(header, contains('volatile uint64_t text_lane_recycle_count;'));
    expect(header, contains('volatile uint64_t text_lane_overflow_count;'));
    final int writeAt = header.indexOf('inline uint64_t WriteTextLaneEvent(');
    final int writeEnd = header.indexOf('\n}', writeAt);
    final String body = header.substring(writeAt, writeEnd);
    expect(body, contains('text_lane_overflow_count'), reason: '丢弃行必须计数');
    expect(body, contains('text_lane_recycle_count'),
        reason: '回收非选定道必须计数（这是压力的第一级）');
    // 选定线程那条道是配对路径的输入，任何情况下不得被顶掉。
    expect(body, contains('if (lanes[i].thread_id == selected) continue;'),
        reason: '回收时必须跳过选定线程那条道');
  });

  test('v13：采集期不再有任何线程过滤，只挡伪影（挤压已由分道解决）', () {
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

    // hookcode/prefer 不能进入准入函数（旧 profile 快路会绕过用户选择）。
    expect(
      functionBody,
      isNot(contains('preferred_hook_codes')),
    );
    expect(functionBody, isNot(contains('const wchar_t* hookcode')));
    // v13：采集期读选定线程 = 又在采集期丢行，分道之后没有任何理由这么做（丢掉的行
    // 换线程后就再也回不来）。选定线程只允许在消费侧使用。
    expect(
      functionBody,
      isNot(contains('SelectedTextThreadId')),
      reason: '采集期不得再读选定线程；那是消费期的事',
    );
    expect(
      functionBody,
      isNot(contains('AcceptsLine(')),
      reason: '采集期不得再跑选定线程准入判定',
    );
    // 仍然必须挡伪影：它们不是台词，进道只会挤掉本线程自己的真台词。
    expect(functionBody, contains('is_artifact'));
    // face 登记仍要做：消费期按 hook 面放行依赖它（BUG-1159）。
    expect(functionBody, contains('NoteFace(thread_id, face_id)'));
  });

  test('v13：Unity 先写预览，再无条件写自己那条道（不再按选定线程丢行）', () {
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
    expect(body, contains('WriteUnityTextEvent('));
    expect(
      body.indexOf('WriteUnityThreadPreview('),
      lessThan(body.indexOf('WriteUnityTextEvent(')),
      reason: '预览必须先写：它是用户挑线程的唯一依据，不能被任何后续判定拦掉',
    );
    expect(
      body,
      isNot(contains('IsExactTextThreadSelected(')),
      reason: 'v13：非选定组件的台词也要进它自己那条道，否则换组件后追不回来',
    );
    // 仍然只发完整行：半截 TextMesh 快照进道会挤掉本组件自己的真行。
    expect(body, contains('if (!completed_line) return;'));
  });
}
