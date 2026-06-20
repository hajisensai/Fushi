import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

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

  group(
      'every mine error branch routes through describeMineOutcome → logMineFailure',
      () {
    // Source-scan guard (BUG-089): the cause must still surface via
    // logMineFailure — now consolidated inside the single describeMineOutcome
    // helper, which all 5 call sites route through (no bare
    // `t.card_export_failed` toast). These pages embed real WebViews / platform
    // channels and cannot be widget-tested directly, so we guard at the source.
    final List<String> callSites = <String>[
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
      'lib/src/pages/implementations/reader_hibiki_page.dart',
      'lib/src/pages/implementations/floating_dict_page.dart',
      'lib/src/pages/implementations/video_hibiki_page.dart',
      'lib/src/models/app_model.dart',
    ];

    test('describeMineOutcome 的 error 分支仍经 logMineFailure 浮现原因', () {
      final String src = File(
        'lib/src/utils/misc/error_log_service.dart',
      ).readAsStringSync();
      expect(src.contains('describeMineOutcome('), isTrue);
      expect(
        src.contains('logMineFailure(outcome)'),
        isTrue,
        reason: 'describeMineOutcome 的 MineResult.error 分支必须经 logMineFailure '
            '记录完整诊断并回简短原因 (BUG-089)',
      );
    });

    for (final String path in callSites) {
      test('$path routes mine outcome through describeMineOutcome', () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: 'missing call site: $path');
        // TODO-589 batch2: reader 制卡方法已搬进 reader_hibiki/mining.part.dart，
        // 读合并语料（主壳 + 全部 part）才能命中搬出去的 mineEntry / describeMineOutcome。
        final String src = path.endsWith('reader_hibiki_page.dart')
            ? readReaderPageSource()
            : f.readAsStringSync();
        // Only inspect files that actually mine entries.
        expect(src.contains('mineEntry'), isTrue,
            reason: '$path no longer calls mineEntry — update this guard');
        expect(
          src.contains('describeMineOutcome('),
          isTrue,
          reason:
              '$path must route MineResult through describeMineOutcome, whose '
              'error branch surfaces the cause via logMineFailure (BUG-089)',
        );
      });
    }
  });
}
