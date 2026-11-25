import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-4718（反馈 mNogI-kBAh）：把「跳转到点击句」绑到鼠标右键后，右键跳句一次，
/// P 等快捷键全部失效，要点一下空白 / 查一次词 / 按一下空格才恢复。
///
/// 根因：正文 JS 的非左键 `mousedown` 经 `onPointerSeek` 回 Dart。这次按下已把 OS
/// 键盘焦点交给原生 WebView（BUG-136 同族），而 `onPointerSeek` 的「seek 到点击句」
/// 分支跑完 `_seekToClickedSentence` 就 `return`，Windows 上的 `hostOwnsWebViewPointerInput`
/// 早退分支同样直接 `return`，全程没有 `_focusOwnership.reclaim`。此后按键只到 DOM，
/// `_handleKeyEvent` 收不到。歌词文档的同名桥 `onLyricsPointerSeek` 早已 reclaim，
/// 正文这条漏了。
///
/// 修法：reclaim 属于「这次指针按下进了 WebView」这件事本身，与按下绑定的是哪个动作
/// 无关，所以在 handler 入口（参数校验之后、任何按动作分流的早退之前）收回一次，而不是
/// 在每个分支末尾各补一行（再加一条分支就又漏）。
void main() {
  final String src = maskComments(readReaderPageSource());

  String pointerSeekHandler() {
    final RegExpMatch? m = RegExp(
      r"handlerName: 'onPointerSeek',\s*callback:",
    ).firstMatch(src);
    expect(m, isNotNull, reason: '找不到 onPointerSeek 的注册处');
    final int at = m!.start;
    final int end = src.indexOf('addJavaScriptHandler(', at);
    return src.substring(at, end < 0 ? src.length : end);
  }

  test('onPointerSeek 在任何按动作分流的早退之前收回焦点', () {
    final String body = pointerSeekHandler();
    const String reclaim = '_focusOwnership.reclaim(FocusReclaimCause.gesture)';
    final int reclaimAt = body.indexOf(reclaim);
    expect(
      reclaimAt,
      greaterThanOrEqualTo(0),
      reason: '右键 / 中键按下已把 OS 焦点交给 WebView，不收回则快捷键全部失效',
    );
    for (final String branch in <String>[
      'isSeekToClickedSentenceButton(',
      '_seekToClickedSentence(',
      'hostOwnsWebViewPointerInput',
      'resolveMouseBindingActionForButton(',
      '_executeShortcutAction(',
    ]) {
      final int branchAt = body.indexOf(branch);
      expect(branchAt, greaterThanOrEqualTo(0), reason: '缺少分支 $branch');
      expect(
        reclaimAt,
        lessThan(branchAt),
        reason: 'reclaim 必须在 $branch 之前，否则该分支的早退会漏掉焦点回收',
      );
    }
    expect(
      RegExp(RegExp.escape(reclaim)).allMatches(body).length,
      1,
      reason: '入口收回一次即可，不在各分支末尾重复补',
    );
  });
}
