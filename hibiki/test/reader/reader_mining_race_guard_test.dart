import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-644 / BUG-357 回归守卫：制卡并发 race（句子/cue 句 + 加粗偏移错配）。
///
/// 两条不变量必须保持，否则 race 复发：
/// 1. `_prepareMiningContext` 在第一个 await（`extractAudioSegment`，让出事件循环数百
///    ms）**之前**把所有要进 [AnkiMiningContext] 的共享可变成员快照成局部 final；await
///    之后不得再读 `currentCueSentence` / `_cachedSentenceOffset`（否则并发查词改写后，
///    第一张卡读到第二个词的值）。
/// 2. `onMineFromPopup` / `onUpdateFromPopup` 经制卡串行队列执行，杜绝快速连制两张卡时
///    两次 prepare→mine 在 await 处交错。
/// 去掉每行 `//` 之后的内容（足以避免说明性注释里出现的标识符被源码守卫误命中；
/// 字符串字面量里的 `//` 在本文件扫描的目标区域不出现，无需更复杂的词法分析）。
String _stripLineComments(String code) {
  return code.split('\n').map((String line) {
    final int slash = line.indexOf('//');
    return slash >= 0 ? line.substring(0, slash) : line;
  }).join('\n');
}

void main() {
  late String source;
  late int prepareStart;
  late int prepareEnd;
  late int extractAwaitIndex;

  setUpAll(() {
    source = readReaderPageSource();

    prepareStart = source.indexOf('_prepareMiningContext() async {');
    expect(prepareStart, greaterThanOrEqualTo(0),
        reason: '必须能定位 _prepareMiningContext。');

    // _prepareMiningContext 之后第一个出现的方法签名作为函数体的结束边界。
    prepareEnd = source.indexOf(
        'Future<MinePopupResult> _onMineFromPopupInner', prepareStart);
    expect(prepareEnd, greaterThan(prepareStart),
        reason: '必须能定位 _prepareMiningContext 的函数体结束边界。');

    extractAwaitIndex = source.indexOf(
        'await TtsChannel.instance.extractAudioSegment', prepareStart);
    expect(extractAwaitIndex, greaterThan(prepareStart));
    expect(extractAwaitIndex, lessThan(prepareEnd),
        reason: 'extractAudioSegment await 必须在 _prepareMiningContext 函数体内。');
  });

  group('TODO-644 制卡并发 race 守卫', () {
    test('await 前快照 cue 句 + 加粗偏移成局部 final', () {
      final String preAwait = source.substring(prepareStart, extractAwaitIndex);
      expect(
        preAwait,
        contains('final String snapshotCueSentence ='),
        reason: 'cue 句必须在 extractAudioSegment await 之前快照。',
      );
      expect(
        preAwait,
        contains('final int? snapshotSentenceOffset = _cachedSentenceOffset'),
        reason: '加粗偏移必须在 extractAudioSegment await 之前快照。',
      );
    });

    test('await 之后不再读会被并发查词改写的共享可变成员', () {
      // 只扫真实代码（剥掉 // 注释），避免「不再读 currentCueSentence」这类说明性
      // 注释误命中。
      final String postAwaitCode =
          _stripLineComments(source.substring(extractAwaitIndex, prepareEnd));
      expect(
        postAwaitCode,
        isNot(contains('currentCueSentence')),
        reason: 'extractAudioSegment await 之后读 currentCueSentence 会拿到并发查词改写后的'
            '第二个词的值；必须用 await 前的 snapshotCueSentence。',
      );
      expect(
        postAwaitCode,
        isNot(contains('_cachedSentenceOffset')),
        reason: 'extractAudioSegment await 之后读 _cachedSentenceOffset 会拿到并发查词改写后'
            '的值；必须用 await 前的 snapshotSentenceOffset。',
      );
    });

    test('AnkiMiningContext 用快照值构造，不读共享可变成员', () {
      final int ctxIndex = source.indexOf(
          'final AnkiMiningContext miningContext = AnkiMiningContext(',
          prepareStart);
      expect(ctxIndex, greaterThan(extractAwaitIndex),
          reason: 'AnkiMiningContext 在 await 之后构造。');
      final int ctxEnd = source.indexOf(');', ctxIndex);
      final String ctxBlock = source.substring(ctxIndex, ctxEnd);
      expect(
        ctxBlock,
        contains('cueSentence: snapshotCueSentence.isNotEmpty'),
        reason: 'cueSentence 必须用快照值。',
      );
      expect(
        ctxBlock,
        contains('sentenceOffset: snapshotSentenceOffset'),
        reason: 'sentenceOffset 必须用快照值。',
      );
    });

    test('制卡 / 覆盖经串行队列执行（连制不交错，不丢弃请求）', () {
      expect(
        source,
        contains('final SerialTaskQueue _miningQueue = SerialTaskQueue();'),
        reason: '必须有制卡串行队列（委托给纯 helper SerialTaskQueue）。',
      );
      expect(
        source,
        contains(
            'return _miningQueue.enqueue(() => _onMineFromPopupInner(fields));'),
        reason: 'onMineFromPopup 必须经串行队列 enqueue。',
      );
      expect(
        source,
        contains(
            'return _miningQueue.enqueue(() => _onUpdateFromPopupInner(noteId, fields));'),
        reason: 'onUpdateFromPopup 必须经串行队列 enqueue。',
      );
    });
  });
}
