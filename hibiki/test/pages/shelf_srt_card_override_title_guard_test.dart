import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

/// TODO-1094 guard: 书架 SRT/字幕卡的书名必须与长按对话框同源（经
/// [MediaSource.getDisplayTitleFromMediaItem] 应用编辑弹窗写入的 override_title），
/// 且无封面时长按对话框显示占位图标而非整块隐藏封面区，与网格 `_buildSrtCover`
/// 的占位判据统一。
///
/// 用源码扫描 + [MediaItemDialogPage] 构造契约锁死两处根因，避免以下回归：
///   Bug1：网格卡直接读 DB 原始列 `book.title`，忽略 override → 编辑书名不生效。
///   Bug2：SRT 无自选封面且未关联 EPUB 封面时长按对话框整块隐藏封面（网格却有
///          占位图标），显示不一致。
void main() {
  final String booksPart =
      File('lib/src/pages/implementations/reader_history/books.part.dart')
          .readAsStringSync();
  final String dialogPage =
      File('lib/src/pages/implementations/media_item_dialog_page.dart')
          .readAsStringSync();

  test('Bug1: 网格 SRT 卡书名经 getDisplayTitleFromMediaItem 而非直读 book.title', () {
    // The SRT grid card must derive its title from the same media item + source
    // display-title logic the long-press dialog uses, so an edited override name
    // shows up in both.
    expect(
      booksPart,
      contains('mediaSource.getDisplayTitleFromMediaItem(srtItem)'),
      reason: 'SRT 卡书名必须经 getDisplayTitleFromMediaItem 应用 override',
    );
    // Regression sentinel: the grid card layout (`_bookCardLayout`) must not feed
    // the raw DB column as the display title again. `_srtBookMediaItem` still
    // carries `title: book.title` as the item's raw title (override is applied on
    // top by getDisplayTitleFromMediaItem), so we scope the check to the card
    // layout call, which must consume `displayTitle`.
    expect(
      booksPart,
      contains(RegExp(r'child: _bookCardLayout\(\s*title: displayTitle,')),
      reason: '网格卡布局须消费 displayTitle（经 override），不得直读 book.title',
    );
  });

  test('Bug2: SRT 长按对话框传入 coverFallbackIcon 作占位', () {
    expect(
      booksPart,
      contains('coverFallbackIcon:'),
      reason: 'SRT 长按对话框须传 coverFallbackIcon 以显示占位封面',
    );
    // The dialog must render a fallback cover when there is no real cover and a
    // fallback icon is supplied (instead of hiding the whole cover block).
    expect(
      dialogPage,
      contains('_buildFallbackCover'),
      reason: '对话框须在无封面且有 fallback 图标时渲染占位封面块',
    );
  });

  testWidgets('MediaItemDialogFrame 在传入占位封面 widget 时渲染封面块（而非隐藏）',
      (WidgetTester tester) async {
    const Key fallbackKey = ValueKey<String>('srt-fallback-cover');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MediaItemDialogFrame(
              cover: SizedBox(
                key: fallbackKey,
                width: 260,
                height: 120,
                child: Center(child: Icon(Icons.subtitles_outlined)),
              ),
              title: 'SRT no cover',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // With a fallback cover widget supplied the dialog renders the cover block
    // (matching the grid placeholder), never an empty gap.
    expect(find.byKey(fallbackKey), findsOneWidget);
    expect(find.byIcon(Icons.subtitles_outlined), findsOneWidget);
  });
}
