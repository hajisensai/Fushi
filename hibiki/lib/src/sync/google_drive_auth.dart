import 'package:google_sign_in/google_sign_in.dart';

class GoogleDriveAuthError implements Exception {
  GoogleDriveAuthError(this.message);
  final String message;

  @override
  String toString() => 'GoogleDriveAuthError: $message';
}

class GoogleDriveAuth {
  GoogleDriveAuth._();
  static final GoogleDriveAuth instance = GoogleDriveAuth._();

  final _googleSignIn = GoogleSignIn(
    scopes: ['https://www.googleapis.com/auth/drive.file'],
  );

  Future<bool> get isAuthenticated => _googleSignIn.isSignedIn();

  Future<String?> get currentEmail async =>
      _googleSignIn.currentUser?.email ??
      (await _googleSignIn.signInSilently())?.email;

  Future<String> getAccessToken() async {
    final account =
        _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
    if (account == null) throw GoogleDriveAuthError('Not authenticated');
    final auth = await account.authentication;
    if (auth.accessToken == null) {
      throw GoogleDriveAuthError('No access token');
    }
    return auth.accessToken!;
  }

  Future<void> authenticate() async {
    final account = await _googleSignIn.signIn();
    if (account == null) {
      throw GoogleDriveAuthError('Sign-in cancelled');
    }
  }

  Future<String> refreshAccessToken() async {
    final account = _googleSignIn.currentUser;
    if (account == null) throw GoogleDriveAuthError('Not authenticated');
    await account.clearAuthCache();
    final auth = await account.authentication;
    if (auth.accessToken == null) {
      await signOut();
      throw GoogleDriveAuthError('Token refresh failed');
    }
    return auth.accessToken!;
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }
}
