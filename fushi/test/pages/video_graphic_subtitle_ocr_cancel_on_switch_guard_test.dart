import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：图形字幕整轨转文字（`_generateSubtitleFromGraphicTrack`）在**换视频源**时
/// 必须被取消。
///
/// 任务按 `isCurrent()`（`_episodeLoadSeq` / `_currentVideoPath` / controller）判断结果
/// 是否作废，但抽轨 ffmpeg 只认取消信号：换集 / 换片 / 换光盘标题后若不取消，它会在
/// 后台把旧文件整个读完（大文件可达十几分钟），期间进度卡一直挂在新视频上、
/// `_graphicSubtitleOcrRunning` 也一直把新视频的「转成文字字幕」入口锁成禁用。
///
/// media_kit 在 headless test 跑不起真视频 widget（无 libmpv），沿用源码扫描守卫范式。
void main() {
  final String src = readVideoFushiSource();

  /// [signature] 所在方法体（到下一个同缩进成员为止的粗切片）。
  String bodyOf(String signature) {
    final int start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '找不到 $signature');
    final int end = src.indexOf('\n  }\n', start);
    expect(end, greaterThan(start));
    return src.substring(start, end);
  }

  test('本地换片（_applyLoad 换了视频源）取消在途的整轨转文字', () {
    expect(
      src.contains('if (clipExportSourceChanged) _cancelGraphicSubtitleOcr();'),
      isTrue,
    );
  });

  test('远端换集与光盘换标题同样取消', () {
    // 两处都在 bump _episodeLoadSeq 的地方紧跟取消。
    final RegExp bumpThenCancel = RegExp(
      r'_episodeLoadSeq\+\+;\s*\n(?:\s*//[^\n]*\n)*\s*_cancelGraphicSubtitleOcr\(\);',
    );
    final RegExp remote = RegExp(
      r'final int seq = \+\+_episodeLoadSeq;\s*\n\s*_cancelGraphicSubtitleOcr\(\);',
    );
    expect(remote.hasMatch(src), isTrue, reason: '远端换集');
    expect(bumpThenCancel.hasMatch(src), isTrue, reason: '光盘换标题');
  });

  test('取消信号就是抽轨与逐条识别共用的那一个', () {
    final String body = bodyOf(
      'Future<void> _generateSubtitleFromGraphicTrack(',
    );
    expect(body.contains('cancel: cancel.future'), isTrue);
    expect(body.contains('!isCurrent() || cancelled()'), isTrue);
    final String cancel = bodyOf('void _cancelGraphicSubtitleOcr()');
    expect(cancel.contains('cancel.complete()'), isTrue);
  });
}
