import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';
import '../pages/video_hibiki_page_source_corpus.dart';

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
        // TODO-589 batch2 / TODO-590 batch14: reader 与 video 的制卡方法分别搬进
        // reader_hibiki/mining.part.dart 与 video_hibiki/lookup_mining.part.dart，
        // 读合并语料（主壳 + 全部 part）才能命中搬出去的 mineEntry / describeMineOutcome。
        final String src = path.endsWith('reader_hibiki_page.dart')
            ? readReaderPageSource()
            : path.endsWith('video_hibiki_page.dart')
                ? readVideoHibikiSource()
                : f.readAsStringSync();
        // Only inspect files that actually mine entries. TODO-1000：video 页把
        // repo.mineEntry 调用搬进 ImmersionMiningEngine（引擎内落卡 + 经
        // describeMineOutcome 路由错误），故委托引擎也算「本页会制卡」。
        expect(src.contains('mineEntry') || src.contains('ImmersionMiningEngine'),
            isTrue,
            reason: '$path no longer calls mineEntry nor delegates to '
                'ImmersionMiningEngine — update this guard');
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

  // TODO-752a: 制卡连接失败的乱码根因——后端把 socket/http 原文（含英文/latin1
  // 乱码）透传进 toast。修复后后端只回**稳定 errorCode**，logMineFailure 据码映射
  // 本地化 toast；errorDetail/error 仍写诊断日志，OS 原文绝不进 toast。
  group('logMineFailure localizes by errorCode (no raw OS text in toast)', () {
    setUp(() async {
      await ErrorLogService.instance.clear();
    });

    final Map<String, String> cases = <String, String>{
      AnkiErrorCode.connectionRefused: t.anki_error_connection_refused,
      AnkiErrorCode.connectionTimeout: t.anki_error_connection_timeout,
      AnkiErrorCode.httpError: t.anki_error_http,
      AnkiErrorCode.connectionUnknown: t.anki_error_connection_unknown,
    };
    cases.forEach((String code, String localized) {
      test('$code maps to its localized toast string', () {
        final MineOutcome outcome = MineOutcome.failure(
          'raw english fallback should be ignored',
          errorCode: code,
          error: SocketException('Connection refused',
              osError: const OSError('Connection refused', 111)),
        );
        final String msg = logMineFailure(outcome);
        // The localized message wins over the backend-provided errorDetail.
        expect(msg, localized);
        // The raw OS exception text is NOT in the toast (no garble vector).
        expect(msg, isNot(contains('OSError')));
        expect(msg, isNot(contains('raw english fallback')));
        // Full diagnostics still reach the error log.
        expect(ErrorLogService.instance.entries, hasLength(1));
      });
    });

    test('unknown/absent errorCode falls back to the detail toast', () {
      final MineOutcome outcome = MineOutcome.failure(
        'All fields are empty',
        errorCode: 'SOME_UNMAPPED_CODE',
      );
      final String msg = logMineFailure(outcome);
      // No mapping for this code -> old behavior (detail woven into toast).
      expect(msg, contains('All fields are empty'));
    });

    test('localizeAnkiMineError returns null for an unmapped code', () {
      expect(localizeAnkiMineError(null), isNull);
      expect(localizeAnkiMineError('SOME_UNMAPPED_CODE'), isNull);
      expect(localizeAnkiMineError(AnkiErrorCode.connectionRefused),
          t.anki_error_connection_refused);
    });
  });
}
