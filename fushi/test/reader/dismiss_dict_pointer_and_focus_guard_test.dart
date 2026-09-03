import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-1071 源码守卫：关闭词典（查词弹窗）的三症同源修复。原生平台 WebView 抢 OS
/// 焦点 + 鼠标键无运行时消费者这两个根因在 headless 单测里难稳定复现（无真实平台
/// 焦点/原生指针），故用接线守卫固化关键不变式，防回归被删（对齐
/// reader_resumed_focus_reclaim_static_test.dart 的做法）。
void main() {
  // 症① 鼠标键关词典：消费者搬到 reader_fushi/webview.part.dart 的 onPointerSeek，
  // 读「主壳 + 全部 part」合并语料。
  final String corpus = readReaderPageSource();

  late String pageSrc;
  setUpAll(() {
    final File f =
        File('lib/src/pages/implementations/reader_fushi_page.dart');
    expect(f.existsSync(), isTrue, reason: '主壳文件不存在');
    pageSrc = f.readAsStringSync().replaceAll('\r\n', '\n');
  });

  group('症① 鼠标键关词典：onPointerSeek 把非位置型按钮交给通用执行体', () {
    late String seekBody;
    late String seekBranch;
    setUpAll(() {
      final int h = corpus.indexOf("handlerName: 'onPointerSeek'");
      expect(h, greaterThanOrEqualTo(0), reason: 'onPointerSeek handler 必须存在');
      // 取该 handler 回调体（到下一个 addJavaScriptHandler 前的一段），足够覆盖判定链。
      final int next = corpus.indexOf('addJavaScriptHandler', h + 1);
      seekBody = corpus.substring(h, next > h ? next : corpus.length);

      // 「位置型动作」分支体（花括号配对取整块），用于结构性断言：controller 门控必须
      // 关在这个分支**里面**，不能挡住后面的通用派发。
      final int b = seekBody.indexOf('if (isSeekToClickedSentenceButton(');
      expect(b, greaterThanOrEqualTo(0), reason: '位置型动作分支必须存在');
      final int open = seekBody.indexOf('{', b);
      expect(open, greaterThanOrEqualTo(0));
      int depth = 0;
      int close = open;
      for (int k = open; k < seekBody.length; k++) {
        if (seekBody[k] == '{') depth++;
        if (seekBody[k] == '}') {
          depth--;
          if (depth == 0) {
            close = k;
            break;
          }
        }
      }
      seekBranch = seekBody.substring(open, close + 1);
    });

    // BUG-2031：本条**加强**了原来的不变式。原守卫钉的是「seekBody 里出现
    // ShortcutAction.readerDismissDict」，那恰恰是 BUG-2031 的根因形状——handler 硬编码
    // 判某一个动作，于是 reader/audiobook scope 明明开着 mouse 通道、设置页也给录入
    // 入口，除这一个（加 seek-to-sentence）之外**绑什么都没反应**。现在改为断言它必须
    // 走通用解析 + 通用执行体，并**禁止**再出现硬编码动作名。
    test('非位置型按钮走通用解析 + 通用执行体，不得硬编码单个动作', () {
      expect(seekBody.contains('resolveMouseBindingActionForButton('), isTrue,
          reason: '必须按 scope 阶梯通用解析，而不是只判某一个动作');
      expect(seekBody.contains('_executeShortcutAction('), isTrue,
          reason: '必须汇进与键盘/手柄同一个执行体');
      expect(seekBody.contains('ShortcutAction.readerDismissDict'), isFalse,
          reason: '硬编码单个动作 = 回到「只有它能用、其余全是死项」的 BUG-2031 根因');
    });

    test('关词典语义仍在（弹窗可见才关整栈），只是搬进了通用执行体', () {
      // 语义没丢：readerDismissDict 的分支体必须仍然「仅弹窗可见时 clearDictionaryResult」。
      final int c =
          corpus.indexOf('case ShortcutAction.readerDismissDict:');
      expect(c, greaterThanOrEqualTo(0),
          reason: '通用执行体必须仍有 readerDismissDict 分支，否则鼠标键关不掉词典');
      final int nextCase = corpus.indexOf('case ShortcutAction.', c + 1);
      final String branch =
          corpus.substring(c, nextCase > c ? nextCase : corpus.length);
      expect(branch.contains('isDictionaryShown'), isTrue,
          reason: '仅在弹窗可见时关，无弹窗不消费');
      expect(branch.contains('clearDictionaryResult()'), isTrue,
          reason: '与键盘 Esc/readerDismissDict 同语义关整栈');
    });

    test('关词典判定独立于 _audiobookController（纯 EPUB 无有声书也能关）', () {
      // 结构性断言而不是「谁在前」：controller 门控必须**关在位置型动作分支里面**
      // （seek 才需要 controller），通用派发在分支之外，故纯 EPUB（controller 恒 null）
      // 也能走到关词典。原守卫用下标先后表达这件事，重构后已不适用。
      expect(seekBranch.contains('_audiobookController == null'), isTrue,
          reason: 'controller 门控属于 seek 分支自己的前提');
      final String outside = seekBody.replaceFirst(seekBranch, '');
      expect(outside.contains('_audiobookController'), isFalse,
          reason: '通用派发路径一旦碰 controller，纯 EPUB 就再也关不掉词典');
      expect(outside.contains('resolveMouseBindingActionForButton('), isTrue,
          reason: '通用派发必须在 controller 门控之外');
    });

    test('seek-to-sentence 旧路径保留（不回归中键点句）', () {
      expect(seekBody.contains('isSeekToClickedSentenceButton'), isTrue);
      expect(seekBody.contains('_seekToClickedSentence('), isTrue);
    });

    // BUG-2031：指针归宿主的平台上，本 handler 主动让位给页面根 Listener；那时
    // 「弹窗可见」这半边由 barrier 的 onNonPrimaryButtonDown 承接，其落地判据是
    // dictionaryPopupForwardedActions。少了这条，Windows 上侧键关词典整条失效。
    test('弹窗可见那半边由转发动作覆盖（readerDismissDict 必须在转发集合里）', () {
      final int start =
          pageSrc.indexOf('get dictionaryPopupForwardedActions');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'reader 必须声明转发动作集合');
      final int end = pageSrc.indexOf('};', start);
      final String body = pageSrc.substring(start, end);
      expect(body.contains('ShortcutAction.readerDismissDict'), isTrue,
          reason: '弹窗可见时按侧键关词典靠它；删掉 = BUG-1071 原症状复现');
      expect(body.contains('ShortcutAction.globalBack'), isTrue,
          reason: '「返回上一级」在弹窗持焦时也必须能关词典');
    });
  });

  group('症② 键盘关词典可靠性：指针唤出弹窗后收回 Flutter 焦点', () {
    test('popupRendered 判据分支存在且门控正确（收回正文节点）', () {
      final int start =
          pageSrc.indexOf('bool _canOwnReaderFocus(FocusReclaimCause cause)');
      expect(start, greaterThanOrEqualTo(0), reason: '应有统一焦点判据，含指针弹窗回收分支');
      final int end = pageSrc.indexOf('\n  }', start);
      final String body = pageSrc.substring(start, end);
      expect(body.contains('FocusReclaimCause.popupRendered'), isTrue,
          reason: '判据必须有 popupRendered 分支（指针唤出弹窗后收回焦点）');
      expect(pageSrc.contains('node: _focusNode'), isTrue,
          reason: '必须把焦点收回正文 _focusNode，否则 Esc 到不了 _handleKeyEvent');
      // 歌词态不动（自有焦点路径）；无弹窗 no-op。
      expect(body.contains('_lyricsMode'), isTrue, reason: '歌词态必须门控，不夺歌词焦点');
      expect(body.contains('isDictionaryShown'), isTrue, reason: '无弹窗时 no-op');
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
      expect(
          body.contains(
              '_focusOwnership.reclaim(FocusReclaimCause.popupRendered)'),
          isTrue,
          reason: '指针路径必须收回焦点，修复键盘关词典经常失效');
    });
  });
}
