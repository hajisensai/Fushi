import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

import '../helpers/source_guard.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 守卫：书架保留自己的导入顺序；视频常规入库与整库刮削统一迁到「来源」后，
/// HomeVideoPage 页头不得重新长出这两个入口，收藏夹仍须排在统计之前。
void main() {
  final File videoSrc =
      File('lib/src/pages/implementations/home_video_page.dart');
  final File shelfSrc =
      File('lib/src/pages/implementations/reader_hibiki_history_page.dart');

  /// 截取某文件中 [_buildPageHeader] 方法体内 actions 列表字面量的源码，顺序断言只在
  /// 该区间内做，避免命中页面其它位置的同名 tooltip / 图标。
  ///
  /// 两种等价写法都认：内联的 `actions: <Widget>[`，以及先落成局部变量再传的
  /// `List<Widget> actions = <Widget>[`（页头统一成 [HibikiPageHeader] 后走后者）。
  /// 区间终点用方括号配对求出，而不是「下一个 `],`」——后者在列表以 `];` 收尾时会
  /// 直接越过方法体，把断言范围放大到整个文件。
  ///
  /// 起点必须命中**定义**而不是调用点。两个语料文件里裸名 `_buildPageHeader` 都是
  /// 先命中调用点（`home_video_page.dart` 的 `if (!isCupertinoPlatform(context))
  /// _buildPageHeader(canImport)` / `reader_hibiki_history_page.dart` 的
  /// `_buildPageHeader()`），定义在几百上千行之后。用裸名 `indexOf` 定起点的话，
  /// 只要将来有人在调用点与定义之间写一个持有 `actions = <Widget>[` 的**无关方法**，
  /// 切出来的就是那个方法的列表，真实页头的顺序回归会静默漏掉（复核方 MUT_G 已实证
  /// 此形态下守卫仍绿）。
  ///
  /// 这里用 [methodBody] 按花括号配对截出方法体：起点签名带 `Widget ` 前缀，只会命中
  /// 定义；终点由源码结构给出，不再是裸名 + 全文件后缀。
  String headerActionsBlock(File file) {
    final String text = methodBody(
      file.readAsStringSync(),
      'Widget _buildPageHeader(',
    );
    int actionsIdx = text.indexOf('List<Widget> actions = <Widget>[');
    final int inlineIdx = text.indexOf('actions: <Widget>[');
    if (actionsIdx < 0 || (inlineIdx >= 0 && inlineIdx < actionsIdx)) {
      actionsIdx = inlineIdx;
    }
    expect(actionsIdx, greaterThanOrEqualTo(0),
        reason: '${file.path} 的 _buildPageHeader 应有 actions 列表字面量'
            '（`actions: <Widget>[` 或 `List<Widget> actions = <Widget>[`）');
    final int openIdx = text.indexOf('[', actionsIdx);
    expect(openIdx, greaterThanOrEqualTo(0),
        reason: '${file.path} 的 actions 列表应有起始方括号');
    int depth = 0;
    int closeIdx = -1;
    for (int i = openIdx; i < text.length; i++) {
      final String ch = text[i];
      if (ch == '[') {
        depth++;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) {
          closeIdx = i;
          break;
        }
      }
    }
    expect(closeIdx, greaterThan(openIdx),
        reason: '${file.path} 的 actions 列表应正常闭合');
    return text.substring(openIdx, closeIdx);
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

  test('视频顶栏移除导入/全部刮削，仍为收藏夹 → 统计', () {
    final String block = headerActionsBlock(videoSrc);
    final int importIdx = orderOf(block, 't.video_import_action');
    final int scrapeIdx = orderOf(block, 't.scrape_all');
    final int collectionsIdx = orderOf(block, 't.collections');
    final int statsIdx = orderOf(block, 't.video_statistics');
    expect(importIdx, -1, reason: '视频常规入库应统一从来源添加文件夹');
    expect(scrapeIdx, -1, reason: '视频全部刮削入口应位于来源页');
    expect(collectionsIdx, greaterThanOrEqualTo(0), reason: '视频应有收藏夹按钮');
    expect(statsIdx, greaterThanOrEqualTo(0), reason: '视频应有统计按钮');
    expect(collectionsIdx, lessThan(statsIdx), reason: '视频收藏夹按钮应在统计之前');
  });

  test('视频空库不再提供单视频 CTA，只提示从来源添加文件夹', () {
    final String body = methodBody(
      videoSrc.readAsStringSync(),
      'Widget _buildEmpty()',
    );
    expect(body, contains('t.video_library_empty_source_hint'));
    expect(body, isNot(contains('home_video_empty_import')));
    expect(body, isNot(contains('t.video_import_action')));
    expect(body, isNot(contains('FilledButton')));
  });

  test('播放器顶栏片段导出按钮紧挨截图按钮', () {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料
    // （+端点 `\n}`）；topRight slot 渲染的两处调用现落在 part 末段，须读主壳+全部 part。
    final String text = readVideoHibikiSource();
    final List<VideoControlItem> topRightItems =
        VideoControlLayout.currentChrome.itemsIn(VideoControlSlot.topRight);
    final int screenshot = topRightItems.indexOf(VideoControlItem.screenshot);
    final int clip = topRightItems.indexOf(VideoControlItem.clipExport);
    expect(screenshot, greaterThanOrEqualTo(0), reason: '顶栏应保留截图按钮');
    expect(clip, greaterThanOrEqualTo(0), reason: '顶栏应新增片段导出按钮');
    expect(clip, greaterThan(screenshot), reason: '片段导出必须放在截图按钮后面');
    expect(clip, screenshot + 1, reason: '片段导出必须紧挨截图按钮，中间不能插入其它按钮');
    expect(
      RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topRight')
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

  test('默认右上角顶栏精简为 6 个常用入口（TODO-642）', () {
    // 默认 topRight = episodeList / screenshot / clipExport / subtitleTrack /
    // audioTrack / chapterList 六个；prev/next 集与 prev/next 章 4 个导航键不再
    // 默认占顶栏（落 hidden / removed，可从编辑器拖回）。screenshot 与 clipExport
    // 保持相邻（受上一个守卫钉死）。
    final List<VideoControlItem> topRight =
        VideoControlLayout.currentChrome.itemsIn(VideoControlSlot.topRight);
    expect(
        topRight,
        <VideoControlItem>[
          VideoControlItem.episodeList,
          VideoControlItem.screenshot,
          VideoControlItem.clipExport,
          VideoControlItem.subtitleTrack,
          VideoControlItem.audioTrack,
          VideoControlItem.chapterList,
        ],
        reason: 'TODO-642：默认右上角顶栏精简为 6 个常用入口');

    // 4 个 prev/next 导航键默认不在任何可见槽，落 removedItems（仍可自定义拖回）。
    const List<VideoControlItem> trimmedNav = <VideoControlItem>[
      VideoControlItem.previousEpisode,
      VideoControlItem.nextEpisode,
      VideoControlItem.previousChapter,
      VideoControlItem.nextChapter,
    ];
    for (final VideoControlItem nav in trimmedNav) {
      expect(VideoControlLayout.currentChrome.isOnPlayer(nav), isFalse,
          reason: '$nav 默认不应在播放器可见槽（TODO-642）');
      expect(VideoControlLayout.currentChrome.removedItems, contains(nav),
          reason: '$nav 默认落 removedItems，可从编辑器面板拖回（非从模型删除）');
      // 仍是可自定义项：能被拖回任意可见槽。
      expect(nav.canMoveToSlot(VideoControlSlot.topRight), isTrue,
          reason: '$nav 仍可被用户加回 topRight');
    }
  });
}
