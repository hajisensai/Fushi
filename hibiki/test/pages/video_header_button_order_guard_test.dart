import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

/// 守卫（TODO-162）：视频页（HomeVideoPage）顶栏三个动作按钮的排列顺序，必须与
/// 书架（ReaderHibikiHistoryPage）顶栏三个动作按钮的相对顺序完全一致——以书架为基准。
///
/// 书架顺序：导入（buildBookImportButton / srt_import） → 收藏夹（collections） →
/// 统计（reading_statistics）。
/// 视频顺序应对齐为：导入（video_import_action） → 收藏夹（collections） →
/// 统计（video_statistics）。
///
/// 历史回归：视频页一度把导入按钮放在末尾（收藏夹 → 统计 → 导入），与书架不一致。
/// 本守卫断言视频顶栏「导入在收藏夹之前、收藏夹在统计之前」，防止顺序再次漂移。
void main() {
  final File videoSrc =
      File('lib/src/pages/implementations/home_video_page.dart');
  final File shelfSrc =
      File('lib/src/pages/implementations/reader_hibiki_history_page.dart');
  final File playerSrc =
      File('lib/src/pages/implementations/video_hibiki_page.dart');

  /// 截取某文件中 [_buildPageHeader] 方法体内 `actions: <Widget>[ ... ]` 区间的源码，
  /// 顺序断言只在该区间内做，避免命中页面其它位置的同名 tooltip / 图标。
  String headerActionsBlock(File file) {
    final String text = file.readAsStringSync();
    final int headerIdx = text.indexOf('_buildPageHeader');
    expect(headerIdx, greaterThanOrEqualTo(0),
        reason: '${file.path} 应定义 _buildPageHeader');
    final int actionsIdx = text.indexOf('actions: <Widget>[', headerIdx);
    expect(actionsIdx, greaterThanOrEqualTo(0),
        reason: '${file.path} 的 _buildPageHeader 应有 actions: <Widget>[');
    // actions 列表以下一个 `],` 收尾——足够覆盖三个按钮，且不会跨出方法体。
    final int closeIdx = text.indexOf('],', actionsIdx);
    expect(closeIdx, greaterThan(actionsIdx),
        reason: '${file.path} 的 actions 列表应正常闭合');
    return text.substring(actionsIdx, closeIdx);
  }

  /// 在区间内按 tooltip 标识取相对位置；找不到返回 -1。
  int orderOf(String block, String token) => block.indexOf(token);

  test('书架顶栏基准顺序：导入 → 收藏夹 → 统计', () {
    final String block = headerActionsBlock(shelfSrc);
    final int importIdx = orderOf(block, 'buildBookImportButton');
    final int collectionsIdx = orderOf(block, 't.collections');
    final int statsIdx = orderOf(block, 't.reading_statistics');
    expect(importIdx, greaterThanOrEqualTo(0), reason: '书架应有导入按钮');
    expect(collectionsIdx, greaterThanOrEqualTo(0), reason: '书架应有收藏夹按钮');
    expect(statsIdx, greaterThanOrEqualTo(0), reason: '书架应有统计按钮');
    expect(importIdx, lessThan(collectionsIdx), reason: '书架基准：导入应在收藏夹之前');
    expect(collectionsIdx, lessThan(statsIdx), reason: '书架基准：收藏夹应在统计之前');
  });

  test('视频顶栏顺序对齐书架：导入 → 收藏夹 → 统计', () {
    final String block = headerActionsBlock(videoSrc);
    final int importIdx = orderOf(block, 't.video_import_action');
    final int collectionsIdx = orderOf(block, 't.collections');
    final int statsIdx = orderOf(block, 't.video_statistics');
    expect(importIdx, greaterThanOrEqualTo(0), reason: '视频应有导入按钮');
    expect(collectionsIdx, greaterThanOrEqualTo(0), reason: '视频应有收藏夹按钮');
    expect(statsIdx, greaterThanOrEqualTo(0), reason: '视频应有统计按钮');
    expect(importIdx, lessThan(collectionsIdx),
        reason: 'TODO-162：视频导入按钮应在收藏夹之前（与书架一致）');
    expect(collectionsIdx, lessThan(statsIdx),
        reason: 'TODO-162：视频收藏夹按钮应在统计之前（与书架一致）');
  });

  test('播放器顶栏片段导出按钮紧挨截图按钮', () {
    final String text = playerSrc.readAsStringSync();
    final List<VideoControlItem> topRightItems =
        VideoControlLayout.currentChrome.itemsIn(VideoControlSlot.topRight);
    final int screenshot = topRightItems.indexOf(VideoControlItem.screenshot);
    final int clip = topRightItems.indexOf(VideoControlItem.clipExport);
    expect(screenshot, greaterThanOrEqualTo(0), reason: '顶栏应保留截图按钮');
    expect(clip, greaterThanOrEqualTo(0), reason: '顶栏应新增片段导出按钮');
    expect(clip, greaterThan(screenshot), reason: '片段导出必须放在截图按钮后面');
    expect(clip, screenshot + 1, reason: '片段导出必须紧挨截图按钮，中间不能插入其它按钮');
    expect(
      '_topBarSlotButtons(VideoControlSlot.topRight, controller'
          .allMatches(text)
          .length,
      greaterThanOrEqualTo(2),
      reason: '桌面与移动顶栏都应渲染 topRight slot',
    );
    expect(text.contains('case VideoControlItem.screenshot:'), isTrue);
    expect(text.contains('_saveScreenshot()'), isTrue);
    expect(text.contains('case VideoControlItem.clipExport:'), isTrue);
    expect(text.contains('_toggleClipExport()'), isTrue);
  });
}
