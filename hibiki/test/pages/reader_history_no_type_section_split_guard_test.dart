import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-902 守卫：书架愤怒回归——用户「我之前好好的书怎么变成 epub书库 和
/// 字幕有声书 分组了，改回去」。`f709b288e` 把书架按类型拆成「字幕有声书 /
/// EPUB 书库」两个分区头（`t.srt_books_section` / `t.section_epub`），无开关、
/// 默认即分组。方案 A 回退：删两个分区头，SRT 卡与 EPUB 卡混排进单一网格。
///
/// 本守卫断言书架 body（`_buildBodyWithSrtBooks`）：
/// 1. 不再用 `_buildSectionHeader` 渲染 `t.srt_books_section` / `t.section_epub`；
/// 2. SRT 与 EPUB 合并进同一网格（itemCount 含 `srtBooks.length + epubBooks.length`）；
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
    expect(
      body.contains('srtBooks.length + epubBooks.length'),
      isTrue,
      reason: 'SRT 卡与 EPUB 卡应混排进同一网格（合并 itemCount）',
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
