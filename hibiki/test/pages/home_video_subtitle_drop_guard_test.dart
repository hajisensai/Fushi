import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-079 源码守卫：主页把字幕拖到视频卡，必须走「直接挂到命中卡的现有视频书」
/// 路径（[attachSubtitleToVideoBook] / `_attachSubtitleToVideoCard`），**不得**回退到
/// 重新打开 VideoImportDialog 导入——后者对已存在视频重算 bookUid 触发同名去重、建
/// `video/<name> (2)` 重复条目，字幕没挂到原视频（headless 测不到真实拖放命中几何，
/// 故在源码层钉死接线，防回归）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/home_video_page.dart',
  );
  final File attachHelper = File(
    'lib/src/media/video/video_subtitle_attach.dart',
  );

  test('home_video_page wires attachToVideoCard to the direct attach path', () {
    final String src = page.readAsStringSync();

    // 命中 attachToVideoCard 分支存在，且调用专用附加方法。
    expect(src.contains('case DropIntent.attachToVideoCard:'), isTrue,
        reason: 'attachToVideoCard case must be handled');
    expect(src.contains('_attachSubtitleToVideoCard('), isTrue,
        reason: 'attachToVideoCard must call the dedicated attach method');

    // 专用方法经纯落库 helper 把字幕挂到现有 bookUid（不新建/不去重）。
    expect(src.contains('attachSubtitleToVideoBook('), isTrue,
        reason: 'attach must go through attachSubtitleToVideoBook helper');
  });

  test('attachToVideoCard does NOT re-import via VideoImportDialog', () {
    final String src = page.readAsStringSync();

    // 找到 attachToVideoCard 这一 case 到下一个 case 之间的代码块，断言里面不调用
    // _openVideoImportPrefilled（那是旧的重复导入 bug 路径）。
    final int start = src.indexOf('case DropIntent.attachToVideoCard:');
    expect(start, greaterThan(-1));
    final int next = src.indexOf('case DropIntent.', start + 1);
    expect(next, greaterThan(start));
    final String block = src.substring(start, next);
    expect(
      block.contains('_openVideoImportPrefilled('),
      isFalse,
      reason: 'attachToVideoCard must not re-import (creates duplicate video '
          'entry, TODO-079 root cause)',
    );
  });

  test('attachSubtitleToVideoBook parses through async subtitle route', () {
    final String src = attachHelper.readAsStringSync();

    expect(src.contains('await parseSubtitleContentAsync('), isTrue,
        reason: 'drag-attach must not synchronously parse large subtitles');
    expect(src.contains('parseSubtitleContent('), isFalse,
        reason: 'the video-card attach path must not call the sync parser');
  });
}
