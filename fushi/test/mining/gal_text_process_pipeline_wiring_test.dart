import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';

import '../helpers/source_guard.dart';

/// 文本处理管线接进 galgame hook 链路的**接线**守卫。
///
/// 管线算法本身在 `galgame_text_process_test.dart` 里验；这里只管两件接线事实：
/// ① 管线随每游戏捕获记忆一起落盘 / 读回（[GalCaptureMemory]）；
/// ② 活代码的文本 poll 路径真的在 `appendLine` **之前**跑了管线。
void main() {
  group('GalCaptureMemory 带管线的 JSON 往返', () {
    const GalTextProcessPipeline pipeline = GalTextProcessPipeline(
      steps: <GalTextProcessStep>[
        GalTextProcessStep(
          id: 'dedupeAscending',
          kind: GalTextProcessKind.dedupeAscending,
        ),
        GalTextProcessStep(
          id: 'takeLines',
          kind: GalTextProcessKind.takeLines,
          lineCount: 2,
          fromEnd: true,
        ),
        GalTextProcessStep(
          id: 'replace#2',
          kind: GalTextProcessKind.replace,
          enabled: false,
          pattern: r'\s+',
          replacement: '',
          isRegex: true,
        ),
      ],
    );

    test('管线逐字段往返，与其它记忆项互不干扰', () {
      const GalCaptureMemory memory = GalCaptureMemory(
        excludedTrackFingerprints: <String>['0:44100:2:16:0'],
        voiceTrackFingerprint: '1:22050:1:16:0',
        textThreadFingerprint: 'code:ENGINE:siglus',
        audioFallbackPolicy: GalAudioFallbackPolicy.cleanOnly,
        textProcess: pipeline,
      );

      final GalCaptureMemory restored = GalCaptureMemory.fromJson(
        memory.toJson(),
      );

      expect(restored.textProcess.steps, pipeline.steps);
      expect(
        restored.excludedTrackFingerprints,
        memory.excludedTrackFingerprints,
      );
      expect(restored.voiceTrackFingerprint, memory.voiceTrackFingerprint);
      expect(restored.textThreadFingerprint, memory.textThreadFingerprint);
      expect(restored.audioFallbackPolicy, memory.audioFallbackPolicy);
    });

    test('管线是可执行的真值，不只是一份存档结构', () {
      final GalCaptureMemory restored = GalCaptureMemory.fromJson(
        const GalCaptureMemory(textProcess: pipeline).toJson(),
      );
      // 第一步吃掉逐字重绘；第三步是 disabled 的空白替换，不许生效。
      expect(restored.textProcess.apply('AA BAB CAB CD'), 'AA BAB CAB CD');
      expect(restored.textProcess.apply('AABABCABCD'), 'ABCD');
    });

    test('空管线不写进 JSON（保持「空值不写」的记忆风格）', () {
      const GalCaptureMemory memory = GalCaptureMemory();
      expect(memory.toJson().containsKey('textProcess'), isFalse);
      expect(memory.isEmpty, isTrue);
    });

    test('步骤全部 disabled 仍然写出——禁用不是删除', () {
      const GalCaptureMemory memory = GalCaptureMemory(
        textProcess: GalTextProcessPipeline(
          steps: <GalTextProcessStep>[
            GalTextProcessStep(
              id: 'stripCurlyBraces',
              kind: GalTextProcessKind.stripCurlyBraces,
              enabled: false,
            ),
          ],
        ),
      );
      expect(
        memory.toJson().containsKey('textProcess'),
        isTrue,
        reason: '按 isEmpty 判空会让用户「临时全禁用一次」= 规则被磁盘悄悄删光',
      );
      expect(memory.isEmpty, isFalse);
      expect(
        GalCaptureMemory.fromJson(
          memory.toJson(),
        ).textProcess.steps.single.enabled,
        isFalse,
      );
    });

    test('缺字段 / 脏值退回空管线而不是抛', () {
      expect(
        GalCaptureMemory.fromJson(const <Object?, Object?>{}).textProcess.steps,
        isEmpty,
      );
      expect(
        GalCaptureMemory.fromJson(const <Object?, Object?>{
          'textProcess': 'not-a-list',
        }).textProcess.steps,
        isEmpty,
      );
    });
  });

  // 回归守卫：活代码的文本 poll 路径（GalHookSessionController._pollHookedText）必须在
  // appendLine **之前**跑管线。顺序不是风格问题——注音剥离（parseRubyMarkup）与渐进
  // 折叠都在 appendLine 内部按入参文本建坐标系，管线挪到之后会让 rubySpans 的下标落在
  // 一份已经不存在的文本上，振假名整片错位。与 galgame_system_ui_filter_test.dart 的
  // 「过滤器真的接上了」守卫同款做法。
  test('GalHookSessionController 的 poll 路径在 appendLine 之前跑文本处理管线', () {
    final File controller = File(
      'lib/src/mining/gal_hook_session_controller.dart',
    );
    expect(
      controller.existsSync(),
      isTrue,
      reason: '找不到 gal_hook_session_controller.dart，路径变更请更新本守卫',
    );
    // 注释掩成等长空白：否则「同文字的注释」能把断言骗绿，下标也仍可回原串切片。
    final String src = maskComments(controller.readAsStringSync());

    final int pollAt = src.indexOf('Future<void> _pollHookedText() async {');
    expect(
      pollAt,
      greaterThanOrEqualTo(0),
      reason: '_pollHookedText 改名了，请更新本守卫',
    );
    final String poll = src.substring(pollAt);

    final int processAt = poll.indexOf('_processSelectedThreadText(line.text)');
    final int appendAt = poll.indexOf('_textService.appendLine(');
    final int acceptsAt = poll.indexOf('_acceptsLineFromSelectedThread(line)');

    expect(
      processAt,
      greaterThanOrEqualTo(0),
      reason: 'poll 路径必须对所选线程的行套用 _processSelectedThreadText',
    );
    expect(appendAt, greaterThanOrEqualTo(0));
    expect(acceptsAt, greaterThanOrEqualTo(0));
    expect(
      processAt,
      lessThan(appendAt),
      reason: '管线必须在 appendLine 之前跑，否则注音 span 的下标会错位',
    );
    expect(
      acceptsAt,
      lessThan(processAt),
      reason: '管线只作用于已通过线程判据的行——线程目录/预览要看引擎原样吐出来的串',
    );
  });

  test('管线处理成空的行整行丢弃，与系统 UI 行同样处置', () {
    final String src = maskComments(
      File(
        'lib/src/mining/gal_hook_session_controller.dart',
      ).readAsStringSync(),
    );
    final int helperAt = src.indexOf(
      'String? _processSelectedThreadText(String text) {',
    );
    expect(helperAt, greaterThanOrEqualTo(0));
    final String body = src.substring(helperAt, helperAt + 400);
    expect(
      compactCode(body).contains('if(pipeline.isEmpty)returntext;'),
      isTrue,
      reason: '空管线必须在第一行短路：这是每条 hook 行都要过的热路径',
    );
    expect(
      compactCode(body).contains('processed.trim().isEmpty?null:processed'),
      isTrue,
      reason: '处理后为空 = 这一行被管线丢掉，调用方据 null 整行丢弃',
    );
  });
}
