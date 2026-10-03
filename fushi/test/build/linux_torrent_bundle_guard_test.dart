import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Linux 桌面包随包内置 torrent 引擎的两端契约：
///  * runner CMake 把 `native/fushi_torrent/prebuilt/linux-x64/libfushi_torrent_ffi.so`
///    **copy-if-present** 进 `bundle/lib/`（缺了照样出包、回退外接 qBittorrent，
///    绝不能写成 FATAL_ERROR——没有任何流水线构建 Linux app，本机也常没 vcpkg）；
///  * Dart 侧默认加载按 `<exe 同级>/lib/` 的绝对路径找它，不押在裸名 dlopen 的
///    RUNPATH 语义上。
/// 两端路径任一漂移，Linux 包就会「随包了却加载不到」或「加载逻辑找不到随包件」。
void main() {
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: 'expected ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('Linux runner CMake copy-if-presents the torrent .so into bundle/lib',
      () {
    final String cmake = read('linux/CMakeLists.txt');
    const String soPath =
        'native/fushi_torrent/prebuilt/linux-x64/libfushi_torrent_ffi.so';
    expect(cmake, contains(soPath));
    final RegExp copyIfPresent = RegExp(
      r'if\(EXISTS "\$\{FUSHI_TORRENT_SO\}"\)\s*'
      r'install\(FILES "\$\{FUSHI_TORRENT_SO\}" DESTINATION "\$\{INSTALL_BUNDLE_LIB_DIR\}"',
    );
    expect(cmake, matches(copyIfPresent),
        reason:
            'torrent .so must be installed into bundle/lib only when present');
    final int start = cmake.indexOf('set(FUSHI_TORRENT_SO');
    final int end = cmake.indexOf('endif()', start);
    expect(start, isNonNegative);
    expect(cmake.substring(start, end), isNot(contains('FATAL_ERROR')),
        reason: 'a missing torrent .so must not fail the Linux build');
  });

  test('the bundled .so name matches what build_linux_so.sh produces', () {
    final String script = read('../native/fushi_torrent/build_linux_so.sh');
    expect(script, contains('prebuilt/linux-x64'));
    expect(script, contains('libfushi_torrent_ffi.so'));
  });

  test('EmbeddedTorrentEngine looks in <exe>/lib/ on Linux before bare name',
      () {
    final String engine =
        read('../packages/fushi_torrent/lib/src/embedded_torrent_engine.dart');
    expect(engine, contains('static List<String> defaultLibraryCandidates('));
    expect(engine, contains("'\${File(exe).parent.path}/lib'"));
    expect(engine,
        contains('final List<String> names = defaultLibraryCandidates();'),
        reason: 'the default open path must use the Linux bundle candidates');
  });
}
