import 'dart:io';

import 'package:hibiki/src/media/manga/mihon/android_mihon_runtime.dart';
import 'package:hibiki/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';

abstract final class MihonRuntimeFactory {
  static bool get isSupported =>
      Platform.isAndroid || Platform.isWindows || Platform.isMacOS;

  static MihonRuntime create(Directory dataDirectory) {
    if (Platform.isAndroid) return AndroidMihonRuntime();
    if (Platform.isWindows || Platform.isMacOS) {
      return DesktopMihonRuntime(dataDirectory: dataDirectory);
    }
    throw const MihonRuntimeException(
      'UNSUPPORTED_PLATFORM',
      'Mihon extensions are supported on Android, Windows, and macOS',
    );
  }
}
