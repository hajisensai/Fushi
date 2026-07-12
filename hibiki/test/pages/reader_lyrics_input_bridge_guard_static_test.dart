import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-756 回归守卫：歌词模式（`LyricsModeHtml` 独立文档）唤不出隐藏底栏 + ESC 退不出。
///
/// 根因：歌词是整页 `loadData` 的独立文档，没有正文 hoshiReader 的 onTap/onTapEmpty
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

  test(
      'reader registers onLyricsTapEmpty that reveals chrome and reclaims focus',
      () {
    final String src = readReaderPageSource();

    expect(src, contains("handlerName: 'onLyricsTapEmpty'"));
    // 取该 handler 注册处往后一段，断言 handler 体真「唤/收底栏 + reclaim 焦点」，
    // 而非只是登记了个空 handler。
    final int start = src.indexOf("handlerName: 'onLyricsTapEmpty'");
    expect(start, greaterThanOrEqualTo(0));
    final String body = src.substring(start, start + 600);
    expect(body, contains('_reclaimReaderFocusAfterGesture()'));
    expect(
      body,
      anyOf(
        contains('_toggleChrome()'),
        contains('_handleFloatingChromeReveal()'),
      ),
    );
  });

  test('lyrics page-ready reclaims reader focus so ESC works from entry', () {
    final String src = readReaderPageSource();

    // `_onChapterLoadComplete` 歌词分支就绪后必须 reclaim 焦点（loadData 掉焦 →
    // 一进歌词模式 ESC 就到不了 Flutter）。锚定该方法体的歌词分支（含
    // `_lyricsPageReady = true;`），断言同一分支里出现 reclaim（旧码无）。
    final int m = src.indexOf('_onChapterLoadComplete(InAppWebViewController');
    expect(m, greaterThanOrEqualTo(0));
    final String method = src.substring(m, m + 1600);
    expect(method, contains('_lyricsPageReady = true;'));
    expect(method, contains('_reclaimReaderFocusAfterGesture()'));
  });
}
