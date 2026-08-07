import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes,
          [Map<String, Object?>? args]) async {
        final File image =
            await File('screenshots/$name.png').create(recursive: true);
        image.writeAsBytesSync(bytes);
        return true;
      },
    );
