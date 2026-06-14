import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-270 E「查词窗口多句合一制卡」(乙方案·视频车道) 接线守卫。
///
/// 视频页用 [DictionaryPageMixin]（非 reader 的 base_source_page），其查词浮层在
/// mixin 的 [DictionaryPageMixin.buildNestedPopupLayer] 构造。media_kit + 原生
/// WebView 无法在无头 widget 测试里驱动，故用源码扫描钉死「+句」累积 → 制卡合并 →
/// 清空 三段接线，防止任一环被悄悄断开（与 video_mining_context_guard / reader 的
/// sentence_draft_wiring_guard 同范式）。草稿合并/join 的纯逻辑已由
/// test/media/audiobook/mining_sentence_draft_test.dart 全覆盖，这里只验「接线」。
void main() {
  String readSource(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  test('mixin exposes an overridable append hook and forwards onAppendSentence',
      () {
    final String src =
        readSource('lib/src/pages/implementations/dictionary_page_mixin.dart');
    // 默认 null = 不支持（纯查词页 / 首页词典不渲染「+句」）。
    expect(
      src,
      contains('Future<int> Function()? get onAppendSentenceToDraft => null;'),
    );
    // buildNestedPopupLayer 把钩子透传给弹窗层；非空才渲染「+句」。
    expect(src, contains('onAppendSentence: onAppendSentenceToDraft'));
  });

  group('video_hibiki_page', () {
    late String src;
    setUpAll(() {
      src = readSource('lib/src/pages/implementations/video_hibiki_page.dart');
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
      // 覆写 mixin 钩子返回非空闭包 → popup 渲染「+句」。
      expect(
        src,
        contains(
            'Future<int> Function()? get onAppendSentenceToDraft => _appendSentenceToDraft;'),
      );
    });

    test('append pushes the current subtitle sentence + its cue range', () {
      final String append = region(
        'Future<int> _appendSentenceToDraft() async {',
        'bool _pausedForLookup',
      );
      expect(append, contains('_miningDraft.append(MiningDraftSentence('));
      expect(append, contains('sentence: _lastLookupSentence'));
      expect(append, contains('audioRange: _currentLookupCueRange()'));
      expect(append, contains('return _miningDraft.length;'));
      // 视频所有 cue 同属一个视频文件 → audioFileIndex 恒 0（合并恒成功取 min/max）。
      final String cueRange = region(
        'AudioPlaybackRange? _currentLookupCueRange() {',
        'Future<int> _appendSentenceToDraft() async {',
      );
      expect(cueRange, contains('audioFileIndex: 0'));
    });

    test('mining merges draft + current for both text and range', () {
      final String resolve = region(
        '_resolveVideoMiningRange(VideoPlayerController controller) {',
        'Future<MinePopupResult> onMineEntry(',
      );
      // 文本合并：草稿全部句 + 当前查词句。
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
        'Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {',
        'TODO-270 D：覆盖',
      );
      // 成功且非多选路径 → 清草稿（与 popup.js 同事件归零）。
      expect(mine, contains('_miningDraft.clear();'));
      // 多选路径成功 → 清多选（保留旧行为，与草稿正交）。
      expect(mine, contains('_clearSelectedMiningCues();'));
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
