import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as auth;

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

  Future<auth.AuthClient> getAuthClient() async {
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) throw GoogleDriveAuthError('Not authenticated');
    return client;
  }

  Future<void> authenticate() async {
    final account = await _googleSignIn.signIn();
    if (account == null) {
      throw GoogleDriveAuthError('Sign-in cancelled');
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }
}
