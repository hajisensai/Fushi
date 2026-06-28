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
///    `_ShelfBookSlot` 推进单一 `mergedBooks` 列表（TODO-616 B2 跨类型排序），
///    再用 `itemCount: mergedBooks.length` 渲染——证明两类卡进同一个 itemCount 网格、
///    无分区头；
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
    // TODO-616 B2 把按类型分别 itemCount 的旧写法重构为：srtBooks / epubBooks 各自
    // 构造 _ShelfBookSlot 推进单一 mergedBooks 列表，再用 mergedBooks.length 作为
    // 唯一网格的 itemCount。下列三条共同证明「SRT + EPUB 进同一个 itemCount 网格、
    // 不再按类型拆」的合并不变式（即使表达从字面 `srtBooks.length + epubBooks.length`
    // 变成 mergedBooks 列表，不变式仍成立）。
    expect(
      body.contains('srt: srtBooks[i]'),
      isTrue,
      reason: 'SRT 卡应作为 _ShelfBookSlot 进入合并列表',
    );
    expect(
      body.contains('epub: epubBooks[i]'),
      isTrue,
      reason: 'EPUB 卡应作为 _ShelfBookSlot 进入同一合并列表',
    );
    expect(
      body.contains('seq: srtBooks.length + i'),
      isTrue,
      reason: 'EPUB 默认排在 SRT 之后（seq 偏移 srtBooks.length），证明两类同序进一个网格',
    );
    expect(
      body.contains('itemCount: mergedBooks.length'),
      isTrue,
      reason: 'SRT 卡与 EPUB 卡应混排进同一网格（单一 mergedBooks 的 itemCount）',
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
