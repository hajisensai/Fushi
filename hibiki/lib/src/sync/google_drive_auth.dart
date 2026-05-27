import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/auth_io.dart' as auth_io;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/src/sync/sync_repository.dart';

class GoogleDriveAuthError implements Exception {
  GoogleDriveAuthError(this.message);
  final String message;

  @override
  String toString() => 'GoogleDriveAuthError: $message';
}

class GoogleDriveAuth {
  GoogleDriveAuth._();
  static final GoogleDriveAuth instance = GoogleDriveAuth._();

  static bool get useMobileAuth => Platform.isAndroid || Platform.isIOS;

  static const _driveFileScope = 'https://www.googleapis.com/auth/drive.file';
  static const _emailScope = 'https://www.googleapis.com/auth/userinfo.email';

  static const _oauthClientId =
      String.fromEnvironment('GOOGLE_OAUTH_CLIENT_ID');
  static const _oauthClientSecret =
      String.fromEnvironment('GOOGLE_OAUTH_CLIENT_SECRET');

  static final _desktopClientId = auth.ClientId(
    _oauthClientId,
    _oauthClientSecret,
  );

  // ── Mobile (google_sign_in) ──────────────────────────────────────

  GoogleSignIn? _googleSignIn;
  GoogleSignIn get _signIn => _googleSignIn ??= GoogleSignIn(
        scopes: [_driveFileScope],
      );

  // ── Desktop (googleapis_auth) ────────────────────────────────────

  auth.AuthClient? _desktopClient;
  auth.AccessCredentials? _desktopCredentials;
  SyncRepository? _cachedRepo;
  String? _desktopEmail;

  // ── Public API ───────────────────────────────────────────────────

  Future<bool> get isAuthenticated {
    if (useMobileAuth) return _signIn.isSignedIn();
    return Future.value(_desktopClient != null);
  }

  Future<String?> get currentEmail async {
    if (useMobileAuth) {
      return _signIn.currentUser?.email ??
          (await _signIn.signInSilently())?.email;
    }
    return _desktopEmail;
  }

  Future<auth.AuthClient> getAuthClient() async {
    if (useMobileAuth) {
      final client = await _signIn.authenticatedClient();
      if (client == null) throw GoogleDriveAuthError('Not authenticated');
      return client;
    }
    final client = _desktopClient;
    if (client == null) throw GoogleDriveAuthError('Not authenticated');
    return client;
  }

  Future<void> authenticate({SyncRepository? repo}) async {
    if (useMobileAuth) {
      final account = await _signIn.signIn();
      if (account == null) {
        throw GoogleDriveAuthError('Sign-in cancelled');
      }
      return;
    }
    final client = await auth_io.clientViaUserConsent(
      _desktopClientId,
      [_driveFileScope, _emailScope],
      (String url) => launchUrl(Uri.parse(url)),
    );

    _desktopClient?.close();
    _desktopCredentials = client.credentials;
    _desktopClient = client;
    _cachedRepo = repo;
    await _fetchDesktopEmail(client);

    if (repo != null) await _persistDesktopCredentials(repo);
  }

  Future<bool> restoreDesktopAuth(SyncRepository repo) async {
    if (useMobileAuth) return false;

    final saved = await repo.getDesktopCredentials();
    if (saved == null) return false;

    final http.Client baseClient = http.Client();
    try {
      final credentials = _deserializeCredentials(saved);
      if (credentials.refreshToken == null) {
        baseClient.close();
        return false;
      }

      final refreshed = await auth_io.refreshCredentials(
        _desktopClientId,
        credentials,
        baseClient,
      );

      _desktopClient?.close();
      _desktopCredentials = refreshed;
      final authClient = auth.authenticatedClient(baseClient, refreshed);
      _desktopClient = authClient;
      _cachedRepo = repo;
      await _fetchDesktopEmail(authClient);
      await _persistDesktopCredentials(repo);
      return true;
    } catch (e, st) {
      baseClient.close();
      developer.log(
        'Failed to restore desktop auth',
        error: e,
        stackTrace: st,
        name: 'GoogleDriveAuth',
      );
      await repo.clearDesktopSession();
      return false;
    }
  }

  Future<void> refreshAuth() async {
    if (useMobileAuth) {
      await _signIn.signInSilently(reAuthenticate: true);
      return;
    }

    final creds = _desktopCredentials;
    if (creds == null || creds.refreshToken == null) {
      developer.log(
        'Cannot refresh: no credentials cached',
        name: 'GoogleDriveAuth',
      );
      return;
    }

    final baseClient = http.Client();
    try {
      final refreshed = await auth_io.refreshCredentials(
        _desktopClientId,
        creds,
        baseClient,
      );
      _desktopCredentials = refreshed;
      _desktopClient?.close();
      _desktopClient = auth.authenticatedClient(baseClient, refreshed);
      final repo = _cachedRepo;
      if (repo != null) await _persistDesktopCredentials(repo);
    } catch (e) {
      baseClient.close();
      developer.log(
        'Desktop token refresh failed',
        error: e,
        name: 'GoogleDriveAuth',
      );
    }
  }

  Future<void> signOut({SyncRepository? repo}) async {
    if (useMobileAuth) {
      await _signIn.signOut();
      return;
    }
    _desktopClient?.close();
    _desktopClient = null;
    _desktopCredentials = null;
    _desktopEmail = null;
    _cachedRepo = null;
    if (repo != null) await repo.clearDesktopSession();
  }

  // ── Desktop user info ─────────────────────────────────────────────

  static const _userinfoUrl = 'https://www.googleapis.com/oauth2/v2/userinfo';

  Future<void> _fetchDesktopEmail(http.Client client) async {
    try {
      final response = await client.get(Uri.parse(_userinfoUrl));
      if (response.statusCode == 200) {
        final info = jsonDecode(response.body) as Map<String, dynamic>;
        _desktopEmail = info['email'] as String?;
      }
    } catch (e) {
      developer.log(
        'Failed to fetch user email',
        error: e,
        name: 'GoogleDriveAuth',
      );
    }
  }

  // ── Credential serialization ─────────────────────────────────────

  Future<void> _persistDesktopCredentials(SyncRepository repo) async {
    final creds = _desktopCredentials;
    if (creds == null) return;
    await repo.setDesktopCredentials(_serializeCredentials(creds));
  }

  static String _serializeCredentials(auth.AccessCredentials creds) {
    return jsonEncode({
      'type': creds.accessToken.type,
      'data': creds.accessToken.data,
      'expiry': creds.accessToken.expiry.toIso8601String(),
      'refreshToken': creds.refreshToken,
      'scopes': creds.scopes.toList(),
    });
  }

  static auth.AccessCredentials _deserializeCredentials(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return auth.AccessCredentials(
      auth.AccessToken(
        map['type'] as String,
        map['data'] as String,
        DateTime.parse(map['expiry'] as String),
      ),
      map['refreshToken'] as String?,
      (map['scopes'] as List?)?.cast<String>() ?? [_driveFileScope],
    );
  }
}
