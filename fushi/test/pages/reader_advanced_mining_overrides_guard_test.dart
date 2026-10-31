import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

/// 「高级制卡」阅读器 / 有声书车道守卫。
///
/// 写卡与对话框试听必须**同源**（BUG-2196 ②：听到什么就压出什么）：草稿合并 +
/// 本次起止偏移只在 `_miningSentenceAudioClip` 一处求值，`_prepareMiningContext` 的
/// CardSourceLink 区间、ffmpeg 裁音频区间、对话框的区间显示与试听都经它。覆盖项从
/// 本次请求的 fields 里读（不挂页面状态：制卡串行队列异步启动）。真实裁音频要
/// ffmpeg + 有声书控制器，无头测试照不到，故用源码扫描钉死每段接线；偏移本身的算术
/// 由 `applyMiningAudioEdgeAdjust` 的单测覆盖。
void main() {
  late String mining;
  late String corpus;

  setUpAll(() {
    mining = File(
      'lib/src/pages/implementations/reader_fushi/mining.part.dart',
    ).readAsStringSync();
    corpus = readReaderPageSource();
  });

  String bodyOf(String src, String signature) {
    final int at = src.indexOf(signature);
    expect(at, greaterThanOrEqualTo(0), reason: '找不到 $signature');
    final int open = src.indexOf('{', at + signature.length);
    int depth = 0;
    for (int i = open; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(open, i + 1);
      }
    }
    fail('could not brace-match $signature');
  }

  test('区间只在 _miningSentenceAudioClip 一处求值：草稿合并 + 起止偏移', () {
    final String helper = bodyOf(
      mining,
      'AudioPlaybackRange? _miningSentenceAudioClip({',
    );
    expect(helper, contains('_miningDraft.composeAudioRange('));
    expect(helper, contains('applyMiningAudioEdgeAdjust('));
    // 整个阅读器（主文件 + 全部 part）里 composeAudioRange 只剩这一个调用点——
    // 再多一处就是又长出了一份不带偏移的区间。
    expect(
      RegExp(r'_miningDraft\.composeAudioRange\(').allMatches(corpus).length,
      1,
      reason: '句子音频区间必须只经 _miningSentenceAudioClip 求值',
    );
  });

  test('写卡两处（CardSourceLink / 裁音频）用同一个值，且带本次偏移', () {
    final String prepare = bodyOf(mining, '_prepareMiningContext({');
    expect(
      RegExp(
        r'sourceAudioRange = _miningSentenceAudioClip\(\s*'
        r'startDeltaMs: overrides\?\.audioStartDeltaMs \?\? 0,\s*'
        r'endDeltaMs: overrides\?\.audioEndDeltaMs \?\? 0,',
      ).hasMatch(prepare),
      isTrue,
    );
    expect(prepare, contains('startMs: sourceAudioRange?.startMs'));
    expect(
      prepare,
      contains('final AudioPlaybackRange? clip = sourceAudioRange;'),
      reason: '裁音频必须复用 CardSourceLink 的同一个区间值',
    );
    // 不要音频：整块跳过；不要图片：书封不进卡。
    expect(
      prepare,
      contains('if (audioFiles != null && !(overrides?.omitAudio ?? false))'),
    );
    expect(
      prepare,
      contains('if (_extractDir != null && !(overrides?.omitImage ?? false))'),
    );
  });

  test('覆盖项从本次 fields 读出（制卡与覆写两条路都认）', () {
    final String mine = bodyOf(
      mining,
      'Future<MinePopupResult> _onMineFromPopupInner(',
    );
    // 容忍 dart format 的折行与尾逗号：钉的是「从 fields 读出」这件事，不是排版。
    final RegExp readFromFields = RegExp(
      r'MiningRequestOverrides\.readFrom\(\s*fields\s*,?\s*\)',
    );
    final int read = readFromFields.firstMatch(mine)?.start ?? -1;
    final int firstAwait = mine.indexOf('await ');
    expect(read, greaterThanOrEqualTo(0));
    expect(
      read,
      lessThan(firstAwait),
      reason: '覆盖项必须在首个 await 之前从冻结的 fields 读出',
    );
    expect(mine, contains('_prepareMiningContext(overrides: overrides)'));
    final String update = bodyOf(
      mining,
      'Future<MinePopupResult> _onUpdateFromPopupInner(',
    );
    expect(readFromFields.hasMatch(update), isTrue);
  });

  test('对话框的区间显示与试听都经 _miningSentenceAudioClip（与写卡同源）', () {
    final String sections = bodyOf(
      corpus,
      'Future<AdvancedMiningSections> buildAdvancedMiningSections({',
    );
    expect(
      sections,
      contains('_miningSentenceAudioClip('),
      reason: 'describe 必须与写卡同一个函数求区间',
    );
    expect(sections, contains('_previewMiningSentenceAudio('));
    expect(sections, contains('stopPreview: onStopSentenceAudioPreview'));
    expect(
      sections,
      contains('onClosed: hasAudiobook ? onStopSentenceAudioPreview'),
      reason: '关窗必须停掉试听',
    );
    expect(
      sections,
      contains('fetchPreview: onSentenceContextPreviewFromDraft'),
    );
    expect(sections, contains('setContext: onSetSentenceContextToDraft'));
    final String preview = bodyOf(
      corpus,
      'Future<RangePlayback?> _previewMiningSentenceAudio({',
    );
    expect(preview, contains('_miningSentenceAudioClip('));
    // 交回片段播放的句柄：对话框的试听按钮在播完 / 被打断时据此复位（FDN66-xurt）。
    expect(preview, contains('return controller.playRange(clip);'));
  });
}
