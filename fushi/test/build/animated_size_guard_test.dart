import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

const String _wrapper = 'lib/src/utils/components/fushi_animated_size.dart';

/// Exact owner + duration expression + occurrence budget. Existing consumers
/// are recorded, not declared safe: some already have a zero-duration branch,
/// others await migration. New uses must use FushiAnimatedSize. Removing an old
/// call must reduce its budget, never transfer it to another duration or file.
void main() {
  test('scanner ignores comments, strings and prefixed component names', () {
    expect(
      _durations('''
// AnimatedSize(duration: Duration.zero, child: x)
final hint = 'AnimatedSize(duration: Duration.zero)';
FushiAnimatedSize(duration: Duration.zero, child: x);
AnimatedSize(key: key, duration: safe(context, Duration.zero), child: x);
AnimatedSize(duration: motion.duration, child: x);
'''),
      <String>['safe(context,Duration.zero)', 'motion.duration'],
    );
  });

  test('new raw calls cannot reuse another owner or duration budget', () {
    final Map<String, int> budget = <String, int>{
      'old.dart|motion.duration': 1,
    };
    expect(
      _excess(<String, int>{'old.dart|motion.duration': 1}, budget),
      isEmpty,
    );
    expect(
      _excess(<String, int>{'old.dart|motion.duration': 2}, budget),
      hasLength(1),
    );
    expect(
      _excess(<String, int>{'new.dart|motion.duration': 1}, budget),
      hasLength(1),
    );
    expect(
      _excess(<String, int>{'old.dart|Duration.zero': 1}, budget),
      hasLength(1),
    );
  });

  test('raw AnimatedSize calls do not grow beyond exact existing sites', () {
    final Map<String, int> actual = <String, int>{};
    int scanned = 0;
    for (final FileSystemEntity entry in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entry is! File) continue;
      final String path = entry.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      scanned++;
      if (path == _wrapper) continue;
      for (final String duration in _durations(entry.readAsStringSync())) {
        final String site = '$path|$duration';
        actual[site] = (actual[site] ?? 0) + 1;
      }
    }
    expectScanScale(
      scanned,
      what: 'AnimatedSize lib sources',
      atLeast: 1200,
      measured: 1547,
    );
    expect(
      _excess(actual, _legacy),
      isEmpty,
      reason: 'Use FushiAnimatedSize for new or migrated calls.',
    );
  });

  test(
    'shared wrapper has exactly one SDK call behind the zero-duration return',
    () {
      final String source = maskCommentsAndStrings(
        File(_wrapper).readAsStringSync(),
      );
      expect(_durations(source), <String>['widget.duration']);
      expect(
        source,
        matches(
          RegExp(
            r'if\s*\(widget\.duration\s*==\s*Duration\.zero\)\s*\{\s*return Align\([\s\S]*?\);\s*\}\s*return AnimatedSize\(',
          ),
        ),
      );
    },
  );
}

List<String> _excess(Map<String, int> actual, Map<String, int> budget) =>
    <String>[
      for (final MapEntry<String, int> entry in actual.entries)
        if (entry.value > (budget[entry.key] ?? 0))
          '${entry.key}: ${entry.value} > ${budget[entry.key] ?? 0}',
    ];

List<String> _durations(String source) {
  final String code = maskCommentsAndStrings(source);
  final List<String> result = <String>[];
  for (final RegExpMatch call in RegExp(
    r'\bAnimatedSize\s*\(',
  ).allMatches(code)) {
    int depth = 0;
    int start = call.end;
    String? duration;
    for (int i = start; i < code.length; i++) {
      final String character = code[i];
      if (depth == 0 && (character == ',' || character == ')')) {
        final String argument = code.substring(start, i).trim();
        final RegExpMatch? name = RegExp(r'^duration\s*:').firstMatch(argument);
        if (name != null) {
          duration = argument
              .substring(name.end)
              .replaceAll(RegExp(r'\s+'), '');
        }
        start = i + 1;
        if (character == ')') break;
      } else if ('([{'.contains(character)) {
        depth++;
      } else if (')]}'.contains(character)) {
        depth--;
      }
    }
    result.add(duration ?? '<missing-duration>');
  }
  return result;
}

// Baseline a9576e38506, after the five shared consumers were migrated.
const Map<String, int> _legacy = <String, int>{
  'lib/src/anki/lapis_style_editor_page.dart|spring.duration': 1,
  'lib/src/controls/control_layout_editor.dart|style.duration(220)': 1,
  'lib/src/media/audiobook/asr_local_model_dialog.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/audiobook/asr_transcribe_sheet.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/audiobook/book_import_dialog.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/audiobook/reader_quick_settings_sheet.dart|fushiMotionDuration(context,FushiMotion.medium)':
      2,
  'lib/src/media/detail/media_detail_kit.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/downloads/download_task_card.dart|expandDuration': 1,
  'lib/src/media/favorites/favorite_batch_mining.dart|context.fushiMotion.spatialDefault.duration':
      1,
  'lib/src/media/import/quick_import_section.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/manga/manga_ocr_settings_section.dart|duration': 1,
  'lib/src/media/manga/mihon/mihon_extensions_page.dart|spring.duration': 1,
  'lib/src/media/manga/mihon/mihon_extensions_page.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/manga/reader/manga_reader_settings_sheet.dart|duration': 1,
  'lib/src/media/metadata/scrape_failure_view.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/novel/online/lnreader_extensions_section.dart|spring.duration':
      1,
  'lib/src/media/online/installed_online_source_row.dart|motion.spatialFast.duration':
      1,
  'lib/src/media/online/installed_online_source_row.dart|motion.spatialDefault.duration':
      1,
  'lib/src/media/tags/tag_picker_sheet.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/media/video/video_import_dialog.dart|context.fushiMotion.spatialDefault.duration':
      1,
  'lib/src/media/video/video_subtitle_jump_panel.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/ocr/system_ocr_setup_dialog.dart|motion.spatialDefault.duration': 1,
  'lib/src/onboarding/recommended_pack_download_mini_bar.dart|spring.duration':
      1,
  'lib/src/pages/implementations/browser_extension_page.dart|d': 2,
  'lib/src/pages/implementations/browser_extension_page.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/pages/implementations/custom_theme_page.dart|motion.spatialDefault.duration':
      5,
  'lib/src/pages/implementations/dictionary_manager_panels.dart|fushiMotionDuration(context,FushiMotion.short)':
      1,
  'lib/src/pages/implementations/dictionary_settings_dialog_page.dart|context.fushiMotion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/font_preview/font_library_widgets.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/pages/implementations/galgame_detail_page.dart|motion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/game_stream_library_page.dart|motion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/home_dictionary_page.dart|fushiMotionDuration(context,FushiMotion.short)':
      1,
  'lib/src/pages/implementations/home_dictionary_page.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/pages/implementations/home_game_page.dart|motion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/manual_download_task_dialog.dart|motion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/media_collection_grid_detail_page.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/pages/implementations/media_sources_view.dart|motion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/onboarding_wizard_page.dart|spring.duration':
      1,
  'lib/src/pages/implementations/sentence_context_dialog.dart|context.fushiMotion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart|motion':
      1,
  'lib/src/pages/implementations/shortcut_settings/shortcut_browser.part.dart|fushiMotionDuration(context,FushiMotion.short)':
      1,
  'lib/src/pages/implementations/stat_shared.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/pages/implementations/updates_dashboard_banner.dart|einkSafeDuration(context,constDuration(milliseconds:220))':
      1,
  'lib/src/pages/implementations/video_download_subscriptions_panel.dart|motion.spatialDefault.duration':
      1,
  'lib/src/pages/implementations/video_fushi/subtitle.part.dart|einkSafeDuration(context,constDuration(milliseconds:200))':
      1,
  'lib/src/reader/reader_control_layout_editor.dart|fushiMotionDuration(context,FushiMotion.short)':
      1,
  'lib/src/reader/reader_control_layout_editor.dart|fushiMotionDuration(context,FushiMotion.medium)':
      1,
  'lib/src/settings/master_detail_settings_sheet.dart|constDuration(milliseconds:200)':
      1,
  'lib/src/sync/jellyfin_settings_widget.dart|motion.spatialDefault.duration':
      1,
  'lib/src/sync/sync_compare_dialog.dart|motion.spatialDefault.duration': 1,
  'lib/src/sync/sync_progress_banner.dart|motion.spatialDefault.duration': 1,
  'lib/src/sync/sync_settings_schema/actions.part.dart|motion.spatialDefault.duration':
      1,
};
