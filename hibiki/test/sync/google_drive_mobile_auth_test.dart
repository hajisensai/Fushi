import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/google_drive_auth.dart';

/// Guards the mobile Google Drive auth fix (BUG-047): on Android/iOS the backend
/// `restoreAuth` used to be a no-op (`return false`) and `GoogleDriveAuth` never
/// called `signInSilently()`, so after a cold app start the account row showed
/// "未登录" (or "已登录" with no email) and auto-sync never passed its
/// isAuthenticated gate. The mobile session must now be rehydrated explicitly.
///
/// The real mobile branch can't run here (host tests have `Platform.isAndroid`
/// == false and the google_sign_in plugin isn't injectable), so behaviour is
/// pinned with a source-scan guard plus a platform-gate runtime check — the same
/// pattern used for the desktop fix in google_drive_desktop_auth_test.dart.
void main() {
  test('restoreMobileAuth is a no-op off mobile (platform gate)', () async {
    // Host runs are non-mobile, so the gate returns false without touching the
    // plugin or any desktop state.
    expect(GoogleDriveAuth.useMobileAuth, isFalse);
    expect(await GoogleDriveAuth.instance.restoreMobileAuth(), isFalse);
  });

  test(
      'source guard: mobile session is rehydrated via signInSilently '
      '(BUG-047)', () {
    final auth = File('lib/src/sync/google_drive_auth.dart').readAsStringSync();

    // The explicit rehydration entry point must exist and use signInSilently().
    expect(auth.contains('Future<bool> restoreMobileAuth()'), isTrue,
        reason: 'mobile restore must rehydrate the saved google_sign_in '
            'session, not return false (BUG-047).');
    expect(auth.contains('signInSilently()'), isTrue);

    // Auth state + email must be driven off the rehydrated account, not the
    // unreliable isSignedIn()/lazy lookup that left "已登录" with no name.
    expect(auth.contains('GoogleSignInAccount? _mobileUser'), isTrue);
    expect(auth.contains('_mobileUser?.email'), isTrue);
    expect(auth.contains('_signIn.isSignedIn()'), isFalse,
        reason: 'isAuthenticated must not gate on the unreliable isSignedIn() '
            '(BUG-047).');
  });

  test(
      'source guard: backend restoreAuth rehydrates on mobile, not no-op '
      '(BUG-047)', () {
    final backend =
        File('lib/src/sync/google_drive_sync_backend.dart').readAsStringSync();

    expect(backend.contains('return _auth.restoreMobileAuth();'), isTrue,
        reason: 'mobile restoreAuth must rehydrate the session (BUG-047).');
    expect(backend.contains('if (GoogleDriveAuth.useMobileAuth) return false;'),
        isFalse,
        reason: 'the old no-op mobile restore must stay gone (BUG-047).');
  });

  test('source guard: compare dialog restores auth before gating (BUG-047)',
      () {
    final dialog =
        File('lib/src/sync/sync_compare_dialog.dart').readAsStringSync();
    // The auth-state read must be preceded by a restore so a cold-start open
    // doesn't wrongly report "set up sync first".
    final restoreAt = dialog.indexOf('await backend.restoreAuth(repo);');
    final gateAt = dialog.indexOf('if (!await backend.isAuthenticated)');
    expect(restoreAt, greaterThanOrEqualTo(0),
        reason: 'showSyncCompareDialog must restoreAuth first (BUG-047).');
    expect(gateAt, greaterThan(restoreAt),
        reason: 'restoreAuth must run before the isAuthenticated gate '
            '(BUG-047).');
  });
}
