import 'package:flutter_test/flutter_test.dart';

import 'sync_settings_schema_source_corpus.dart';

/// TODO-045 (observability): a failed Google sign-in only showed a transient
/// snackbar — the real cause (invalid_client 401, redirect mismatch, a blocked
/// connection) vanished. The sign-in handler must persist the full diagnostic
/// to ErrorLogService so it survives on the error-log page. This source guard
/// fails if either catch arm of `_signIn` stops logging.
///
/// TODO-585: `_signIn` 现住在 sync_settings_schema/account.part.dart；读合并语料
/// 而不是单文件，搬到哪个 part 都扫得到。
void main() {
  test('_signIn logs both catch arms to ErrorLogService', () {
    final String body = readSyncSettingsSchemaSource();

    final int signInIdx = body.indexOf('Future<void> _signIn() async');
    expect(signInIdx, greaterThanOrEqualTo(0),
        reason: '_signIn was renamed/removed — update this guard');

    // Scope the search to the _signIn method body (up to the next method).
    final int signOutIdx = body.indexOf('Future<void> _signOut() async');
    final String signInBody = signOutIdx > signInIdx
        ? body.substring(signInIdx, signOutIdx)
        : body.substring(signInIdx);

    final int logCount = "ErrorLogService.instance.log('SyncSettings.signIn'"
        .allMatches(signInBody)
        .length;
    expect(logCount, greaterThanOrEqualTo(2),
        reason: 'both the SyncAuthError and the generic catch arms of _signIn '
            'must write the failure to ErrorLogService (TODO-045); found '
            '$logCount call(s)');
  });
}
