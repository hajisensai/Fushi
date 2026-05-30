import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reader quick settings owns the in-book settings hierarchy', () {
    final String source =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('class ReaderQuickSettingsSheet'));
    expect(source, contains("page: 'appearance'"));
    expect(source, contains("page: 'layout'"));
    expect(source, contains("page: 'behavior'"));
    expect(source, contains("page: 'location'"));
    expect(source, contains("page: 'audiobook'"));
    expect(source, isNot(contains('class AudiobookSettingsSheet')));
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
