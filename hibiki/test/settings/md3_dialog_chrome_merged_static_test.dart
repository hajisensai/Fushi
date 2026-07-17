import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_history_source_corpus.dart';

/// 合并守卫：MD3 对话框壳（HibikiDialogFrame / HibikiModalSheetFrame / 设计令牌）
/// 一致性静态守卫。原来每个对话框各占一个 *_md3_static_test.dart 文件，断言同形但
/// 各自钉死本文件差异化的 inline-state spacing / insetPadding / EdgeInsets 切片标记，
/// 无法用共享断言列表替代。此文件把每个源文件的全部 test() 块**逐字**搬进来，用
/// group() 按源文件包裹以保失败隔离，断言与 reason 文案一律原样保留。
void main() {
  group('anki_handlebar_picker_dialog_md3_static', () {
    test('anki settings page uses MD3 spacing tokens for inline states', () {
      final String source = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      final String pageSource =
          source.substring(0, source.indexOf('Widget _buildFetchTile'));

      expect(pageSource, contains('HibikiDesignTokens.of(context)'));
      expect(
        pageSource,
        isNot(contains('padding: const EdgeInsets.fromLTRB(12, 0, 12, 12)')),
      );
      expect(
        pageSource,
        isNot(contains('padding: const EdgeInsets.fromLTRB(16, 8, 16, 20)')),
      );
    });

    test(
        'anki handlebar picker dialog uses shared MD3 dialog chrome and tokens',
        () {
      final String source = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      final String dialogSource =
          source.substring(source.indexOf('class AnkiHandlebarPickerDialog'));

      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, contains('HibikiDesignTokens.of(context)'));
      expect(dialogSource, contains('insetPadding: EdgeInsets.symmetric('));
      expect(dialogSource, contains('horizontal: tokens.spacing.card'));
      expect(dialogSource, contains('vertical: tokens.spacing.gap'));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
      expect(
        dialogSource,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 8)'),
        ),
      );
    });
  });

  group('audio_recorder_dialog_md3_static', () {
    test('audio recorder dialog uses shared MD3 dialog chrome and tokens', () {
      final String source = File(
        'lib/src/pages/implementations/audio_recorder_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, contains('insetPadding: EdgeInsets.symmetric('));
      expect(source, contains('horizontal: tokens.spacing.card'));
      expect(source, contains('vertical: tokens.spacing.card'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('Spacing.of(context)')));
      expect(
        source,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
        ),
      );
      expect(source, isNot(contains('const EdgeInsets.all(16)')));
    });

    test('audio recorder player controls use shared MD3 icon buttons', () {
      final String source = File(
        'lib/src/pages/implementations/audio_recorder_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiIconButton('));
      expect(source, isNot(contains('return IconButton(')));
      expect(source, isNot(contains('child: IconButton(')));
    });
  });

  group('blur_options_dialog_md3_static', () {
    test('blur options dialog uses shared MD3 dialog chrome and token spacing',
        () {
      final String source = File(
        'lib/src/pages/implementations/blur_options_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('Spacing.of(context)')));
    });
  });

  group('book_profile_dialog_md3_static', () {
    test('book profile dialog owns shared MD3 dialog and sheet chrome', () {
      final String source = readReaderHistorySource();
      final String dialogSource = _between(
        source,
        'class _BookProfileDialog extends StatefulWidget',
        'class BookProfileDialogContent extends StatelessWidget',
      );

      expect(dialogSource, contains('BookProfileDialogFrame('));
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    });
  });

  group('crop_image_dialog_md3_static', () {
    test('crop image dialog uses shared MD3 dialog chrome and token spacing',
        () {
      final String source = File(
        'lib/src/pages/implementations/crop_image_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('Spacing.of(context)')));
    });
  });

  group('dictionary_settings_dialog_md3_static', () {
    test('dictionary settings dialogs use shared MD3 dialog chrome and tokens',
        () {
      final String source = File(
        'lib/src/pages/implementations/dictionary_settings_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, contains('insetPadding: EdgeInsets.symmetric('));
      expect(source, contains('horizontal: tokens.spacing.card'));
      expect(source, contains('vertical: tokens.spacing.card'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(
        source,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
        ),
      );
    });

    test('audio source controls use shared MD3 icon buttons', () {
      final String source = File(
        'lib/src/pages/implementations/dictionary_settings_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiIconButton('));
      expect(source, isNot(contains('trailing: IconButton(')));
      expect(source, isNot(contains('suffixIcon: IconButton(')));
      expect(source, isNot(contains('visualDensity: VisualDensity.compact')));
    });
  });

  group('media_source_picker_dialog_md3_static', () {
    test('media source picker uses shared MD3 dialog shell', () {
      final String source = File(
        'lib/src/pages/implementations/media_source_picker_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiListItem('));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('Spacing.of(context)')));
    });
  });

  group('example_sentences_dialog_md3_static', () {
    test('example sentences dialog uses shared MD3 dialog and card chrome', () {
      final String source = File(
        'lib/src/pages/implementations/example_sentences_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiCard('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('Spacing.of(context)')));
      expect(source, isNot(contains('GestureDetector(')));
      expect(source, isNot(contains('Container(')));
    });
  });

  group('profile_management_dialog_md3_static', () {
    test('profile management dialogs use shared MD3 dialog chrome and tokens',
        () {
      final String source = File(
        'lib/src/pages/implementations/profile_management_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, contains('insetPadding: EdgeInsets.symmetric('));
      expect(source, contains('horizontal: tokens.spacing.card'));
      expect(source, contains('vertical: tokens.spacing.card'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(
        source,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
        ),
      );
    });

    test('profile action buttons use shared MD3 icon buttons', () {
      final String source = File(
        'lib/src/pages/implementations/profile_management_page.dart',
      ).readAsStringSync();

      final int actionStart = source.indexOf('class _ProfileActionButton');
      final int deleteStart = source.indexOf('@visibleForTesting', actionStart);
      final String actionSource = source.substring(actionStart, deleteStart);

      expect(actionSource, contains('HibikiIconButton('));
      expect(actionSource, isNot(contains('return IconButton(')));
      expect(actionSource, isNot(contains('VisualDensity.compact')));
    });
  });

  group('switch_settings_dialog_md3_static', () {
    test('switch settings dialog uses shared MD3 dialog chrome', () {
      final String source = File(
        'lib/src/pages/implementations/switch_settings_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('contentPadding: const EdgeInsets')));
    });
  });

  group('tag_management_dialog_md3_static', () {
    test('tag management dialogs use shared MD3 dialog chrome and tokens', () {
      final String source = File(
        'lib/src/pages/implementations/tag_management_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, contains('insetPadding: EdgeInsets.symmetric('));
      expect(source, contains('horizontal: tokens.spacing.card'));
      expect(source, contains('vertical: tokens.spacing.card'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(
        source,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
        ),
      );
      expect(
        source,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 8)'),
        ),
      );
    });
  });

  group('text_segmentation_dialog_md3_static', () {
    test('text segmentation dialog uses shared MD3 dialog and chip chrome', () {
      final String source = File(
        'lib/src/pages/implementations/text_segmentation_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiSelectableChip('));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('Spacing.of(context)')));
      expect(source, isNot(contains('Container(')));
    });
  });

  group('websocket_dialog_md3_static', () {
    test('websocket dialog uses shared MD3 dialog chrome', () {
      final String source = File(
        'lib/src/pages/implementations/websocket_dialog_page.dart',
      ).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('));
      expect(source, contains('HibikiModalSheetFrame('));
      expect(source, contains('HibikiDesignTokens.of(context)'));
      expect(source, isNot(contains('adaptiveAlertDialog(')));
      expect(source, isNot(contains('Spacing.of(context)')));
    });
  });
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  final int endIndex = source.indexOf(end, startIndex);
  expect(startIndex, isNonNegative, reason: 'Missing source marker: $start');
  expect(endIndex, isNonNegative, reason: 'Missing source marker: $end');
  return source.substring(startIndex, endIndex);
}
