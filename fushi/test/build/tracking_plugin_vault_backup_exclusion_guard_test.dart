import 'dart:io';

import 'package:test/test.dart';

/// Tracking plugin credentials (`<support>/tracking_plugins/.credentials/`,
/// and the data key in flutter_secure_storage) never go with Android backup
/// or device transfer: both rule files exclude them, and the path follows the
/// plugin root the app model uses. Run from `fushi/`.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('the plugin root is still <database dir>/tracking_plugins', () {
    expect(
      read('lib/src/models/app_model.dart'),
      contains("path.join(databaseDirectory.path, 'tracking_plugins')"),
    );
  });

  test('both Android backup rule files exclude the credential vault', () {
    const List<String> rules = <String>[
      '<exclude domain="file" path="tracking_plugins/.credentials/" />',
      '<exclude domain="sharedpref" path="FlutterSecureStorage.xml" />',
      '<exclude domain="sharedpref" path="FlutterSecureKeyStorage.xml" />',
    ];
    final String legacy = read('android/app/src/main/res/xml/backup_rules.xml');
    final String modern = read(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    );
    final String cloud = modern.substring(
      modern.indexOf('<cloud-backup>'),
      modern.indexOf('</cloud-backup>'),
    );
    final String transfer = modern.substring(
      modern.indexOf('<device-transfer>'),
      modern.indexOf('</device-transfer>'),
    );
    for (final String rule in rules) {
      expect(legacy, contains(rule));
      expect(cloud, contains(rule));
      expect(transfer, contains(rule));
    }
  });
}
