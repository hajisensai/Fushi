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

    // BUG-1504 起不再自己 read+parse，而是转调 loadExternalSubtitleCueResult
    // ——它内部走 _readAndParse（异步 parser 入口，由 video_subtitle_source_test
    // 的守卫钉住）。TODO-475 的意图不变：这条路径不得同步解析大字幕。
    expect(src.contains('await loadExternalSubtitleCueResult('), isTrue,
        reason: 'drag-attach must reuse the classified async cue loader');
    expect(src.contains('parseSubtitleContent('), isFalse,
        reason: 'the video-card attach path must not parse on its own');
  });

  // -----------------------------------------------------------------------
  // BUG-1504：坏字幕拖到主页卡上，用户什么提示都没有。根因不是「少写一个 try」，
  // 而是这条链路没有结果所有者——drop 回调同步发起、不 await，helper 又会抛，
  // 异常无处可去。下面三条把「谁发起 / 谁等待 / 谁呈现」钉死在源码层：headless
  // 测不到真实拖放命中几何（需要 OS 拖放 + 卡片屏幕矩形），只能到这一层。
  // -----------------------------------------------------------------------

  test('attach helper 是全函数：读/解析/落库全部有失败出口，不抛给 fire-and-forget 调用方', () {
    final String src = attachHelper.readAsStringSync();

    // 拷盘 + 落库两处 IO 各自有 catch，并且落到显式 outcome 上。
    expect('catch'.allMatches(src).length, greaterThanOrEqualTo(2),
        reason: 'copy 与 saveSubtitleSelection 都必须有失败出口');
    expect(src.contains('SubtitleAttachOutcome.persistFailed'), isTrue,
        reason: 'IO/DB 失败必须变成 persistFailed 而不是异常');
    expect(src.contains('SubtitleAttachOutcome.cueLoadFailed'), isTrue,
        reason: 'cue 读不出/解不出必须变成 cueLoadFailed 并带 SubtitleCueLoadFailure');
    // 失败分类复用播放页那份（BUG-1490），不在主页再造一套语义。
    expect(src.contains('SubtitleCueLoadFailure.'), isTrue,
        reason: 'attach 必须复用 SubtitleCueLoadFailure，不得自建失败枚举');
  });

  test('drop 回调显式 unawaited 地把结果所有权交给 _attachSubtitleToVideoCard', () {
    final String src = page.readAsStringSync();

    expect(
      src.contains('unawaited(_attachSubtitleToVideoCard('),
      isTrue,
      reason: '裸调用会让异步失败无人接管；所有权必须显式移交（BUG-1504）',
    );
  });

  test('两个挂载入口的失败都可见，且文案同源', () {
    final String videoPage = page.readAsStringSync();
    final String homePage =
        File('lib/src/pages/implementations/home_page.dart').readAsStringSync();

    // 主页视频卡拖放：结果一律经共享映射变成 SnackBar。
    expect(videoPage.contains('subtitleAttachMessage('), isTrue,
        reason: '拖放入口必须经共享失败文案映射呈现结果');
    expect(videoPage.contains('showSnackBar('), isTrue);

    // 字幕搜索页安装到「已存在视频」：不能只在 attached 时做事、失败静默。
    final int at = homePage.indexOf('attachSubtitleToVideoBook(');
    expect(at, greaterThan(-1));
    final String tail = homePage.substring(at, at + 900);
    expect(tail.contains('subtitleAttachMessage('), isTrue,
        reason: '安装入口的失败必须呈现给用户，而不是只在成功时刷新库');
  });
}
