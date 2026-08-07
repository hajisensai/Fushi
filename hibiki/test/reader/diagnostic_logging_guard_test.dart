import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// 诊断观测守卫（TODO-656 / TODO-630）。
///
/// 这两个问题反复「没修好」，根因是没在真实代码路径上取证就盲改了相邻路径
/// （656 改了滚轮路径，用户真机走触摸 `_bEnd`；630 改了 SRT 书根本不执行的
/// 下游 JS 折叠）。本守卫锁定真机定位用的诊断埋点不被回归删除——它们是下一步
/// 根因修复的证据来源，删掉就又会抓瞎：
/// - `[xchapter]`：连续模式跨章三路径（滚轮/触摸/指针）+ Dart 汇合点，定位
///   「没到章首就跨章」到底走哪条输入、什么几何值触发。
/// - `[sasayaki-hl]`：有声书逐句高亮在 Dart 端的 prepareCues **决策点**留痕。BUG-395
///   前 SRT 书在 `_srtBookUid!=null` 时无条件 return null（绕开 sasayaki 系统），
///   正是这条日志暴露了「SRT 书被匹配进真 EPUB 后 cue 是 sasayaki:// 却建不了
///   range」的真因；BUG-395 已把 SRT/Audiobook 两源判据归一，prepareCues 决策探针
///   保留（标明书源 + cachedSasayaki + payloadLen），仍是「完全没高亮」真机定位的
///   证据来源。
///   BUG-914：audiobook_bridge 播放期**逐 cue 热路径**的 highlight raw= /
///   applySasayakiCues section= 打点属发布版噪声已移除（不再在本守卫断言存在），其
///   「已删且不回归」由 audiobook_probe_removal_guard_test.dart 单独锁定。
void main() {
  group('TODO-656 跨章诊断埋点 [xchapter]', () {
    late String corpus;
    late String paginationScripts;
    setUpAll(() {
      corpus = readReaderPageSource();
      paginationScripts = File('lib/src/reader/reader_pagination_scripts.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
    });

    test('触摸/指针边界手势带 src 标记并打印几何', () {
      expect(paginationScripts, contains('function _bEnd(x, y, src)'),
          reason: '_bEnd 必须带 src 入参以区分 touch/pointer 路径');
      expect(paginationScripts, contains('[xchapter] bEnd src='),
          reason: '触摸/指针跨章判定处必须打印 src + scrollTop 几何');
      expect(paginationScripts, contains("clientY, 'touch')"),
          reason: 'touchend 必须以 src=touch 调用 _bEnd（手机触摸边界手势保留）');
      expect(paginationScripts,
          isNot(contains("_bEnd(e.clientX, e.clientY, 'pointer')")),
          reason: '已砍掉 PC 鼠标(pointer)边界手势跨章：鼠标左键回归原生选字，'
              'PC 桌面跨章只走滚轮，鼠标拖动不再误跨章');
    });

    test('滚轮边界判定与 Dart 汇合点都有诊断', () {
      expect(corpus, contains('[xchapter] wheel '),
          reason: '滚轮边界附近必须打印几何 + armed 状态（对照组）');
      expect(corpus, contains('[xchapter] onBoundarySwipe '),
          reason: '跨章手势 Dart 汇合点必须打印 dir + chapter');
      expect(corpus, contains('[xchapter] handlePageTurnLimit '),
          reason: '跨章真正落子前必须打印 dir + chapter');
    });
  });

  group('TODO-630 有声书高亮诊断埋点 [sentence-audio-hl]', () {
    late String corpus;
    setUpAll(() {
      corpus = readReaderPageSource();
    });

    test('Dart 端 prepareCues 决策有日志（书源 + cachedSentenceAudio + payloadLen 留痕）',
        () {
      expect(corpus, contains('[sentence-audio-hl] prepareCues path='),
          reason:
              'prepareCues 的高亮决策（书源/是否 sentenceAudioHighlight/payload 条数）必须留痕，'
              '是「完全没高亮」真机定位的证据来源（BUG-395）');
      expect(corpus, contains(r'path=$pathTag'),
          reason: 'BUG-395：SRT 与 Audiobook 两源判据归一后，pathTag 仍标明书源以便定位');
      expect(corpus, contains(r'path=$pathTag-SENTENCE-AUDIO'),
          reason: 'sentenceAudioHighlight 书建 payload 的分支必须留痕（含 payloadLen）');
    });

    // BUG-914：audiobook_bridge 播放期逐 cue 热路径的 [sasayaki-hl] highlight raw= /
    // applySasayakiCues section= 打点属发布版噪声已移除；此处不再断言其存在（旧断言会
    // 失败）。「已删且不回归」的守卫移交 audiobook_probe_removal_guard_test.dart，避免两
    // 处守卫对同一事实各执一词。保留的 prepareCues 决策探针仍由上面的用例锁定。
  });
}
