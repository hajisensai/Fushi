import 'package:dio/dio.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:hibiki/src/sync/token_storage.dart';

class GoogleDriveAuthError implements Exception {
  GoogleDriveAuthError(this.message);
  final String message;

  @override
  String toString() => 'GoogleDriveAuthError: $message';
}

class GoogleDriveAuth {
  GoogleDriveAuth._();
  static final GoogleDriveAuth instance = GoogleDriveAuth._();

  static final _clientIdPattern =
      RegExp(r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$');

  Future<bool> get isAuthenticated => SyncTokenStorage.isAuthenticated;

  Future<String> getAccessToken() async {
    final token = await SyncTokenStorage.getAccessToken();
    if (token == null) throw GoogleDriveAuthError('Not authenticated');
    return token;
  }

  Future<void> authenticate(String clientId) async {
    final trimmed = clientId.trim();
    if (!_clientIdPattern.hasMatch(trimmed)) {
      throw GoogleDriveAuthError('Invalid Client ID format');
    }

    final scheme = trimmed.split('.').reversed.join('.');
    final redirectUri = '$scheme:/oauth2callback';

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': trimmed,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': 'https://www.googleapis.com/auth/drive.file',
    });

    final callbackUrl = await FlutterWebAuth2.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: scheme,
    );

    final code = Uri.parse(callbackUrl).queryParameters['code'];
    if (code == null) {
      throw GoogleDriveAuthError('No authorization code in callback');
    }

    await _exchangeCode(
        code: code, clientId: trimmed, redirectUri: redirectUri);
    await SyncTokenStorage.saveClientId(trimmed);
  }

  Future<String> refreshAccessToken() async {
    final refreshToken = await SyncTokenStorage.getRefreshToken();
    final clientId = await SyncTokenStorage.getClientId();
    if (refreshToken == null || clientId == null) {
      throw GoogleDriveAuthError('Not authenticated');
    }

    final dio = Dio();
    try {
      final response = await dio.post(
        'https://oauth2.googleapis.com/token',
        options: Options(contentType: Headers.formUrlEncodedContentType),
        data: {
          'client_id': clientId,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        },
      );

      if (response.statusCode != 200) {
        await signOut();
        throw GoogleDriveAuthError('Token refresh failed');
      }

      final accessToken = response.data['access_token'] as String;
      await SyncTokenStorage.saveAccessToken(accessToken);
      return accessToken;
    } on DioError catch (e) {
      final status = e.response?.statusCode;
      if (status != null && (status == 400 || status == 401)) {
        await signOut();
        throw GoogleDriveAuthError('Token refresh failed: invalid grant');
      }
      throw GoogleDriveAuthError('Token refresh failed: network error');
    } finally {
      dio.close();
    }
  }

  Future<void> signOut() async {
    await SyncTokenStorage.clear();
  }

  Future<void> _exchangeCode({
    required String code,
    required String clientId,
    required String redirectUri,
  }) async {
    final dio = Dio();
    try {
      final response = await dio.post(
        'https://oauth2.googleapis.com/token',
        options: Options(contentType: Headers.formUrlEncodedContentType),
        data: {
          'code': code,
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'grant_type': 'authorization_code',
        },
      );

      final statusCode = response.statusCode ?? -1;
      if (statusCode < 200 || statusCode >= 300) {
        throw GoogleDriveAuthError('Token exchange failed: $statusCode');
      }

      final data = response.data as Map<String, dynamic>;
      await SyncTokenStorage.saveAccessToken(data['access_token'] as String);
      final refresh = data['refresh_token'] as String?;
      if (refresh != null) {
        await SyncTokenStorage.saveRefreshToken(refresh);
      }
    } finally {
      dio.close();
    }
  }
}
