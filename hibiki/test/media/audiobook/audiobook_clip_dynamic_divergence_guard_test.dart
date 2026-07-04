import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1115 review 守卫：动态导出（多句连读 + 逐句高亮）的两处硬化。
///
/// M1（audioFileIndex 分歧回退）：音频裁剪走静态 `range`（由 range.audioFileIndex 选
/// inputFile），起止 ms 却走 dynamicPlan.globalStartMs/globalEndMs（由 span 独立解析出的
/// dynamicPlan.audioFileIndex 定的坐标系）。二者理论可分歧；一旦 dynamicPlan.audioFileIndex
/// != range.audioFileIndex，就会拿 A 文件的 ms 偏移去裁 B 文件 → 错音频 + 错高亮。护栏：
/// 分歧则放弃动态、令 dynamicPlan=null，回退单句静态（运行时判据，不用 release 会被剥的
/// assert）。
///
/// M2（分类文本同源）：动态侧 [classifyAudiobookClipMultiCue] 的 selectedText 必须与静态
/// 路径 [_exportAudiobookClip] 的 selectedText 同源——`_cachedSelectionRange?.text ??
/// currentSentence.text`；此前动态侧只用 currentSentence.text，两条 emptySelection 判据
/// 不同调。span 主锚（_cachedSentenceRange.offset/length）保持不变。
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  /// 复用 logging-guard 的函数体截取器：按 [signature]（函数名 + 起始 '('）先配平圆括号
  /// 跳过参数列表，再从其后第一个 '{' 起配平大括号截出函数体。
  String fnBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0),
        reason: '函数 $signature 必须存在（结构守卫锚点）。');
    int i = start + signature.length - 1; // 指向起始 '('
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
    expect(bodyStart, greaterThanOrEqualTo(0),
        reason: '函数 $signature 参数列表后必须有函数体 "{"。');
    int depth = 0;
    for (i = bodyStart; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return src.substring(bodyStart, i + 1);
      }
    }
    fail('函数 $signature 大括号不配平，无法截出函数体。');
  }

  late String audiobookPart;

  setUpAll(() {
    audiobookPart = libFile(
      'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
    );
  });

  group('M1: dynamic/static audioFileIndex divergence guard', () {
    test(
        'dispatcher compares dynamicPlan.audioFileIndex to range.audioFileIndex',
        () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      // 必须存在「dynamicPlan.audioFileIndex != range.audioFileIndex」判据。
      // 容忍 dart format 换行/空白。
      final RegExp cmp = RegExp(
        r'dynamicPlan\.audioFileIndex\s*!=\s*range\.audioFileIndex',
      );
      expect(cmp.hasMatch(body), isTrue,
          reason: 'M1：分歧护栏必须比较 dynamicPlan.audioFileIndex != '
              'range.audioFileIndex（否则会拿 A 文件 ms 去裁 B 文件）。');
    });

    test('divergence path drops the dynamic plan (dynamicPlan = null)', () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      // 分歧时把 dynamicPlan 置 null → 回退单句静态。要求 dynamicPlan 是可变局部
      // （非 final）且有一处赋 null。
      expect(body.contains('dynamicPlan = null;'), isTrue,
          reason: 'M1：分歧时必须令 dynamicPlan = null 回退单句静态。');
      expect(body.contains('final _AudiobookClipDynamicPlan? dynamicPlan ='),
          isFalse,
          reason: 'M1：dynamicPlan 必须是可变局部（否则无法在分歧时置 null）。');
    });

    test('divergence path logs the fallback reason (no assert)', () {
      final String body = fnBody(audiobookPart, 'void _exportAudiobookClip(');
      expect(body, contains('ReaderHibiki.exportClip.audioFileIndexDivergence'),
          reason: 'M1：分歧回退必须记 ErrorLogService（release 会剥 assert）。');
      // 明确不用 assert 作为护栏（release 会被剥）。
      expect(body.contains('assert(dynamicPlan'), isFalse,
          reason: 'M1：不得用 assert 做分歧护栏（release 剥除）。');
    });
  });

  group('M2: dynamic classify text shares single source with static path', () {
    test(
        '_buildAudiobookClipPlan classify text = _cachedSelectionRange?.text ?? sentence',
        () {
      final String body = fnBody(
          audiobookPart, '_AudiobookClipDynamicPlan? _buildAudiobookClipPlan(');
      // 分类文本必须取同源。允许命名局部 classifyText，或直接内联表达式。
      final RegExp source = RegExp(
        r'_cachedSelectionRange\?\.text\s*\?\?\s*sentence',
      );
      expect(source.hasMatch(body), isTrue,
          reason: 'M2：动态分类文本必须与静态路径同源 '
              '(_cachedSelectionRange?.text ?? currentSentence.text)。');
      // classify 调用的 selectedText 不得再直接绑 currentSentence 文本变量 sentence。
      expect(body.contains('selectedText: sentence,'), isFalse,
          reason: 'M2：classifyAudiobookClipMultiCue 的 selectedText 不得只用 '
              'currentSentence.text（两条 emptySelection 判据会不同调）。');
    });

    test('span anchor stays on currentSentence.text + norm offset/length', () {
      final String body = fnBody(
          audiobookPart, '_AudiobookClipDynamicPlan? _buildAudiobookClipPlan(');
      // span 主锚不变：miningSentenceCueSpan 仍喂 sentence + _cachedSentenceRange。
      expect(body.contains('sentence: sentence,'), isTrue,
          reason: 'M2：span 主锚必须仍用整句文本（sentence），不能被选区文本替换。');
      expect(body,
          contains('sentenceNormCharOffset: _cachedSentenceRange?.offset'),
          reason: 'M2：span 主锚的归一化 offset 必须保持不变。');
      expect(body,
          contains('sentenceNormCharLength: _cachedSentenceRange?.length'),
          reason: 'M2：span 主锚的归一化 length 必须保持不变。');
    });
  });
}
