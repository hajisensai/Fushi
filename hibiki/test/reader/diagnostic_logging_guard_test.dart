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
/// - `[sasayaki-hl]`：有声书逐句高亮在 Dart 端的路径分叉（SRT 书绕开 sasayaki
///   系统），定位「完全没高亮」的真因。JS 端原有 `[sasayaki-hl]` 日志在 SRT
///   路径下永不触发，故 Dart 端这几处是关键盲区补全。
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
          reason: 'touchend 必须以 src=touch 调用 _bEnd');
      expect(paginationScripts, contains("e.clientY, 'pointer')"),
          reason: 'pointerup 必须以 src=pointer 调用 _bEnd');
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

  group('TODO-630 有声书高亮诊断埋点 [sasayaki-hl]', () {
    late String corpus;
    late String audiobookBridge;
    setUpAll(() {
      corpus = readReaderPageSource();
      audiobookBridge = File('lib/src/media/audiobook/audiobook_bridge.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
    });

    test('Dart 端 prepareCues 路径分叉有日志（SRT 绕开 sasayaki 的盲区）', () {
      expect(corpus, contains('[sasayaki-hl] prepareCues path=SRT'),
          reason: '纯 SRT 书直接 return null（applySasayakiCues 永不调用）必须留痕');
      expect(corpus, contains('[sasayaki-hl] prepareCues path=AUDIOBOOK'),
          reason: '有声书无 sasayaki cue 的早返回必须留痕');
    });

    test('Dart 端 highlight/apply 路径分叉有日志', () {
      expect(audiobookBridge, contains('[sasayaki-hl] highlight raw='),
          reason: '播放期逐句高亮的 frag null/非 null 分叉必须留痕');
      expect(
          audiobookBridge, contains('[sasayaki-hl] applySasayakiCues section='),
          reason: 'payload 空导致 JS 不被调用必须留痕');
    });
  });
}
