import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

/// 守卫：阅读器「阅读统计」按钮必须是布局模型里的一颗真按钮（任何槽位都能放），
/// 点击开统计侧栏、有稳定 semantics id、沿用既有 i18n key。
///
/// 由来：移动端此前唯一的统计入口是「齿轮 → 快速设置 sheet → 阅读统计行」三步。
/// 2026-09-13 起顶栏 / 底栏按钮全部由 [ReaderControlLayout] 驱动（与视频页同一套
/// 泛型布局），按钮「按下去干什么」的唯一真相源是 `_readerControlAction`，
/// 「此刻有没有」是 `_shouldRenderReaderControl`——本守卫钉这两处，而不是钉某条
/// 硬编码的底栏 Row（那条 Row 已不存在）。
///
/// 静态守卫而非 widget 测试：这些方法长在 `_ReaderFushiPageState` 的私有 build 路径
/// 里，渲染它要整页起 WebView（真 InAppWebView 平台视图），测试环境跑不动。
String _member(String src, String signature, String nextMarker) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 `$signature`，请更新守卫。');
  final int end = src.indexOf(nextMarker, start + signature.length);
  expect(end, greaterThanOrEqualTo(0), reason: '找不到 `$nextMarker`，请更新守卫。');
  return src.substring(start, end);
}

void main() {
  group('阅读器统计按钮守卫（布局模型）', () {
    // expect 只能在 test 体内调：切片放 setUpAll。
    late String src;
    late String action;
    late String render;
    setUpAll(() {
      src = readReaderPageSource();
      action = _member(
        src,
        '  ReaderHeaderAction _readerControlAction(ReaderControlItem item) {',
        '  List<ReaderHeaderAction> _readerControlActionsIn(',
      );
      render = _member(
        src,
        '  bool _shouldRenderReaderControl(ReaderControlItem item) {',
        '  List<ReaderControlItem> _renderableControlsIn(',
      );
    });

    test('统计按钮点击开统计侧栏、有稳定 semantics id、沿用既有 i18n key', () {
      final int at = action.indexOf('case ReaderControlItem.statistics:');
      expect(at, greaterThanOrEqualTo(0));
      final String stats = action.substring(
        at,
        action.indexOf('case ReaderControlItem.title:', at),
      );
      expect(stats, contains("semanticsId: 'hibiki.reader.header.statistics'"),
          reason: '集成测试按这个 identifier 找控件');
      expect(stats, contains('onPressed: _openReadingStatistics'),
          reason: '统计键点击必须开阅读统计侧栏');
      expect(stats, contains('t.reading_statistics'),
          reason: '沿用既有 i18n key，不新造');
      expect(stats, isNot(contains('_toggleStudyClockManualPause')),
          reason: '点击语义恒为「打开统计」，停 / 续表在侧栏与状态行计时块上做');
    });

    test('统计按钮任何模式都渲染；目录 / 插图只在正文模式', () {
      // 与 _readerControlAction 同一张 switch：statistics 归在恒 true 那一组。
      final String alwaysGroup = render.substring(
        render.indexOf('case ReaderControlItem.back:'),
        render.indexOf('return true;'),
      );
      expect(alwaysGroup, contains('case ReaderControlItem.statistics:'));
      expect(alwaysGroup, contains('case ReaderControlItem.settings:'));
      final String navGroup = render.substring(
        render.indexOf('case ReaderControlItem.navigation:'),
        render.indexOf('case ReaderControlItem.audiobook:'),
      );
      expect(navGroup, contains('return !_lyricsMode;'),
          reason: '歌词页翻章会把歌词文档换成 EPUB 章节，目录 / 插图只在正文模式挂');
    });

    test('顶栏 / 底栏都从布局槽位取按钮，不再硬编码 barItems', () {
      final String header = _member(
        src,
        '  Widget _buildDesktopHeader() {',
        '  /// 顶部工具栏「统计」',
      );
      expect(
          header,
          contains(
              'leading: _readerControlActionsIn(ReaderControlSlot.topLeft)'));
      expect(
          header,
          contains(
              'trailing: _readerControlActionsIn(ReaderControlSlot.topRight)'));
      final String bottom = _member(
        src,
        '  Widget _buildSettingsBar() {',
        "  // TODO-796: resolve a TOC entry's href",
      );
      expect(bottom, contains('_bottomSlotButtons()'));
      expect(
          bottom, contains('reversed ? barItems.reversed.toList() : barItems'),
          reason: '「反转底栏」仍是整体镜像');
      expect(bottom, isNot(contains('IconButton(')),
          reason: '底栏不再手写任何一颗按钮，全部来自布局槽位');
    });

    test('有声书播放条在场时底栏槽位按钮并进它的右端', () {
      final String bar = _member(
        src,
        '  Widget _buildAudiobookBar() {',
        '  Widget? _buildAudiobookBarTrailing() {',
      );
      expect(bar, contains('trailing: _buildAudiobookBarTrailing(),'));
      final String trailing = _member(
        src,
        '  Widget? _buildAudiobookBarTrailing() {',
        '  /// 小说页的窗口全屏切换',
      );
      expect(trailing, contains('_readerControlActionsIn(slot)'));
      expect(
          trailing, contains('_playbackStatusInline ? _buildBarStatusText()'),
          reason: '状态读数仍是播放条右端的落点');
    });
  });
}
