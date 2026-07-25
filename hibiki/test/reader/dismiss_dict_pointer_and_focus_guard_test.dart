import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-1071 源码守卫：关闭词典（查词弹窗）的三症同源修复。原生平台 WebView 抢 OS
/// 焦点 + 鼠标键无运行时消费者这两个根因在 headless 单测里难稳定复现（无真实平台
/// 焦点/原生指针），故用接线守卫固化关键不变式，防回归被删（对齐
/// reader_resumed_focus_reclaim_static_test.dart 的做法）。
void main() {
  // 症① 鼠标键关词典：消费者搬到 reader_hibiki/webview.part.dart 的 onPointerSeek，
  // 读「主壳 + 全部 part」合并语料。
  final String corpus = readReaderPageSource();

  late String pageSrc;
  setUpAll(() {
    final File f =
        File('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(f.existsSync(), isTrue, reason: '主壳文件不存在');
    pageSrc = f.readAsStringSync().replaceAll('\r\n', '\n');
  });

  group('症① 鼠标键关词典：onPointerSeek 消费 readerDismissDict 鼠标绑定', () {
    late String seekBody;
    setUpAll(() {
      final int h = corpus.indexOf("handlerName: 'onPointerSeek'");
      expect(h, greaterThanOrEqualTo(0), reason: 'onPointerSeek handler 必须存在');
      // 取该 handler 回调体（到下一个 addJavaScriptHandler 前的一段），足够覆盖判定链。
      final int next = corpus.indexOf('addJavaScriptHandler', h + 1);
      seekBody = corpus.substring(h, next > h ? next : corpus.length);
    });

    test('鼠标键经 resolveMouse(reader scope) 解析成 readerDismissDict', () {
      expect(seekBody.contains('resolveMouse('), isTrue,
          reason: '鼠标键必须经 resolveMouse 解析');
      expect(seekBody.contains('ShortcutScope.reader'), isTrue,
          reason: '关词典鼠标键属 reader scope');
      expect(seekBody.contains('ShortcutAction.readerDismissDict'), isTrue,
          reason: '必须判定 readerDismissDict 动作，否则鼠标键无消费者（原始症①）');
    });

    test('命中 readerDismissDict 且弹窗可见时关整栈（clearDictionaryResult）', () {
      expect(seekBody.contains('isDictionaryShown'), isTrue,
          reason: '仅在弹窗可见时关，无弹窗不消费');
      expect(seekBody.contains('clearDictionaryResult()'), isTrue,
          reason: '与键盘 Esc/readerDismissDict 同语义关整栈');
    });

    test('关词典判定独立于 _audiobookController（纯 EPUB 无有声书也能关）', () {
      // 关词典分支必须排在 `_audiobookController == null` 早退之前，否则纯 EPUB
      // （controller 恒 null）永远走不到关词典。断言两个片段的先后顺序。
      final int dismissIdx = seekBody.indexOf('ShortcutAction.readerDismissDict');
      final int controllerGuardIdx =
          seekBody.indexOf('_audiobookController == null');
      expect(dismissIdx, greaterThanOrEqualTo(0));
      expect(controllerGuardIdx, greaterThanOrEqualTo(0));
      expect(dismissIdx, lessThan(controllerGuardIdx),
          reason: '关词典判定必须在 controller==null 早退之前');
    });

    test('seek-to-sentence 旧路径保留（不回归中键点句）', () {
      expect(seekBody.contains('isSeekToClickedSentenceButton'), isTrue);
      expect(seekBody.contains('_seekToClickedSentence('), isTrue);
    });
  });

  group('症② 键盘关词典可靠性：指针唤出弹窗后收回 Flutter 焦点', () {
    test('存在 _reclaimReaderFocusForTouchPopup helper 且 requestFocus 正文节点', () {
      final int start =
          pageSrc.indexOf('void _reclaimReaderFocusForTouchPopup()');
      expect(start, greaterThanOrEqualTo(0),
          reason: '应有指针弹窗焦点回收 helper');
      final int end = pageSrc.indexOf('\n  }', start);
      final String body = pageSrc.substring(start, end);
      expect(body.contains('_focusNode.requestFocus()'), isTrue,
          reason: '必须把焦点收回正文 _focusNode，否则 Esc 到不了 _handleKeyEvent');
      // 歌词态不动（自有焦点路径）；无弹窗 no-op。
      expect(body.contains('_lyricsMode'), isTrue,
          reason: '歌词态必须门控，不夺歌词焦点');
      expect(body.contains('isDictionaryShown'), isTrue,
          reason: '无弹窗时 no-op');
    });

    test('onDictionaryPopupRendered 仅在指针路径(CaretSurface.none)调回收 helper', () {
      final int start =
          pageSrc.indexOf('void onDictionaryPopupRendered(int index) {');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'reader 必须覆写 onDictionaryPopupRendered 接入焦点回收');
      final int end = pageSrc.indexOf('\n  }', start);
      final String body = pageSrc.substring(start, end);
      // 光标/手柄唤出（surface != none）时 controller 会 transfer 光标、_focusNode 本就
      // 持焦，此处不介入以免与 transfer 竞争、不回归 BUG-136。
      expect(body.contains('_caret.onDictionaryPopupRendered(index)'), isTrue,
          reason: '既有光标 transfer 不得丢失');
      expect(body.contains('_caretSurface == CaretSurface.none'), isTrue,
          reason: '仅指针路径 reclaim（光标态交给 transfer）');
      expect(body.contains('_reclaimReaderFocusForTouchPopup()'), isTrue,
          reason: '指针路径必须收回焦点，修复键盘关词典经常失效');
    });
  });
}
