import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// BUG-089: a card-mining failure used to vanish — backends returned a bare
// `MineResult.error` and only `debugPrint`-ed the cause (which goes nowhere
// unless the user manually enables the debug log), and every UI call site
// mapped it to a generic `t.card_export_failed` toast. The user could neither
// read the reason in the toast nor find it in the error-log page.
//
// The fix carries the cause back in `MineOutcome` and routes every error
// branch through the single `logMineFailure` helper: full diagnostics →
// ErrorLogService (error-log page), concise reason → toast.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocaleRaw('en');

  group('logMineFailure surfaces the cause', () {
    setUp(() async {
      await ErrorLogService.instance.clear();
    });

    test('writes full diagnostics (error + stack) to the error log', () {
      final StackTrace stack = StackTrace.current;
      final MineOutcome outcome = MineOutcome.failure(
        'AnkiConnect: cannot create note because it is a duplicate',
        error: StateError('boom'),
        stackTrace: stack,
      );

      logMineFailure(outcome);

      expect(ErrorLogService.instance.entries, hasLength(1));
      final ErrorLogEntry entry = ErrorLogService.instance.entries.single;
      expect(entry.source, 'Anki.mineEntry');
      // The raw error object (not just the concise detail) reaches the log.
      expect(entry.error, contains('boom'));
      expect(entry.stackTrace, isNotNull);
    });

    test('returns the concise reason for the toast when detail is present', () {
      final String msg = logMineFailure(
        MineOutcome.failure('All fields are empty'),
      );

      // The concise reason is woven into the localized toast string.
      expect(msg, contains('All fields are empty'));
      expect(msg, isNot(equals(t.card_export_failed)));
    });

    test('falls back to the generic message when no detail is carried', () {
      // A defensive case: an error outcome built without a detail string.
      const MineOutcome outcome = MineOutcome(MineResult.error);

      final String msg = logMineFailure(outcome);

      expect(msg, t.card_export_failed);
      // Still logs something so the failure is not silently dropped.
      expect(ErrorLogService.instance.entries, hasLength(1));
    });
  });

  group('every mine error branch routes through logMineFailure', () {
    // Source-scan guard: the 5 call sites must surface the cause via
    // logMineFailure(outcome), not a bare `t.card_export_failed` toast.
    // (These pages embed real WebViews / platform channels and cannot be
    // widget-tested directly, so we guard the contract at the source.)
    final List<String> callSites = <String>[
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
      'lib/src/pages/implementations/reader_hibiki_page.dart',
      'lib/src/pages/implementations/floating_dict_page.dart',
      'lib/src/pages/implementations/video_hibiki_page.dart',
      'lib/src/models/app_model.dart',
    ];

    for (final String path in callSites) {
      test('$path uses logMineFailure(outcome) in its error branch', () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: 'missing call site: $path');
        final String src = f.readAsStringSync();
        // Only inspect files that actually mine entries.
        expect(src.contains('mineEntry'), isTrue,
            reason: '$path no longer calls mineEntry — update this guard');
        expect(
          src.contains('logMineFailure(outcome)'),
          isTrue,
          reason: '$path must route MineResult.error through logMineFailure to '
              'log the cause and show the concise reason (BUG-089)',
        );
      });
    }
  });
}
