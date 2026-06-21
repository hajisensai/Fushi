import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// TODO-393「查词窗口句子上下文制卡」(视频车道) 接线守卫。
///
/// 视频页用 [DictionaryPageMixin]（非 reader 的 base_source_page），其查词浮层在 mixin
/// 的 [DictionaryPageMixin.buildNestedPopupLayer] 构造。media_kit + 原生 WebView 无法在
/// 无头 widget 测试里驱动，故用源码扫描钉死「上 N 句 / 下 N 句」上下文 → 制卡合并 →
/// 换词/制卡清空 三段接线。草稿合并/join 的纯逻辑已由
/// test/media/audiobook/mining_sentence_draft_test.dart 全覆盖，这里只验「接线」。
void main() {
  String readSource(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  test('mixin exposes an overridable set-context hook and forwards it', () {
    final String src =
        readSource('lib/src/pages/implementations/dictionary_page_mixin.dart');
    // 默认 null = 不支持（纯查词页 / 首页词典不渲染选择器）。
    expect(
      src,
      contains('get onSetSentenceContextToDraft => null;'),
    );
    // buildNestedPopupLayer 把钩子透传给弹窗层；非空才渲染选择器。
    expect(src, contains('onSetSentenceContext: onSetSentenceContextToDraft'));
  });

  group('video_hibiki_page', () {
    // TODO-590 batch13: `_lookupAt`（含 `_lastLookupSentence = sentence;` /
    // `_miningDraft.clear();` / `await pushNestedPopup(`）已搬进
    // lookup_favorite.part.dart，改读合并语料。
    // TODO-590 batch14: `_cueRange` / `_setSentenceContextToDraft` /
    // `_resolveVideoMiningRange` / `onMineEntry` 体（→ `_onMineEntryImpl`）已搬进
    // lookup_mining.part.dart；合并语料把主壳排在 part 前，凡 end marker 原指向「仍在
    // 主壳的字段/方法」（`bool _pausedForLookup` / `onMineEntry` 瘦转发器 /
    // `TODO-270 D：覆盖` 文案）现位于 start 之前会切片失败，改用 part 内紧随其后的
    // 方法签名作 end marker。`_popNestedPopupAt` / `_lookupAt` 切片不受影响。
    late String src;
    setUpAll(() {
      src = readVideoHibikiSource();
    });

    String region(String startSig, String endSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
      final int end = src.indexOf(endSig, start + startSig.length);
      expect(end, greaterThan(start),
          reason: 'missing $endSig after $startSig');
      return src.substring(start, end);
    }

    test('video opts into the draft and reuses the shared draft model', () {
      // 复用平台无关的 MiningSentenceDraft（不重写）。
      expect(
        src,
        contains(
            "import 'package:hibiki/src/media/audiobook/mining_sentence_draft.dart';"),
      );
      expect(src, contains('final MiningSentenceDraft _miningDraft ='));
      // 覆写 mixin 钩子返回非空闭包 → popup 渲染上下文选择器。
      expect(
        src,
        contains(
            'get onSetSentenceContextToDraft => _setSentenceContextToDraft;'),
      );
    });

    test('set-context takes prev/next cues around the lookup cue', () {
      final String set = region(
        'Future<int> _setSentenceContextToDraft(int prevCount, int nextCount) async {',
        'Future<int> _clearSentenceDraft(',
      );
      expect(set, contains('_lastLookupCue'));
      expect(set, contains('controller.cues'));
      expect(set, contains('_miningDraft.setContext('));
      expect(set, contains('return _miningDraft.length;'));
      // 视频所有 cue 同属一个视频文件 → audioFileIndex 恒 0（合并恒成功取 min/max）。
      final String cueRange = region(
        'AudioPlaybackRange? _cueRange(AudioCue? cue) {',
        'Future<int> _setSentenceContextToDraft(',
      );
      expect(cueRange, contains('audioFileIndex: 0'));
    });

    test('mining merges draft + current for both text and range', () {
      final String resolve = region(
        '_resolveVideoMiningRange(VideoPlayerController controller) {',
        'Future<MinePopupResult> _onMineEntryImpl(',
      );
      // 文本合并：草稿上下文句 + 当前查词句。
      expect(
        resolve,
        contains('_miningDraft.composeText(_lastLookupSentence)'),
      );
      // 区间合并：草稿区间 + 当前 cue 区间 → 首句起→末句止。
      expect(resolve, contains('_miningDraft.composeAudioRange('));
      // 字幕列表多选（TODO-102）仍优先，不掺草稿。
      expect(resolve, contains('usedSelectedCue: true'));
    });

    test('mining clears the draft only on success of the draft path', () {
      final String mine = region(
        'Future<MinePopupResult> _onMineEntryImpl(Map<String, String> fields) async {',
        'Future<MinePopupResult> _onUpdateEntryImpl(',
      );
      // 成功且非多选路径 → 清草稿（与 popup.js 同事件归零）。
      expect(mine, contains('_miningDraft.clear();'));
      // 多选路径成功 → 清多选（保留旧行为，与草稿正交）。
      expect(mine, contains('_clearSelectedMiningCues();'));
    });

    test(
        'a new lookup discards the previous word context (no cross-contamination)',
        () {
      final String lookup = region(
        '_lastLookupSentence = sentence;',
        'await pushNestedPopup(',
      );
      expect(lookup, contains('_miningDraft.clear();'));
    });

    test('closing the whole popup stack discards an un-mined draft', () {
      final String pop = region(
        'void _popNestedPopupAt(int index) {',
        'Widget _buildNestedPopupLayer(',
      );
      // 关栈汇聚点（reader onAllPopupsDismissed 的视频等价）：栈全空丢弃未制卡草稿。
      expect(pop, contains('if (stackEmpty) {'));
      expect(pop, contains('_miningDraft.clear();'));
    });
  });
}
