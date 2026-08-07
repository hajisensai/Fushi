import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// 开书/跨章性能守卫（阅读器渐进重建 phase1）：`_prepareSasayakiCuesJson` 不得
/// 每次章节加载都重查全书 cue。
///
/// 旧实现方法开头 `_cachedAllCues = null;` 主动丢弃缓存再 `_loadHighlightCues()`
/// 全书重查——而 `_resolveAudioSlot → _primeAudioCuesForCurrentBook` 在开书时
/// 已查过同一份并灌进 `_cachedAllCues`。这个重复查询串行挡在每次引擎注入之前
/// （首帧路径），且清缓存后若加载失败，`_injectAudiobookBridge` 会静默拿到 null
/// 跳过 cue 装载（竞态隐患）。
///
/// 修复后的不变量：
///  ① prepare 先复用 `_cachedAllCues`，仅缓存缺失时兜底加载；
///  ② 缓存生命周期 = 音频槽绑定：`_resolveAudioSlot` 的 detach 块清缓存，
///     prime 重灌——不靠每章丢弃换正确性。
///
/// 页面私有方法无法在 host widget 测试里行为驱动（需真 InAppWebView + 音频会话），
/// 落在源码语料层（与 reader_sasayaki_payload_source_guard_test 同纪律）。
void main() {
  final String src = readReaderPageSource();

  final int prepStart =
      src.indexOf('Future<String?> _prepareSentenceAudioCuesJson() async {');
  final int injectStart =
      src.indexOf('Future<void> _injectAudiobookBridge() async {');

  test('方法边界可定位（防守卫因重命名失效）', () {
    expect(prepStart, greaterThanOrEqualTo(0));
    expect(injectStart, greaterThan(prepStart));
  });

  final String prepBody = prepStart >= 0 && injectStart > prepStart
      ? src.substring(prepStart, injectStart)
      : src;

  test('① prepare 复用 _cachedAllCues，不再每章先清缓存', () {
    expect(prepBody.contains('_cachedAllCues = null'), isFalse,
        reason: '方法内不得丢弃缓存——丢弃即退回「每章全书重查 + 失败静默跳过」');
    expect(prepBody.contains('= _cachedAllCues;'), isTrue,
        reason: '必须先读缓存（复用 _primeAudioCuesForCurrentBook 已查的全书 cue）');
    expect(prepBody.contains('allCues = await _loadHighlightCues();'), isTrue,
        reason: '缓存缺失时仍要兜底加载（不变量是复用，不是砍掉加载能力）');
  });

  test('② 缓存生命周期 = 音频槽绑定：detach 块失效、prime 重灌', () {
    final int slotStart = src
        .indexOf('Future<void> _resolveAudioSlot({bool forceReload = false})');
    final int attachStart = src.indexOf(
        'Future<void> _attachExistingSession(AudiobookSession session)');
    expect(slotStart, greaterThanOrEqualTo(0));
    expect(attachStart, greaterThan(slotStart));
    final String slotBody = src.substring(slotStart, attachStart);
    expect(slotBody.contains('_cachedAllCues = null;'), isTrue,
        reason: 'detach 旧音频槽时必须失效 cue 缓存（换音频源后不得用旧 cue）');

    final int primeStart =
        src.indexOf('Future<void> _primeAudioCuesForCurrentBook() async {');
    expect(primeStart, greaterThanOrEqualTo(0));
    final String primeBody = src.substring(primeStart, primeStart + 2400);
    expect(primeBody.contains('_cachedAllCues = '), isTrue,
        reason: 'prime 必须重灌缓存（prepare 复用的就是这份）');
  });
}
