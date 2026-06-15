import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-300 source guard：有声书文字跟随高亮在阅读器里不显示，根因是 reader 的
/// `_prepareSasayakiCuesJson` 手写内联循环构造给 JS 的 sasayaki cue payload 时
/// 漏了 cue 原文 `text` 字段 —— JS `collectSasayakiCueRanges`（BUG-060 改造）必须
/// 用 `cue.text` 在实时 DOM 里就近重定位高亮，缺 text 时只能按错位的提示偏移回落，
/// 高亮落空。修复改为直接复用 `AudiobookBridge.buildSasayakiPayload`（必含 text），
/// 与有声书桥接路径共用同一份 payload 契约。
///
/// 行为驱动需要真 InAppWebView + 平台视图（headless 不可用），故此处锁定调用点
/// 不变量：① reader 路径复用 buildSasayakiPayload；② buildSasayakiPayload 必含
/// `'text': cue.text`。撤修复（退回手写漏 text 的内联 payload）会让本守卫转红。
void main() {
  final String readerSrc =
      File('lib/src/pages/implementations/reader_hibiki_page.dart')
          .readAsStringSync();
  final String bridgeSrc =
      File('lib/src/media/audiobook/audiobook_bridge.dart').readAsStringSync();

  /// 截取 _prepareSasayakiCuesJson 方法体：从其签名到下一个方法
  /// _injectAudiobookBridge 之前（reader 文件里这两个方法相邻）。
  final int prepStart =
      readerSrc.indexOf('Future<String?> _prepareSasayakiCuesJson() async {');
  final int injectStart =
      readerSrc.indexOf('Future<void> _injectAudiobookBridge() async {');

  test('方法边界可定位（防止守卫因重命名而失效）', () {
    expect(prepStart, greaterThanOrEqualTo(0));
    expect(injectStart, greaterThan(prepStart));
  });

  test('_prepareSasayakiCuesJson 复用 buildSasayakiPayload（含 text 的契约）', () {
    final String body = readerSrc.substring(prepStart, injectStart);
    expect(
      body.contains('AudiobookBridge.buildSasayakiPayload('),
      isTrue,
      reason: 'reader 必须复用 buildSasayakiPayload，确保 payload 带 cue 原文 text',
    );
  });

  test('_prepareSasayakiCuesJson 不再手写内联 payload map（会漏 text）', () {
    final String body = readerSrc.substring(prepStart, injectStart);
    expect(
      body.contains('payload.add(<String, dynamic>{'),
      isFalse,
      reason: '手写内联 payload 历史上漏了 text 字段（BUG-300），必须复用纯函数',
    );
  });

  test('buildSasayakiPayload 的 payload 契约必含 cue 原文 text', () {
    final int start = bridgeSrc
        .indexOf('static List<Map<String, dynamic>> buildSasayakiPayload(');
    expect(start, greaterThanOrEqualTo(0));
    final String body = bridgeSrc.substring(start);
    expect(
      body.contains("'text': cue.text"),
      isTrue,
      reason:
          'JS collectSasayakiCueRanges 靠 cue.text 在实时 DOM 重定位高亮（BUG-060/300）',
    );
  });
  group('BUG-300 机制验证：缺 text(needle 空) 无法定位高亮', () {
    // ReaderPaginationScripts.resolveCueNormStartsForTesting 是 JS
    // collectSasayakiCueRanges 定位算法的纯 Dart 影子（同算法）。这里端到端验证
    // BUG-300 根因：reader payload 缺 cue 原文 text 时，JS needle 为空 → 无法在
    // 实时 DOM 就近重定位，只能落到「匹配坐标系」的错位提示偏移；带 text 时能
    // 自愈到真实渲染位置。两坐标系前部相差 2 字（ＸＹ），提示仍说旧偏移。
    const String domFull = 'ＸＹあいうえおかきくけこさしすせそ'; // 真实「かきくけこ」在 7

    test('带 text(needle 非空)：自愈到真实 DOM 位置 7（高亮落对）', () {
      final List<int> out =
          ReaderPaginationScripts.resolveCueNormStartsForTesting(
        fullNorm: domFull,
        cues: const <SasayakiCueHint>[
          SasayakiCueHint(needle: 'かきくけこ', hint: 5, length: 5),
        ],
      );
      expect(out.single, 7, reason: '带 cue 原文 needle 时按实时 DOM 重定位到真实位置 7');
    });

    test('缺 text(needle 空)：只能落到错位提示偏移 5（高亮落错/落空）', () {
      final List<int> out =
          ReaderPaginationScripts.resolveCueNormStartsForTesting(
        fullNorm: domFull,
        cues: const <SasayakiCueHint>[
          // 模拟 reader 旧 payload：无 text → needle 空，仅有 start 提示 5。
          SasayakiCueHint(needle: '', hint: 5, length: 5),
        ],
      );
      expect(out.single, 5, reason: 'needle 空时无法重定位，落到错位提示 5 ≠ 真实 7，即高亮错位/落空');
      expect(out.single == 7, isFalse, reason: 'BUG-300：缺 text 永远到不了真实渲染位置');
    });
  });
}
