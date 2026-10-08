import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi_audio/fushi_audio.dart';

import 'reader_fushi_page_source_corpus.dart';

/// BUG-756 回归守卫：歌词模式（`LyricsModeHtml` 独立文档）唤不出隐藏底栏 + ESC 退不出。
///
/// 根因：歌词是整页 `loadData` 的独立文档，没有正文 fushiReader 的 onTap/onTapEmpty
/// 桥；歌词里点句子 = 查词，点空白此前是 no-op（`if (!cueEl) return;`）。于是：
/// ① 底栏一旦隐藏就再无任何手势能唤出；② 桌面 WebView2 在 pointer 手势里抢走 OS 焦点，
/// 歌词 tap 路径从不 reclaim Flutter `_focusNode` → 收不到 ESC → 全局「Esc 退出整页」
/// 处理器永不触发（正文每个手势 handler 都 reclaim，歌词此前一处都没有）。
///
/// 修：① 歌词 HTML 空白点击 `callHandler('onLyricsTapEmpty')`；② reader 注册该 handler
/// 无条件唤/收隐藏底栏 + reclaim 阅读焦点；③ 歌词页就绪即 reclaim，让 ESC 从进入那刻起可退。
/// 三层都是「WebView 行为，无法 widget 挂载真 InAppWebView」，最强可落地层是生成的 HTML
/// 契约 + reader 源码扫描守卫。
void main() {
  AudioCue cue(int i) => AudioCue()
    ..id = i + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = i
    ..textFragmentId = ''
    ..text = 'cue $i'
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;

  test('lyrics HTML forwards empty-space tap to onLyricsTapEmpty (BUG-756)',
      () {
    final String html = LyricsModeHtml.generate(
      cues: <AudioCue>[cue(0), cue(1), cue(2)],
      currentIndex: 0,
      backgroundColor: 'rgba(255,255,255,1.00)',
      textColor: 'rgba(0,0,0,1.00)',
      accentColor: 'rgba(255,220,0,1.00)',
      fontSize: 20,
    );

    // 空白点击（!cueEl）必须回 Dart 唤底栏 + reclaim 焦点，而不是旧的 no-op return。
    expect(html, contains("callHandler('onLyricsTapEmpty')"));
    // 旧码是 `if (!cueEl) return;`（无桥）——改成 !cueEl 分支后这条字面量必须消失。
    expect(html, isNot(contains('if (!cueEl) return;')));
  });

  // 2026-10-04 覆盖层架构：歌词有自己的 WebView，覆盖层自带全套播放控件，点空白
  // 不再负责唤出底栏（底栏在覆盖层下面，覆盖层的 ⋯ 菜单承接全部操作）。点空白的
  // 职责收敛为：有查词弹窗就关栈，否则清残留选区，并 reclaim 阅读焦点（BUG-136/756
  // 的 ESC 契约不变）。
  test(
      'lyrics WebView routes empty taps to one handler that reclaims focus',
      () {
    final String src = readReaderPageSource();

    expect(src, contains("handlerName: 'onLyricsTapEmpty'"));
    final int fn = src.indexOf('bool lyricsTapEmptyConsumed() {');
    expect(fn, greaterThanOrEqualTo(0));
    final String body = src.substring(fn, src.indexOf('\n        }\n', fn));
    expect(body, contains('clearDictionaryResult()'));
    expect(body, contains('_closeSideSheetForWebViewPointer()'));
    // 歌词文档里的选词脚本命中空白回 onTapEmpty、歌词页自身空白回
    // onLyricsTapEmpty，两条都必须先过同一个判据、再 reclaim 阅读焦点。
    final int reg = src.indexOf('Widget _buildLyricsWebView() {');
    expect(reg, greaterThanOrEqualTo(0));
    final String lyricsWeb = src.substring(reg);
    for (final String name in <String>['onTapEmpty', 'onLyricsTapEmpty']) {
      final int h = lyricsWeb.indexOf("handlerName: '$name',");
      expect(h, greaterThanOrEqualTo(0), reason: name);
      final String cb = lyricsWeb.substring(h, h + 260);
      expect(cb, contains('if (lyricsTapEmptyConsumed()) return;'));
      expect(
          cb, contains('_focusOwnership.reclaim(FocusReclaimCause.gesture)'));
    }
  });

  test(
      'lyrics page-ready does NOT steal reader focus on load (BUG-767 no flicker)',
      () {
    final String src = readReaderPageSource();

    // BUG-767 回归守卫：BUG-755 曾在歌词就绪分支回收焦点
    // 想让 ESC 从进入即可用，但桌面 loadData 后强夺 Flutter 焦点会顶焦原生 WebView2、
    // 重置滚动（→ 高亮看似回第一句）并抖动，叠加重载路径成持续闪烁。故歌词就绪
    // **必须不再**在 loadData 后强夺焦（ESC 改由任一交互后的 reclaim 覆盖）。
    // 覆盖层架构下歌词就绪是独立的 _onLyricsDocumentReady（不再是正文就绪的分支）。
    final int m = src.indexOf('Future<void> _onLyricsDocumentReady(');
    expect(m, greaterThanOrEqualTo(0));
    final int end = src.indexOf('Widget _buildLyricsWebView() {', m);
    expect(end, greaterThan(m));
    final String ready = src.substring(m, end);
    expect(ready, contains('_lyricsPageReady = true'));
    expect(ready,
        isNot(contains('_focusOwnership.reclaim(FocusReclaimCause.gesture)')));
  });

  test(
      'lyrics cue sync holds position when sourceIdx<0 (BUG-767 no reload loop)',
      () {
    final String src = readReaderPageSource();

    // BUG-767 回归守卫：sourceIdx<0（当前 cue 不可解析：cue 间隙 / 跨章瞬间）时必须
    // 保位不跳、绝不重载。旧码在 `idx<0` 分支无条件 `_loadLyricsPage()`，重载又以
    // 过期 entry index 生成 currentIndex → 恒第一句 + 无限重载闪烁。守卫后重载只剩
    // 「窗外合法重载」一处。
    final int s = src.indexOf('void _syncLyricsOverlayCue(');
    expect(s, greaterThanOrEqualTo(0));
    final int e = src.indexOf('Future<void> _onLyricsDocumentReady(', s);
    expect(e, greaterThan(s));
    final String sync = src.substring(s, e);
    final int guard = sync.indexOf('if (sourceIdx < 0) return;');
    expect(guard, greaterThanOrEqualTo(0));
    // 守卫之后只剩「cue 移出已载窗口」这一处重载（守卫之前那处是无整书 cue 的书
    // 跨章换了章 cue 列表，与 sourceIdx 无关）。
    expect('_loadLyricsPage()'.allMatches(sync.substring(guard)).length, 1);
  });

  test(
      'lyrics mode persists across re-entry via safe deferred restore (BUG-785)',
      () {
    final String src = readReaderPageSource();

    // fresh open 捕获「上次是歌词模式」意图（保留偏好），而不是旧的直接抹除偏好。
    expect(
      src,
      contains(
          '_pendingLyricsRestore =\n'
            '        _sourceReviewSession == null && '
            'ReaderFushiSource.instance.lyricsMode;'),
    );
    // EPUB 内容就绪 + 有声书已挂载后再切歌词（等价手动切、规避 iOS 白屏），一次性触发。
    final int t = src.indexOf('if (_pendingLyricsRestore) {');
    expect(t, greaterThanOrEqualTo(0));
    final String block = src.substring(t, t + 220);
    expect(block, contains('_pendingLyricsRestore = false;'));
    expect(block, contains('_audiobookController != null'));
    expect(block, contains('_toggleLyricsMode()'));
  });
}
