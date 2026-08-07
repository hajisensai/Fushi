import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-1321：字幕对齐文本与 EPUB 真实选区不一致（ruby/措辞/空白差异，长选区几乎必现）
/// 时，`_buildAudiobookClipPlan` 曾直接丢弃整个计划——连同**整段音频窗**一起丢。静态
/// 回退于是退回 currentSentence 单句锚，产出「全文卡片 + 只有第一句声音」。
///
/// 修复契约（结构守卫，锚在真实源码上）：
/// ① 计划构建器在文本不一致时**保留计划**（带 cueTextMatches=false），不再 return null；
/// ② 调度方在 exportable 分支据 cueTextMatches=false 仅禁用逐句高亮（dynamicPlan=null），
///    此时整段窗口已通过 sentenceRange 进入静态裁剪范围；
/// ③ BUG-968 契约不变：不一致时绝不渲染字幕文本（静态精确选区卡）。
void main() {
  late String part;

  /// 与 audiobook_clip_export_logging_guard_test 同款函数体截取器。
  String fnBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0),
        reason: '函数 $signature 必须存在（结构守卫锚点）。');
    int i = start + signature.length - 1;
    expect(src[i], '(', reason: 'signature 必须以 "(" 结尾。');
    int paren = 0;
    for (; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '(') paren++;
      if (ch == ')') {
        paren--;
        if (paren == 0) break;
      }
    }
    final int bodyStart = src.indexOf('{', i);
    expect(bodyStart, greaterThanOrEqualTo(0));
    int depth = 0;
    for (i = bodyStart; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return src.substring(bodyStart, i + 1);
      }
    }
    fail('函数 $signature 大括号不配平。');
  }

  setUpAll(() {
    part = File(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('plan builder keeps the plan (and its audio window) on text mismatch',
      () {
    // BUG-1320：构造器改成返回 (plan, range) 记录后签名不再以 `(` 结尾，改用共享
    // methodBody（它会跳过命名参数表）；`_buildAudiobookClipPlan({` 只匹配定义，
    // 调用点是 `_buildAudiobookClipPlan(audioFileCount:`，不会撞。
    final String body = methodBody(part, '_buildAudiobookClipPlan({');
    final int matchAt = body.indexOf('audiobookClipCueTextMatchesSelection(');
    expect(matchAt, greaterThanOrEqualTo(0), reason: 'BUG-968 的一致性判定必须保留');
    // 一致性判定之后不得再出现 return null：不一致只降级高亮，绝不丢整段音频窗。
    final String afterMatch = body.substring(matchAt);
    expect(afterMatch.contains('return null;'), isFalse,
        reason: '文本不一致时丢弃整个计划会把长选区音频塌缩成单句（BUG-1321 根因）');
    // 判定结果必须作为 cueTextMatches 进入计划。
    expect(afterMatch, contains('cueTextMatches: cueTextMatches'));
  });

  test('dispatcher only disables highlight on mismatch, keeps the full window',
      () {
    final String body = fnBody(part, 'void _exportAudiobookClip(');
    // 门必须真实读取 cueTextMatches 并置空 dynamicPlan（静态精确选区卡），
    // 且发生在 exportable 分支内（sentenceRange 已从计划取整段窗口）。
    final RegExp gate = RegExp(
      r'if \(dynamicPlan != null &&\s*!dynamicPlan\.cueTextMatches\)',
    );
    final Match? gateMatch = gate.firstMatch(body);
    expect(gateMatch, isNotNull, reason: '不一致时必须显式禁用逐句高亮（BUG-968 契约），而非丢弃音频窗');
    final int nullAfterGate =
        body.indexOf('dynamicPlan = null;', gateMatch!.start);
    expect(nullAfterGate, greaterThan(gateMatch.start));
    // 窗口来源不回退：sentenceRange 必须取计划算出的整段窗口，只有计划**真的没窗口**
    // 时才回落单句锚。BUG-1320 之后窗口由 clipPlan.range 直接给出（超上限时 plan 为空
    // 但窗口仍有效），不再从 dynamicPlan.global* 反推。
    expect(
      containsCodeLine(body, 'clipPlan.range ?? _currentSentenceAudioRange()'),
      isTrue,
      reason: 'BUG-1321/BUG-1320：整段窗口必须来自多句计划；无条件回落单句锚会把长选区'
          '音频塌缩成一句，或把「太长」洗成「可导出」',
    );
  });

  test('plan model carries the cueTextMatches contract field', () {
    final int classAt = part.indexOf('class _AudiobookClipDynamicPlan {');
    expect(classAt, greaterThanOrEqualTo(0));
    final String classBody = part.substring(
        classAt,
        part.indexOf(
            '}',
            part.indexOf(
                'final List<List<Uint8List>> imagesByCueIndex;', classAt)));
    expect(classBody, contains('final bool cueTextMatches;'));
  });
}
