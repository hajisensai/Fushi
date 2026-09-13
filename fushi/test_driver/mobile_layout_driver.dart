import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final Directory dir =
      Directory('../.codex-test/mobile-layout-0910/screenshots');
  await dir.create(recursive: true);
  await integrationDriver(onScreenshot: (String name, List<int> bytes,
      [Map<String, Object?>? args]) async {
    await File('${dir.path}/$name.png').writeAsBytes(bytes);
    return true;
  });
}
