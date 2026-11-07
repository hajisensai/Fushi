import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_study_stats.dart';
import 'package:fushi/src/reader/reader_statistics_sheet.dart'
    show ReaderPositionSnapshot;

import '../../helpers/source_guard.dart';

void main() {
  group('mangaStatsPosition（统计侧栏位置读口）', () {
    test('本地卷：本章 = 当前页（从 1 起）/ 页数，没有章序', () {
      final ReaderPositionSnapshot p = mangaStatsPosition(
        currentPage: 0,
        pageCount: 24,
        chapterIndex: -1,
        chapterCount: 0,
      );
      expect(p.chapterCurrent, 1);
      expect(p.chapterTotal, 24);
      expect(p.bookCurrent, isNull);
      expect(p.bookTotal, isNull);
    });

    test('书架在线条目：章表按新→旧，章序 = 章数 − 下标（最旧一话是第 1 章）', () {
      final ReaderPositionSnapshot oldest = mangaStatsPosition(
        currentPage: 9,
        pageCount: 20,
        chapterIndex: 4,
        chapterCount: 5,
      );
      expect(oldest.chapterCurrent, 10);
      expect(oldest.bookCurrent, 1);
      expect(oldest.bookTotal, 5);
      final ReaderPositionSnapshot newest = mangaStatsPosition(
        currentPage: 19,
        pageCount: 20,
        chapterIndex: 0,
        chapterCount: 5,
      );
      expect(newest.chapterCurrent, 20);
      expect(newest.bookCurrent, 5);
    });

    test('没有正文（未装好 / 本章未下载）页数两项为 null；下标越界章序为 null', () {
      final ReaderPositionSnapshot p = mangaStatsPosition(
        currentPage: 3,
        pageCount: 0,
        chapterIndex: 7,
        chapterCount: 5,
      );
      expect(p.chapterCurrent, isNull);
      expect(p.chapterTotal, isNull);
      expect(p.bookCurrent, isNull);
      expect(p.bookTotal, isNull);
    });

    test('当前页夹进 [1, 页数]（换章瞬间旧页号越过新章页数）', () {
      expect(
        mangaStatsPosition(
          currentPage: 40,
          pageCount: 12,
          chapterIndex: -1,
          chapterCount: 0,
        ).chapterCurrent,
        12,
      );
    });
  });

  group('mangaStudyContentAbsent（页内遮挡判据）', () {
    test('加载失败 / 本章未下载 = 屏上没有可读正文，停表；都没有 = 照常计', () {
      expect(
        mangaStudyContentAbsent(loadFailed: false, chapterNotDownloaded: false),
        isFalse,
      );
      expect(
        mangaStudyContentAbsent(loadFailed: true, chapterNotDownloaded: false),
        isTrue,
      );
      expect(
        mangaStudyContentAbsent(loadFailed: false, chapterNotDownloaded: true),
        isTrue,
      );
    });
  });

  group('漫画页学习计时接线（源码守卫：整页过重，无法在 widget test 拉起）', () {
    final String src = maskComments(
      File(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n'),
    );

    test('页内遮挡唯一喂点在 setState 覆写里，按 mangaStudyContentAbsent 判', () {
      final String body = methodBody(src, '  void setState(VoidCallback fn) {');
      expect(body, contains('super.setState(fn);'));
      expect(body, contains('_studyClockGate.setLocallyCovered('));
      expect(body, contains('mangaStudyContentAbsent('));
      expect(
        '.setLocallyCovered('.allMatches(src).length,
        1,
        reason: '页内遮挡只许一个喂点，散落各处必有漏喂',
      );
    });

    test('手动暂停只经 StudyClockRunGate（控制条计时键 + 统计侧栏暂停键同一入口）', () {
      expect(
        methodBody(src, '  void _toggleStudyClockManualPause() {'),
        contains('_studyClockGate.toggleManualPause'),
      );
      expect(
        src,
        contains('onTogglePause: _toggleStudyClockManualPause'),
        reason: '统计侧栏 hero 的暂停键与控制条计时键必须是同一执行体',
      );
      expect(
        src,
        contains('onPressed: _toggleStudyClockManualPause'),
        reason: '控制条 studyTimer 键',
      );
      // 页面不许绕过门直接起停表（关书 onSourcePagePop 的 stop 除外：那是退出）。
      expect(
        '_studyClock?.start()'.allMatches(src),
        isEmpty,
        reason: '起表只经 _studyClockGate 的判据',
      );
    });

    test('统计侧栏：漫画口径 + 路由构造时声明豁免（侧栏不遮正文，开着照常计时）', () {
      final String open = methodBody(
        src,
        '  Future<void> _openMangaStatistics() async {',
      );
      expect(open, contains('showReaderSideSheet<void>('));
      expect(open, contains('studyClockTransparentWhen: transparent'));
      expect(open, contains('media: ReaderStatsMedia.manga'));
      expect(open, contains('sessionPages: () => _studyClock?.sessionPages'));
      // 「打开完整记录」先关侧栏再 push 统计中心（被路由盖住自动停表）。
      expect(open, contains('_openStatisticsCenter()'));
      expect(
        methodBody(src, '  Future<void> _openStatisticsCenter() async {'),
        contains('StatsCenterTab.reading'),
      );
      expect(
        methodBody(
          src,
          '  Future<ReaderBookStatTotals> _loadMangaBookStatTotals() async {',
        ),
        contains('bookKey: widget.bookKey'),
        reason: '本书统计身份必须与时钟 mediaKey 同为 widget.bookKey（永不按 title 认）',
      );
    });
  });
}
