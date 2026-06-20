import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reader quick settings owns the in-book settings hierarchy', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('class ReaderQuickSettingsSheet'));
    expect(source, contains("page: 'layout'"));
    expect(source, contains("page: 'behavior'"));
    expect(source, contains("page: 'location'"));
    expect(source, contains("page: 'audiobook'"));
    expect(source, isNot(contains('class AudiobookSettingsSheet')));
  });

  test('reader quick settings home inlines the appearance controls', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    final String mainSource = _between(
      source,
      '  Widget _buildMainPage(BuildContext context, ThemeData theme)',
      '  Widget _buildSubPage(BuildContext context, ThemeData theme)',
    );

    // 外观已平铺到主页（窄窗），不再有独立的「外观」导航子页 push 入口。
    expect(mainSource, contains('_buildAppearanceInline(theme)'));
    // 宽窗 master-detail 用 `id: 'appearance'`（非 `page: 'appearance'` push）。
    expect(source, isNot(contains("page: 'appearance'")));
    expect(source, isNot(contains('Widget _buildQuickControlsSection(')));

    // 窄窗内联包装仍是单张等宽卡（一个 AdaptiveSettingsSection）。
    final String inlineSource = _between(
      source,
      '  Widget _buildAppearanceInline(ThemeData theme)',
      '  List<Widget> _appearanceCardChildren()',
    );
    expect('AdaptiveSettingsSection('.allMatches(inlineSource).length, 1);

    // 复用的外观行集合（窄窗内联 + 宽窗右 pane 共用）：主题行 + appearance
    // schema 裸行 + 编辑书籍CSS（最后一行，非独立卡）。
    final String cardSource = _between(
      source,
      '  List<Widget> _appearanceCardChildren()',
      '  Widget _buildAppearanceDetail()',
    );
    expect(cardSource, contains('buildThemeSelector(_themeSettingsContext())'));
    expect(cardSource, contains('ReaderGroup.appearance'));
    // appearance schema 行用 buildSectionRows 取「裸行」（非 buildDetailContent
    // 的 ListView+整页内边距），才能与下方导航卡等宽。
    expect(cardSource, contains('buildSectionRows('));
    expect(cardSource, contains('book_css_editor_edit_css'));
    // 主题不再是独立卡：内联区不再用旧的 _buildThemeSelector() 包装方法。
    expect(source, isNot(contains('Widget _buildThemeSelector()')));
  });

  test('reader quick settings sheet uses shared MD3 sheet chrome', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    // sheet 外壳骨架已抽到共享 HibikiMasterDetailSettingsSheet（TODO-583）：阅读器
    // 经它进入 PopScope + HibikiModalSheetFrame + master-detail；frame / maxHeightFactor
    // 的断言下沉到 master_detail_settings_sheet_test。这里只锁阅读器仍走共享外壳，
    // 且没退回旧的 SafeArea / 2px 拖拽手柄 bespoke chrome。
    expect(source, contains('HibikiMasterDetailSettingsSheet('));
    expect(source, isNot(contains('child: SafeArea(')));
    expect(source, isNot(contains('BorderRadius.circular(2)')));
  });

  test('reader quick settings action buttons use shared MD3 icon controls', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    // 返回页头已抽到共享 HibikiSettingsSubPageHeader（TODO-583）：从共享文件读它。
    final String sharedSheetSource =
        File('lib/src/settings/master_detail_settings_sheet.dart')
            .readAsStringSync();
    final String headerSource = _between(
      sharedSheetSource,
      'class HibikiSettingsSubPageHeader',
      'class HibikiMasterDetailSettingsSheet',
    );
    final String favoriteActionSource = _between(
      source,
      'class _InBookIconButton',
      'class _RepeatIconButton',
    );
    final String repeatActionSource = _between(
      source,
      'class _RepeatIconButton',
      source.length,
    );

    expect(source, contains('HibikiIconButton('));
    expect(source, contains('class _InBookIconButton'));
    expect(source, contains('class _RepeatIconButton'));
    for (final String actionSource in <String>[
      headerSource,
      favoriteActionSource,
      repeatActionSource,
    ]) {
      final String normalized = _withoutSharedIconButton(actionSource);
      expect(normalized, isNot(contains('return IconButton(')));
      expect(normalized, isNot(contains('child: IconButton(')));
      expect(actionSource,
          isNot(contains('visualDensity: VisualDensity.compact')));
    }
    expect(
      favoriteActionSource,
      isNot(contains('constraints: const BoxConstraints(minWidth: 32')),
    );

    final String inBookSource = _between(
      source,
      '  Widget _buildSearchSection(ThemeData theme)',
      'class _InBookTocRow',
    );
    expect(inBookSource, contains('HibikiIconButton('));
    expect(inBookSource, isNot(contains('FilledButton.tonal(')));
    expect(inBookSource, isNot(contains('VisualDensity.compact')));
  });

  test('audiobook play bar restores the MD3 filled-tonal play frame (TODO-297)',
      () {
    // 代际守卫翻转：48a8d2044 曾把播放条全部按钮换成扁平的 HibikiIconButton，
    // TODO-297 把主操作（播放/暂停）还原成原生 [IconButton.filledTonal]（MD3 圆框
    // + state-layer + ripple），其余键（上一句/下一句/follow/设置）还原成无框原生
    // [IconButton]。锁住「图标 + 圆框 md3」旧观感不再回退到扁平自定义按钮。
    final String source =
        File('lib/src/media/audiobook/audiobook_play_bar.dart')
            .readAsStringSync();

    // 播放/暂停键是 filled-tonal 圆框。
    expect(source, contains('IconButton.filledTonal('));
    // 不再用扁平的共享 HibikiIconButton 渲染播放条按钮。
    expect(source, isNot(contains('HibikiIconButton(')));
  });

  test('reader quick settings sheet uses MD3 spacing tokens', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, isNot(contains('const SizedBox(height: 12)')));
    expect(source, isNot(contains('const SizedBox(height: 8)')));
    expect(source, isNot(contains('const SizedBox(width: 8)')));
    expect(
        source, isNot(contains('padding: const EdgeInsets.only(bottom: 8)')));
    expect(
        source, isNot(contains('contentPadding: const EdgeInsets.symmetric(')));
    expect(source,
        isNot(contains('padding: const EdgeInsets.symmetric(horizontal: 12')));
    expect(source,
        isNot(contains('padding: const EdgeInsets.symmetric(vertical: 12')));
    expect(source, isNot(contains('spacing: 6')));
    expect(source, isNot(contains('runSpacing: 6')));
    expect(source, isNot(contains('const SizedBox(height: 4)')));
    expect(source, isNot(contains('const SizedBox(width: 4)')));
    expect(source, isNot(contains('const SizedBox(width: 6)')));
    expect(source, isNot(contains('const SizedBox(width: 10)')));
    expect(source, isNot(contains('const SizedBox(height: 2)')));
    expect(source, isNot(contains('top: 12,')));
    expect(source, isNot(contains('bottom: 4,')));
    expect(source, isNot(contains('start: (cupertino ? 16 : 12)')));
  });

  test('reader quick settings section headings use shared settings chrome', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('SettingsSectionHeader('));
    expect(source, isNot(contains('style: theme.textTheme.titleMedium')));
  });

  test('in-book settings header uses theme typography without hardcoded size',
      () {
    // 返回页头已抽到共享 HibikiSettingsSubPageHeader（TODO-583）：扫共享文件。
    final String source =
        File('lib/src/settings/master_detail_settings_sheet.dart')
            .readAsStringSync();
    final String headerSource = source.substring(
      source.indexOf('class HibikiSettingsSubPageHeader'),
      source.indexOf('class HibikiMasterDetailSettingsSheet'),
    );

    expect(headerSource, contains('navTitleTextStyle'));
    expect(headerSource, isNot(contains('fontSize: 17')));
  });

  test('reader action row flexes so labels never overflow (BUG-028)', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    final String actionRowSource = _between(
      source,
      '  Widget _buildActionRow(BuildContext context)',
      '  Widget _actionBtn(',
    );

    // 根因：spaceAround 只分配正余白，子项固有宽度（标签+固定内边距）超出可用
    // 宽度时照样溢出。修复改为每个按钮 Expanded 均分槽位，且不再用 spaceAround。
    expect(actionRowSource, contains('Expanded('),
        reason: '动作按钮必须包进 Expanded 才能在任意标签宽度下均分、不溢出');
    expect(actionRowSource, isNot(contains('MainAxisAlignment.spaceAround')),
        reason: 'spaceAround 不缩子项，是 3.3px 右溢出的根因');

    // 标签在槽位内也要安全降级：短 CJK 标签可换成两行完整显示，
    // 极端长标签仍用 ellipsis 兜底，避免把 Column 无限撑高。
    final String lyricsActionSource = _between(
      source,
      'label: widget.lyricsMode ? t.book_mode : t.lyrics_mode',
      'label: t.action_bookmark',
    );
    expect(lyricsActionSource, contains('widget.onToggleLyricsMode!()'));

    final String actionBtnSource = _between(
      source,
      '  Widget _actionBtn(',
      'class _InBookTocRow',
    );
    expect(actionBtnSource, contains('overflow: TextOverflow.ellipsis'));
    expect(actionBtnSource, contains('maxLines: 2'));
  });

  test('reader page opens the reader quick settings sheet', () {
    final String readerSource =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();
    final String playBarSource =
        File('lib/src/media/audiobook/audiobook_play_bar.dart')
            .readAsStringSync();

    expect(readerSource, contains('ReaderQuickSettingsSheet'));
    expect(readerSource, isNot(contains('AudiobookSettingsSheet(')));
    expect(playBarSource, isNot(contains('class AudiobookSettingsSheet')));
  });

  test('reading progress section shows book title and current chapter name',
      () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    // sheet 暴露 chapterLabel 入参，承载阅读器页面反查出的当前章节名。
    expect(source, contains('final String? chapterLabel;'));

    final String progressSource = _between(
      source,
      '  Widget _buildProgressSection(ThemeData theme)',
      '  Widget _buildAudioProgressLine(',
    );
    // 阅读进度区块在数字进度行之上额外渲染书名（epubBook.title）与章节名。
    expect(progressSource, contains('widget.epubBook?.title'));
    expect(progressSource, contains('widget.chapterLabel'));
    // 书名/章节名为空时不渲染空行。
    expect(progressSource, contains('hasTitle'));
    expect(progressSource, contains('hasChapter'));

    // 阅读器页面把当前章节名喂给 sheet。
    final String readerSource =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();
    expect(readerSource, contains('chapterLabel: _currentChapterLabel()'));
  });

  test('reader page uses shared MD3 dialog frame for desktop quick settings',
      () {
    final String readerSource =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();

    final int desktopBranch = readerSource.indexOf('if (isDesktopPlatform)');
    final int mobileBranch =
        readerSource.indexOf('await adaptiveModalSheet<void>', desktopBranch);
    expect(desktopBranch, isNonNegative);
    expect(mobileBranch, greaterThan(desktopBranch));

    final String desktopSource =
        readerSource.substring(desktopBranch, mobileBranch);
    expect(desktopSource, contains('HibikiDialogFrame('));
    // master-detail 需要更宽画布（左父菜单 + 右详情）；520 太窄进不了分栏。
    expect(desktopSource, contains('maxWidth: 900'));
    expect(desktopSource, contains('maxHeightFactor: 0.80'));
    expect(desktopSource, isNot(contains('=> Dialog(')));
    expect(desktopSource, isNot(contains('ConstrainedBox(')));
  });

  test('reader quick settings widens into master-detail on wide windows', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    // 宽窗用主页同款 supporting-pane（左父菜单 + 右详情），阈值走共享常量。
    expect(source, contains('MaterialSupportingPaneLayout('));
    expect(source, contains('SupportingPaneSide.start'));
    expect(source, contains('minSplitWidth: kHibikiSettingsWideThreshold'));
    // 左父菜单收窄到共享常量（不再硬编码 248）。
    expect(source,
        contains('supportingWidth: kHibikiSettingsSupportingPaneWidth'));
    // 宽窗判定（constraints.maxWidth >= 阈值）已下沉到共享外壳；阅读器经
    // isWide / onWideChanged 与外壳交互（见 master_detail_settings_sheet_test）。
    expect(source, contains('isWide: _isWide'));
    expect(source, contains('onWideChanged:'));
    expect(source, contains('padding: wideSupportingPadding'));
    expect(source, contains('padding: widePrimaryPadding'));
    expect(source, contains('Widget _buildWidePane('));
    expect(source, contains('_wideCategories()'));

    // 左 pane 把外观纳入分类（默认选中），右 pane 复用同一份子页详情。
    expect(source, contains("id: 'appearance'"));
    expect(source, contains("_subPage ?? 'appearance'"));
    expect(source, contains('_subPageContent(selectedId)'));
    // 左 pane 分类用带选中态的 MD3 列表项（pill 高亮，无 chevron 误导 push）。
    expect(source, contains('HibikiListItemSelectedShape.pill'));
    // 右 pane 详情按选中 id KeyedSubtree，防 Element 复用副作用。
    expect(source, contains('KeyedSubtree('));
    expect(source, contains('ValueKey<String>(selectedId)'));

    // 窄窗（含手机 bottom sheet）保留原 push：< 640 仍走主页/子页。
    expect(source, contains('? _buildSubPage(context, theme)'));
    expect(source, contains(': _buildMainPage(context, theme)'));
    // 宽窗下返回键直接关弹窗，不卡在「返回上一级」：canPop 逻辑下沉到共享外壳，
    // 阅读器把 subPageActive / onPopToParent / isWide 喂给它。
    expect(source, contains('subPageActive: _subPage != null'));
    expect(source, contains('onPopToParent:'));
  });

  test('reader quick settings uses a deterministic width+height gate', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    // 左父菜单用更窄的固定宽度（共享常量），不再吃硬编码 248。
    expect(source,
        contains('supportingWidth: kHibikiSettingsSupportingPaneWidth'));

    // 确定性几何判据（宽且高都 >= 共享阈值）已下沉到共享外壳
    // HibikiMasterDetailSettingsSheet（master_detail_settings_sheet_test 守它）；阅读器
    // 经 isWide / onWideChanged 与外壳交互，本文件只锁阅读器仍用共享外壳 + 没退回
    // 旧的 post-frame 测内容溢出回退判据。
    expect(source, contains('HibikiMasterDetailSettingsSheet('));
    expect(source, contains('onWideChanged:'));

    // 旧的「post-frame 测左父菜单内容溢出回退」已移除（会随内容高度发散 → 同设备
    // 两种表现）。
    expect(source, isNot(contains('_supportingOverflowsWide')));
    expect(source, isNot(contains('_supportingScrollController')));
    expect(source, isNot(contains('_wideProbeHeight')));
  });

  test('reader wide pane drops progress; it moves into the appearance detail',
      () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    // 左父菜单做矮：阅读进度从左 pane 移到右侧外观详情顶部（_buildWidePrimary），
    // 左栏只留分类导航 + 动作，让更多窗口能进宽窗。
    expect(source, contains('Widget _buildWidePrimary('));
    expect(source, contains('_buildProgressSection(theme)'));
    // 右 pane 渲染走 _buildWidePrimary（默认外观顶部并入进度），不再直接铺
    // _subPageContent。
    expect(source, contains('_buildWidePrimary(context, theme, selectedId)'));
  });
}

String _withoutSharedIconButton(String source) {
  return source.replaceAll('HibikiIconButton(', 'HibikiSharedIconControl(');
}

String _between(String source, Object start, Object end) {
  final int startIndex = start is int ? start : source.indexOf(start as String);
  final int endIndex =
      end is int ? end : source.indexOf(end as String, startIndex);
  expect(startIndex, isNonNegative, reason: 'Missing source marker: $start');
  expect(endIndex, isNonNegative, reason: 'Missing source marker: $end');
  return source.substring(startIndex, endIndex);
}
