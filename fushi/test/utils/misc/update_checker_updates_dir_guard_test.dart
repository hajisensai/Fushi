import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-4104：更新清理会删掉 updates 目录里所有不是临时文件的条目，所以这个目录必须
/// 只属于 Fushi。非 Windows 以前直接用系统临时根（Linux `/tmp`、未沙盒 macOS 的共享
/// 临时目录），Steam Deck 上实测清理去删 `/tmp/sddm-auth-*`。
void main() {
  final String source = File(
    'lib/src/utils/misc/update_checker_download.dart',
  ).readAsStringSync();

  String updatesDirFunction() {
    final int start = source.indexOf(
      'Future<Directory> _updatesDirectoryForCurrentPlatform()',
    );
    expect(start, isNot(-1));
    final int end = source.indexOf('\n}\n', start);
    return source.substring(start, end);
  }

  test('updates dir never resolves to a shared temp root', () {
    final String body = updatesDirFunction();
    expect(body, isNot(contains('getTemporaryDirectory')));
    expect(body, isNot(contains('tempRootDirectory')));
    expect(body, isNot(contains('systemTemp')));
  });

  test(
    'non-Windows uses the app-only cache dir, always in an updates child',
    () {
      final String body = updatesDirFunction();
      expect(body, contains('AppPaths.appCacheRootDirectory()'));
      expect(body, contains("updates'"));
    },
  );
}
