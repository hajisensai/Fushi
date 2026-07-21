import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-963 guard：书架标签筛选时合集内有声书成员丢封面。
///
/// 根因：`_buildBodyWithSrtBooks` 里三张「从 EPUB 借用」的展示映射
/// （封面 `epubCoverUrisByBookKey` / 有 EPUB 背书门控 `epubBackedBookKeys` /
/// 借用进度 `epubProgressByBookKey`）以前遍历**筛选后的 `books` 参数**构建。
/// 合集内只给有声书(SRT)打了标签、关联 EPUB 未命中同一标签时，EPUB 被
/// `filteredBookIdsProvider` 筛掉 → 映射里查不到 → SRT 成员卡（BUG-937 让被筛
/// 合集能带命中成员显示）借不到关联 EPUB 封面 → 回退占位图 = 丢封面。
///
/// 修复：借用映射改以**未筛选全量** `ref.read(hibikiBooksProvider(...))`
/// （变量 `allEpubBooksForBorrow`）为源，与「参与网格展示的筛选后列表」解耦。
/// 借用是纯展示数据，不该被标签筛选裁剪。此守卫锁死数据来源不回归。
void main() {
  final String source = File(
    'lib/src/pages/implementations/reader_hibiki_history_page.dart',
  ).readAsStringSync();

  // 切出 _buildBodyWithSrtBooks 方法体（到下一个方法 _buildShelfGroupSlivers 为止），
  // 避免误命中文件别处同名字面量。
  String buildBody() {
    const String start = 'Widget _buildBodyWithSrtBooks(';
    const String end = 'List<Widget> _buildShelfGroupSlivers(';
    final int startIdx = source.indexOf(start);
    final int endIdx = source.indexOf(end);
    expect(startIdx, greaterThanOrEqualTo(0),
        reason: '找不到 _buildBodyWithSrtBooks');
    expect(endIdx, greaterThan(startIdx), reason: '找不到方法体结束锚点');
    return source.substring(startIdx, endIdx);
  }

  test('借用映射源 = 未筛选全量 hibikiBooksProvider，而非筛选后的 books 参数', () {
    final String body = buildBody();
    // 全量来源变量必须存在，且取自 hibikiBooksProvider（未过滤真值），
    // 空态兜底回退到 books 参数。
    expect(
      body.contains(RegExp(
          r'final List<MediaItem> allEpubBooksForBorrow\s*=\s*\n?\s*ref\.read\(hibikiBooksProvider\(appModel\.targetLanguage\)\)\.valueOrNull\s*\?\?')),
      isTrue,
      reason: '借用映射源须为 ref.read(hibikiBooksProvider(...)) 全量列表，'
          'valueOrNull 为空时回退 books',
    );
    // 三张借用映射的唯一装配循环必须遍历全量 allEpubBooksForBorrow。
    expect(
      body,
      contains('for (final MediaItem item in allEpubBooksForBorrow)'),
      reason: '封面/背书/进度三张映射须遍历未筛选全量列表装配',
    );
  });

  test('回归哨兵：装配循环不得再遍历筛选后的 books 参数', () {
    final String body = buildBody();
    // 旧写法 `for (final MediaItem item in books)` 会让筛选时借用映射被裁剪，
    // 复现丢封面。注意 `epubBooks = books.where(...)` 的展示列表过滤仍合法，
    // 只锁死借用映射的 for-in 循环不得以 books 为源。
    expect(
      body.contains(RegExp(r'for\s*\(\s*final MediaItem item in books\s*\)')),
      isFalse,
      reason: '借用映射循环不得遍历筛选后的 books（会让筛选时合集成员丢封面）',
    );
  });

  test('封面映射最终写入 _epubCoverUrisByBookKey 字段供成员卡读取', () {
    final String body = buildBody();
    expect(
      body,
      contains('epubCoverUrisByBookKey[key] = imageUrl'),
      reason: '须收录每本 EPUB 的封面 imageUrl',
    );
    expect(
      body,
      contains('_epubCoverUrisByBookKey = epubCoverUrisByBookKey'),
      reason: '须把本帧封面映射赋给字段，供 _buildSrtCard 借用',
    );
  });
}
