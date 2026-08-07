import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_http.dart';

/// Access + refresh token pair returned by an OAuth 2.0 token endpoint.
class PkceTokens {
  const PkceTokens({required this.accessToken, this.refreshToken});

  final String accessToken;
  final String? refreshToken;
}

/// Shared OAuth 2.0 PKCE token exchange for the Dropbox / OneDrive sync
/// backends. The code-verifier/challenge generation and the authorization-code
/// / refresh-token exchanges are byte-identical between those two providers;
/// the only per-provider differences are the client id, token endpoint, and
/// (OneDrive only) an extra `scope` param on refresh. This helper owns those
/// exchanges; each backend keeps its own token persistence, user-info fetch,
/// authorize-URL construction, and desktop-vs-mobile flow.
class PkceOAuthFlow {
  const PkceOAuthFlow({
    required this.clientId,
    required this.tokenEndpoint,
    this.extraRefreshBody = const <String, String>{},
  });

  final String clientId;
  final String tokenEndpoint;

  /// Token-endpoint body params added to the refresh request beyond the shared
  /// defaults (OneDrive appends `scope`; Dropbox adds nothing).
  final Map<String, String> extraRefreshBody;

  /// RFC 7636 code verifier: 32 random bytes, base64url without padding.
  static String generateCodeVerifier() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// RFC 7636 S256 code challenge for [verifier].
  static String codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// Exchange an authorization [code] for tokens. [redirectUri] must match the
  /// value sent in the authorization request (custom scheme on mobile, the
  /// loopback URL on desktop).
  Future<PkceTokens> exchangeCode({
    required String code,
    required String redirectUri,
    required String verifier,
  }) async {
    final response = await (await obtainSyncHttpClient()).post(
      Uri.parse(tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': clientId,
        'code': code,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      },
    );

    if (response.statusCode != 200) {
      throw SyncAuthError(
          'Token exchange failed: ${response.statusCode} ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return PkceTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
    );
  }

  /// Exchange a [refreshToken] for a fresh access token. The provider may or may
  /// not return a new refresh token; [PkceTokens.refreshToken] is null when the
  /// response omits it (callers keep their existing one in that case).
  Future<PkceTokens> refreshTokens({required String refreshToken}) async {
    final response = await (await obtainSyncHttpClient()).post(
      Uri.parse(tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        ...extraRefreshBody,
      },
    );

    if (response.statusCode != 200) {
      throw SyncAuthError('Token refresh failed: ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return PkceTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json.containsKey('refresh_token')
          ? json['refresh_token'] as String
          : null,
    );
  }
}
