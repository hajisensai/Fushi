import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS platform services use the AnkiMobile repository', () {
    final src =
        File('lib/src/platform/platform_services.dart').readAsStringSync();

    expect(
        src,
        contains(
            "import 'package:fushi/src/anki/ankimobile_repository.dart';"));
    expect(src, contains('if (Platform.isIOS)'));
    expect(src, contains('createAnkiRepository: AnkiMobileRepository.new'));
  });

  test('Riverpod Anki repository is created from PlatformServices', () {
    final src = File('lib/src/anki/anki_view_model.dart').readAsStringSync();

    expect(
        src,
        contains(
            "import 'package:fushi/src/platform/platform_providers.dart';"));
    expect(src, contains('ref.watch(platformServicesProvider)'));
    expect(src,
        isNot(contains('if (isAndroidPlatform) return AnkiRepository();')));
  });
}
