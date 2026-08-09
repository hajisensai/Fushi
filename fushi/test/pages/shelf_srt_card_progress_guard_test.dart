import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-728 guard：书架有声书进度条。EPUB-backed 有声书在书架**只渲染成 SRT 卡**
/// （其 EpubBooks 行被 `srtBookKeys` 过滤出 EPUB 卡列表，见
/// `reader_fushi_history_page.dart` 的 `epubBooks = books.where(... !srtBookKeys...)`），
/// 而 SRT 卡以前不传 `metadata:` 且 `_srtBookMediaItem` 硬编码 `position:0, duration:1`
/// → 有声书书架永远没有进度条（用户「有声书好像少了进度条」）。
///
/// 修复把 EPUB 卡已算好的 position/duration（经 `computeBookProgress`，含听书
/// normCharOffset 回退）按 bookKey 建映射喂给 SRT 卡，并对 EPUB-backed 书渲染同一个
/// `_progressBar`。用源码扫描锁死三根线，避免回归。
void main() {
  final String historyPage = File(
    'lib/src/pages/implementations/reader_fushi_history_page.dart',
  ).readAsStringSync();
  final String booksPart = File(
    'lib/src/pages/implementations/reader_history/books.part.dart',
  ).readAsStringSync();

  test('装配：history page 从 books 建 _epubProgressByBookKey（过滤前）', () {
    // 映射必须在过滤 EPUB 卡之前，用每本 EpubBooks 行 MediaItem 已算好的
    // position/duration 装配；断了这根线，SRT 卡拿不到进度真值。
    expect(
      historyPage,
      contains('epubProgressByBookKey[key] ='),
      reason: '须在遍历 books 时收录每本书已算好的 position/duration',
    );
    expect(
      historyPage,
      contains('_epubProgressByBookKey = epubProgressByBookKey'),
      reason: '须把本帧映射赋给字段供 SRT 卡读取',
    );
    // 位置守卫：装配点必须在把 srtBookKeys 从 epubBooks 过滤之前（即遍历 books 的
    // 循环里），否则只以 SRT 卡出现的有声书永远进不了映射。
    final int assemble = historyPage.indexOf('epubProgressByBookKey[key] =');
    final int filter = historyPage.indexOf('!srtBookKeys.contains(key)');
    expect(assemble, greaterThanOrEqualTo(0));
    expect(filter, greaterThan(assemble),
        reason: '进度映射装配必须早于 EPUB 卡过滤，才能覆盖被过滤成 SRT 卡的有声书');
  });

  test('_srtBookMediaItem 用 _epubProgressByBookKey 而非硬编码 0/1', () {
    expect(
      booksPart,
      contains('_epubProgressByBookKey[book.bookKey]'),
      reason: 'SRT MediaItem 进度须复用 EPUB-backed 书的 position/duration',
    );
    expect(
      booksPart,
      contains('position: prog?.position ?? 0'),
      reason: '有 EPUB backing 时用真实 position，否则退回 0',
    );
    expect(
      booksPart,
      contains('duration: prog?.duration ?? 1'),
      reason: '有 EPUB backing 时用真实 duration，否则退回 1（不除零）',
    );
    // 回归哨兵：不得再出现旧的硬编码「position: 0, duration: 1」直写（会让进度恒 0）。
    expect(
      booksPart.contains(RegExp(r'position:\s*0,\s*\n\s*duration:\s*1,')),
      isFalse,
      reason: 'SRT MediaItem 不得再硬编码 position:0/duration:1',
    );
  });

  test('_buildSrtCard 对 EPUB-backed 书渲染 _progressBar，纯字幕书不渲染', () {
    // EPUB-backed 有声书画进度条（走与 EPUB 卡同一 _progressBar）；纯字幕书无进度
    // 真值 → 不传 metadata，保持无进度条（不显永远空的条）。
    // 结构性守卫：门控 `_srtBookHasProgress(book) ?`，真分支画 `_progressBar(srtItem…)`，
    // 纯字幕书 `: null` 不渲染。用正则而非单行字面量，容忍进度条扩展参数（如 BUG-888
    // 手动读完态 `completed:`）导致的多行 dart format，同时仍锁死门控与真/假分支。
    expect(
      booksPart.contains(RegExp(
          r'metadata: _srtBookHasProgress\(book\)\s*\?\s*_progressBar\(\s*srtItem,?[\s\S]*?\)\s*:\s*null')),
      isTrue,
      reason: 'SRT 卡进度条须按 _srtBookHasProgress 门控渲染'
          '（true 分支画 _progressBar(srtItem…)，纯字幕书 : null 不渲染）',
    );
    expect(
      booksPart,
      contains('bool _srtBookHasProgress(SrtBook book)'),
      reason: '须有 EPUB-backing 进度门控判据',
    );
    // 门控判据须命中 _epubProgressByBookKey（=有 EPUB 卡算好的进度）。
    expect(
      booksPart,
      contains('_epubProgressByBookKey.containsKey(book.bookKey)'),
      reason: '门控须以「命中进度映射」为准，纯字幕书 bookKey 不在映射里',
    );
  });
}
