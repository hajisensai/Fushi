import 'dart:io';

import 'package:fushi/src/media/manga/mihon/android_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

abstract final class MihonRuntimeFactory {
  static bool get isSupported => Platform.isAndroid || usesDesktopSidecar;

  /// 桌面三端走同一个 M-Extension-Server JVM sidecar（[DesktopMihonRuntime]）：
  /// 扩展 APK 落在数据目录、退出时要关掉子进程。sidecar 本身是平台无关的 JAR，
  /// 平台差异只在随包 JRE（`tool/mihon/build_desktop_runtime.*`）与它的位置。
  static bool get usesDesktopSidecar =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static MihonRuntime create(Directory dataDirectory) {
    if (Platform.isAndroid) return AndroidMihonRuntime();
    if (usesDesktopSidecar) {
      return DesktopMihonRuntime(dataDirectory: dataDirectory);
    }
    throw const MihonRuntimeException(
      'UNSUPPORTED_PLATFORM',
      'Mihon extensions are supported on Android, Windows, macOS, and Linux',
    );
  }
}
