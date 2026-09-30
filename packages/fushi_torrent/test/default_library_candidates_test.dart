import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:test/test.dart';

/// Linux 桌面包把 `libfushi_torrent_ffi.so` 放在 `bundle/lib/`（runner CMake
/// copy-if-present）。默认加载必须先试 `<exe 同级>/lib/` 的绝对路径，不押在
/// 裸名 dlopen 的 RUNPATH 语义上；其余平台保持裸名。
void main() {
  test('Linux 先试 exe 同级 lib/ 的绝对路径，再退裸名', () {
    final List<String> candidates =
        EmbeddedTorrentEngine.defaultLibraryCandidates(
            executablePath: '/opt/fushi/bundle/fushi');
    if (Platform.isLinux) {
      expect(candidates, <String>[
        '/opt/fushi/bundle/lib/libfushi_torrent_ffi.so',
        'libfushi_torrent_ffi.so',
      ]);
    } else {
      expect(candidates, EmbeddedTorrentEngine.defaultLibraryNames());
    }
  });
}
