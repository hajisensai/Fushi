import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/helpers/observe_capture.dart';

void main() {
  test('mobile fallback stores observe screenshots under system temp', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final Directory directory = observeScreenshotDir();

    expect(directory.path, startsWith(Directory.systemTemp.path));
  });
}
