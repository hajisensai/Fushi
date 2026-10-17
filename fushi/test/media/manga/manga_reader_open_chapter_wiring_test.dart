// BUG-3246：作品页点名开某一章时把章下标显式交给阅读器；直接开书（openMedia 默认的
// buildLaunchPage）不点名，阅读器按「重新打开位置」偏好自己选章
// （mangaReaderOpenChapterIndex，判据见 manga_resume_point_test）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

MangaFushiPage _readerOf(Object page) =>
    (page as FushiAppUiScaleNeutralizer).child as MangaFushiPage;

void main() {
  test('直接开书不点名；点名版把章下标交给阅读器', () {
    final MediaItem item = MediaItem(
      mediaIdentifier: 'fushi://book/fixture',
      title: 'Fixture',
      mediaTypeIdentifier: 'reader_media_type',
      mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
      position: 0,
      duration: 1,
      canDelete: true,
      canEdit: true,
    );
    final MangaFushiPage direct = _readerOf(
      MangaFushiSource.instance.buildLaunchPage(item: item),
    );
    expect(direct.bookKey, 'fixture');
    expect(direct.initialChapterIndex, isNull);

    final MangaFushiPage named = _readerOf(
      MangaFushiSource.instance.buildChapterLaunchPage(
        item: item,
        chapterIndex: 4,
      ),
    );
    expect(named.bookKey, 'fixture');
    expect(named.initialChapterIndex, 4);
  });

  test('作品页点章开读经 launchPageBuilder 点名，不落回直接开书的偏好判据', () {
    final String src = File(
      'lib/src/media/manga/library/manga_series_page.dart',
    ).readAsStringSync();
    expect(src, contains('await _openReader(bookKey, chapterIndex: index);'));
    expect(
      src,
      contains(
        '.buildChapterLaunchPage(item: launchItem, chapterIndex: chapterIndex)',
      ),
    );
  });
}
