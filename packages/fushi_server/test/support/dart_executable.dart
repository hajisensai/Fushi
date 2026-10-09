import 'dart:io';

import 'package:path/path.dart' as p;

/// 测试里起 Dart 子进程用的可执行文件。
///
/// `dart test` 下 [Platform.resolvedExecutable] 就是 dart；但 CI 的 server job 用
/// `flutter test` 跑本包，那时它是 flutter_tester，拿它跑 `.dart` 脚本子进程会一直挂起。
/// 这时改用 flutter 工具设置的 `FLUTTER_ROOT` 旁边的 SDK dart。
String dartExecutable() {
  final String current = Platform.resolvedExecutable;
  final String base = p.basenameWithoutExtension(current);
  if (base == 'dart') return current;
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final File sdkDart = File(p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart'));
    if (sdkDart.existsSync()) return sdkDart.path;
  }
  return 'dart';
}
