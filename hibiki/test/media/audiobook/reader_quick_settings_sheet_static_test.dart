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

    // 外观已平铺到主页，不再有独立的「外观」导航子页入口。
    expect(mainSource, contains('_buildAppearanceInline(theme)'));
    expect(source, isNot(contains("page: 'appearance'")));
    expect(source, isNot(contains('Widget _buildQuickControlsSection(')));

    // 平铺区把主题行 + appearance schema 裸行 + 编辑书籍CSS 合并成一张等宽卡
    // （单个 AdaptiveSettingsSection），编辑书籍CSS 是最后一行而非独立卡。
    final String inlineSource = _between(
      source,
      '  Widget _buildAppearanceInline(ThemeData theme)',
      '  Widget _buildLocationSection(ThemeData theme)',
    );
    expect(
        inlineSource, contains('buildThemeSelector(_themeSettingsContext())'));
    expect(inlineSource, contains('ReaderGroup.appearance'));
    // appearance schema 行用 buildSectionRows 取「裸行」（非 buildDetailContent
    // 的 ListView+整页内边距），才能与下方导航卡等宽。
    expect(inlineSource, contains('buildSectionRows('));
    expect(inlineSource, contains('book_css_editor_edit_css'));
    // 主题不再是独立卡：内联区不再用旧的 _buildThemeSelector() 包装方法。
    expect(source, isNot(contains('Widget _buildThemeSelector()')));
    // 单卡合并：内联区只一个 AdaptiveSettingsSection（编辑书籍CSS 并入其中，
    // 非独立卡）。
    expect('AdaptiveSettingsSection('.allMatches(inlineSource).length, 1);
  });

  test('reader quick settings sheet uses shared MD3 sheet chrome', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('maxHeightFactor: 0.80'));
    expect(source, isNot(contains('child: SafeArea(')));
    expect(source, isNot(contains('BorderRadius.circular(2)')));
  });

  test('reader quick settings action buttons use shared MD3 icon controls', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    final String headerSource = _between(
      source,
      'class _InBookSettingsHeader',
      'class _InBookTocRow',
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
      'class _InBookSettingsHeader',
    );
    expect(inBookSource, contains('HibikiIconButton('));
    expect(inBookSource, isNot(contains('FilledButton.tonal(')));
    expect(inBookSource, isNot(contains('VisualDensity.compact')));
  });

  test('audiobook play bar uses shared MD3 icon controls', () {
    final String source =
        File('lib/src/media/audiobook/audiobook_play_bar.dart')
            .readAsStringSync();

    expect(source, contains('HibikiIconButton('));
    final String normalized = _withoutSharedIconButton(source);
    expect(normalized, isNot(contains('return IconButton(')));
    expect(normalized, isNot(contains('child: IconButton(')));
    expect(source, isNot(contains('IconButton.filledTonal(')));
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
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    final String headerSource = source.substring(
      source.indexOf('class _InBookSettingsHeader'),
      source.indexOf('class _InBookTocRow'),
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

    // 标签在槽位内也要安全降级，避免极端长标签把 Column 撑高/裁切。
    final String actionBtnSource = _between(
      source,
      '  Widget _actionBtn(',
      'class _InBookSettingsHeader',
    );
    expect(actionBtnSource, contains('overflow: TextOverflow.ellipsis'));
    expect(actionBtnSource, contains('maxLines: 1'));
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
    expect(desktopSource, contains('maxWidth: 520'));
    expect(desktopSource, contains('maxHeightFactor: 0.80'));
    expect(desktopSource, isNot(contains('=> Dialog(')));
    expect(desktopSource, isNot(contains('ConstrainedBox(')));
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
