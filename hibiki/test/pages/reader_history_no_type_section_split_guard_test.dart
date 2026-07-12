import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-902 守卫：书架愤怒回归——用户「我之前好好的书怎么变成 epub书库 和
/// 字幕有声书 分组了，改回去」。`f709b288e` 把书架按类型拆成「字幕有声书 /
/// EPUB 书库」两个分区头（`t.srt_books_section` / `t.section_epub`），无开关、
/// 默认即分组。方案 A 回退：删两个分区头，SRT 卡与 EPUB 卡混排进单一网格。
///
/// 本守卫断言书架 body（`_buildBodyWithSrtBooks`）：
/// 1. 不再用 `_buildSectionHeader` 渲染 `t.srt_books_section` / `t.section_epub`；
/// 2. SRT 与 EPUB 合并进同一网格：把 srtBooks 与 epubBooks 各自构造成
///    `_ShelfBookSlot` payload 合进单一 `shelfGroups`（TODO-616 A2 分组 + 跨类型排序），
///    再用 `itemCount: shelfGroups.length` 渲染——证明两类卡（+ 系列卡）进同一个
///    itemCount 网格、无分区头；
/// 3. 视频分区头 `t.shelf_video_section` 保持不动（本回归不碰视频）。
///
/// 纯静态切片守卫——书架页依赖 WebView/DB，整页 pumpWidget 过重，故沿用本仓库
/// `*_static_test` 的源码切片范式。i18n key 仍保留（向后兼容，仅不再渲染）。
void main() {
  const String path =
      'lib/src/pages/implementations/reader_hibiki_history_page.dart';

  String readBody() {
    final String source = File(path).readAsStringSync();
    const String start = 'Widget _buildBodyWithSrtBooks(';
    const String end = 'Widget _buildSectionHeader(';
    final int startIdx = source.indexOf(start);
    final int endIdx = source.indexOf(end);
    expect(startIdx, greaterThanOrEqualTo(0),
        reason: '_buildBodyWithSrtBooks 应存在');
    expect(endIdx, greaterThan(startIdx), reason: '_buildSectionHeader 应在其后');
    return source.substring(startIdx, endIdx);
  }

  test('书架 body 不再渲染 srt/epub 类型分区头（TODO-902 回退）', () {
    final String body = readBody();
    expect(
      body.contains('_buildSectionHeader(t.srt_books_section)'),
      isFalse,
      reason: '不应再有「字幕有声书」分区头',
    );
    expect(
      body.contains('_buildSectionHeader(t.section_epub)'),
      isFalse,
      reason: '不应再有「EPUB 书库」分区头',
    );
  });

  test('书架 body 把 SRT 与 EPUB 合并进单一网格', () {
    final String body = readBody();
    // 单一 mergedBooks 列表经 groupByCollections 分组：srtBooks / epubBooks 各自构造
    // 成 CollectionOrderingItem<_ShelfBookSlot>（payload 仍是 _ShelfBookSlot，srt/epub
    // 各填一个），合进单一 shelfItems → shelfGroups 交错渲染。散书每条单独成 group、
    // 合集聚成一行，但**依旧无类型分区头**。下列共同证明「SRT + EPUB 进同一合并列表、
    // 不再按类型拆」的合并不变式。
    expect(
      body.contains('_ShelfBookSlot(srt: srt)'),
      isTrue,
      reason: 'SRT 卡应作为 _ShelfBookSlot payload 进入合并列表',
    );
    expect(
      body.contains('_ShelfBookSlot(epub: epub)'),
      isTrue,
      reason: 'EPUB 卡应作为 _ShelfBookSlot payload 进入同一合并列表',
    );
    // BUG-756：seq 假名次已删——两类同进一个 shelfItems 列表（SRT 段在前、EPUB
    // 段在后的字面顺序即合并证据），排序量纲改由 compareShelfSortKeys 推导。
    expect(
      body.contains('for (final SrtBook srt in srtBooks)') &&
          body.contains('for (final MediaItem epub in epubBooks)'),
      isTrue,
      reason: 'SRT 与 EPUB 必须构造进同一合并列表（无类型分区）',
    );
    // UI v2 Phase C 后单一 shelfGroups 交给 _buildShelfGroupSlivers 保序交错
    // （合集=横排行、连续散书段=网格）。SRT/EPUB 仍在同一合并列表、同段网格混排
    // （itemCount: segment.length），**依旧没有按类型拆的分区头**——本守卫保护的
    // 不变量不变，只是渲染载体从单网格换成交错 slivers。
    expect(
      body.contains('..._buildShelfGroupSlivers('),
      isTrue,
      reason: '单一合并 shelfGroups 必须整体交给交错渲染（无类型拆分）',
    );
    expect(
      body.contains('itemCount: segment.length'),
      isTrue,
      reason: '散书段落（SRT+EPUB 混排）共用同一网格段',
    );
  });

  test('视频分区头保持不动（本回归不碰视频）', () {
    final String body = readBody();
    expect(
      body.contains('_buildSectionHeader(t.shelf_video_section)'),
      isTrue,
      reason: '视频分区头应保留',
    );
  });
}
