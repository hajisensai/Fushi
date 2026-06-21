import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-395 接线守卫：「普通 EPUB + SRT 音频」被 matcher 匹配后 cue 是
/// `sasayaki://...`，但 reader setup 期 `_prepareSasayakiCuesJson` 旧代码在
/// `_srtBookUid != null` 时**无条件早退 return null** → `applySasayakiCues` 永不
/// 调用 → JS `cueRangesMap` 恒空 → playback 每次 `highlightSasayakiCue` 都
/// `RETURN_NULL_no_segments`，正文无任何有声书跟随高亮（章节级跟随仍正常，因其走
/// cue 解码的 sectionIndex，不依赖 DOM range）。
///
/// 根因 = setup 用「音频格式=srt」(`_srtBookUid`) 当高亮策略代理，与 playback 用
/// 「cue 是否 sasayaki 编码」(`SasayakiMatchCodec.tryDecode`) 两套判据打架。修复把
/// 判据归一到 cue 内容：SRT / Audiobook 两源都先经 `_loadHighlightCues` 取全书 cue，
/// 再统一走 `buildSasayakiPayload` 判据，消除 SRT 预早退特例。
///
/// 既有 sasayaki 测试全是纯函数 + 源码字符串守卫、**零端到端接线断言**，所以「SRT 自
/// 首版就 return null、从未接线」从未被任何回归拦住（坏了好久）。本守卫专门锁定这条
/// 接线不变量；headless 无真 InAppWebView，逐句上色须真机复验。
void main() {
  final String readerSrc = readReaderPageSource();

  final int prepStart =
      readerSrc.indexOf('Future<String?> _prepareSasayakiCuesJson() async {');
  final int injectStart =
      readerSrc.indexOf('Future<void> _injectAudiobookBridge() async {');

  test('方法边界可定位（防守卫因重命名失效）', () {
    expect(prepStart, greaterThanOrEqualTo(0));
    expect(injectStart, greaterThan(prepStart));
  });

  final String prepBody = prepStart >= 0 && injectStart > prepStart
      ? readerSrc.substring(prepStart, injectStart)
      : readerSrc;

  test('SRT 不再无条件早退（旧 BUG-395 病征字符串已消除）', () {
    expect(
      prepBody.contains('applySasayakiCues SKIPPED (early return)'),
      isFalse,
      reason: '旧代码 _srtBookUid!=null 即 return null（SKIPPED early return），'
          'SRT-sasayaki 书永不建 range；修复后两源统一走 buildSasayakiPayload',
    );
  });

  test('cue 来源经统一 _loadHighlightCues 取得（SRT/Audiobook 同源判据）', () {
    expect(
      prepBody.contains('_loadHighlightCues('),
      isTrue,
      reason: 'SRT 与 Audiobook 两源必须先经统一加载，再走同一 sasayaki 判据，'
          '不得在 _prepareSasayakiCuesJson 里按 _srtBookUid 分叉早退',
    );
  });

  test('_prepareSasayakiCuesJson 仍复用 buildSasayakiPayload（BUG-300 契约不回退）', () {
    expect(prepBody.contains('AudiobookBridge.buildSasayakiPayload('), isTrue);
  });

  test('_loadHighlightCues 同时覆盖 SRT 与 Audiobook 两个 cue 源', () {
    final int loadStart = readerSrc.indexOf('_loadHighlightCues() async {');
    expect(loadStart, greaterThanOrEqualTo(0), reason: '统一 cue 加载器必须存在');
    final String loadBody = readerSrc.substring(loadStart, loadStart + 600);
    expect(loadBody.contains('SrtBookRepository'), isTrue,
        reason: 'SRT 书 cue 源');
    expect(loadBody.contains('AudiobookRepository'), isTrue,
        reason: '普通有声书 cue 源');
  });

  group('BUG-395 判据：sasayaki 编码的 cue（无论书源）都产出非空 payload', () {
    AudioCue sasayakiCue(int section, int ns, int ne, String text) => AudioCue()
      ..bookKey = ''
      ..chapterHref = ''
      ..sentenceIndex = 0
      ..textFragmentId = SasayakiMatchCodec.encodeHit(
          sectionIndex: section, normCharStart: ns, normCharEnd: ne)
      ..text = text
      ..startMs = 0
      ..endMs = 0
      ..audioFileIndex = 0;

    test('SRT 书被匹配进真 EPUB 后的 sasayaki cue → buildSasayakiPayload 非空（应建 range）',
        () {
      // 这正是用户日志里的 cue：sasayaki://s=26&ns=84&ne=111。
      final payload = AudiobookBridge.buildSasayakiPayload(
        <AudioCue>[sasayakiCue(26, 84, 111, 'これは推理小説です')],
        26,
      );
      expect(payload, isNotEmpty,
          reason: 'cue 是 sasayaki 编码就该建 range —— 与书源（SRT/Audiobook）无关');
      expect(payload.single['text'], 'これは推理小説です');
    });

    test('纯 [data-cue-id] 字幕 cue → 空 payload（保留早退，真 SRT 字幕书零回归）', () {
      final AudioCue dataCueId = AudioCue()
        ..bookKey = ''
        ..chapterHref = ''
        ..sentenceIndex = 0
        ..textFragmentId = '[data-cue-id="0"]'
        ..text = 'x'
        ..startMs = 0
        ..endMs = 0
        ..audioFileIndex = 0;
      expect(AudiobookBridge.buildSasayakiPayload(<AudioCue>[dataCueId], 0),
          isEmpty);
    });
  });
}
