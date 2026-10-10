import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/pkce_oauth_backend_mixin.dart';
import 'package:xml/xml.dart';

const String _androidNamespace = 'http://schemas.android.com/apk/res/android';

String? _androidAttribute(XmlElement element, String name) =>
    element.getAttribute(name, namespace: _androidNamespace);

void main() {
  final Map<String, dynamic> contract =
      jsonDecode(File('../docs/agent/oauth-redirects.json').readAsStringSync())
          as Map<String, dynamic>;
  final XmlDocument manifest = XmlDocument.parse(
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
  );
  final XmlDocument plist = XmlDocument.parse(
    File('ios/Runner/Info.plist').readAsStringSync(),
  );
  final Map<String, PkceOAuthBackendMixin> backends =
      <String, PkceOAuthBackendMixin>{
        'onedrive': OneDriveSyncBackend.instance,
        'dropbox': DropboxSyncBackend.instance,
      };

  for (final MapEntry<String, PkceOAuthBackendMixin> entry
      in backends.entries) {
    test('${entry.key}: authorize URL matches registration contract', () {
      final Map<String, dynamic> expected =
          contract[entry.key] as Map<String, dynamic>;
      // Exercise the same protected provider hooks authenticate() consumes.
      // ignore: invalid_use_of_protected_member
      final String redirect = entry.value.mobileRedirectUri;
      // ignore: invalid_use_of_protected_member
      final Uri url = entry.value.buildAuthUrl('test-challenge', redirect);
      expect(url.queryParameters['client_id'], expected['clientId']);
      expect(
        url.queryParameters['redirect_uri'],
        expected['mobileRedirectUri'],
        reason:
            'Update the cloud registration contract and save/read back '
            'Azure or Dropbox registration when changing a redirect URI.',
      );
      expect(url.queryParameters['code_challenge_method'], 'S256');
      // ignore: invalid_use_of_protected_member
      expect(entry.value.desktopLoopbackPort, expected['desktopLoopbackPort']);
      expect(expected['retainLegacyRedirectUri'], 'hibiki://auth/${entry.key}');
      expect(
        expected['cloudVerification'],
        isIn(<String>['pending', 'verified']),
      );
      if (expected['cloudVerification'] == 'verified') {
        expect(expected['verifiedOn'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        expect(
          expected['observedRedirectUris'],
          contains(expected['mobileRedirectUri']),
          reason:
              'A changed callback requires fresh cloud readback; '
              'mark verification pending until it has been checked.',
        );
        if (entry.key == 'dropbox') {
          expect(
            expected['observedRedirectUris'],
            contains('http://localhost:${expected['desktopLoopbackPort']}'),
          );
        }
      }

      final Uri callback = Uri.parse(redirect);
      final Iterable<XmlElement> receivers = manifest
          .findAllElements('activity')
          .where(
            (XmlElement activity) =>
                _androidAttribute(activity, 'name') == '.MainActivity' &&
                _androidAttribute(activity, 'exported') == 'true',
          )
          .expand(
            (XmlElement activity) => activity.findElements('intent-filter'),
          );
      expect(
        receivers.any((XmlElement filter) {
          final Set<String?> actions = filter
              .findElements('action')
              .map((XmlElement element) => _androidAttribute(element, 'name'))
              .toSet();
          final Set<String?> categories = filter
              .findElements('category')
              .map((XmlElement element) => _androidAttribute(element, 'name'))
              .toSet();
          return actions.contains('android.intent.action.VIEW') &&
              categories.contains('android.intent.category.BROWSABLE') &&
              categories.contains('android.intent.category.DEFAULT') &&
              filter
                  .findElements('data')
                  .any(
                    (XmlElement data) =>
                        _androidAttribute(data, 'scheme') == callback.scheme &&
                        _androidAttribute(data, 'host') == callback.host &&
                        (_androidAttribute(data, 'path') == null ||
                            _androidAttribute(data, 'path') == callback.path),
                  );
        }),
        isTrue,
        reason: 'Android must accept the contracted OAuth callback.',
      );

      final Iterable<XmlElement> schemes = plist
          .findAllElements('key')
          .where((XmlElement key) => key.innerText == 'CFBundleURLSchemes')
          .map((XmlElement key) => key.nextElementSibling!)
          .expand((XmlElement array) => array.findElements('string'));
      expect(
        schemes.map((XmlElement scheme) => scheme.innerText),
        contains(callback.scheme),
      );
    });
  }
}
