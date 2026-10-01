import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:test/test.dart';

/// 桌面包把引擎库放在固定的包内目录：Linux `bundle/lib/`（runner CMake
/// copy-if-present）、macOS `Contents/Frameworks/`（Runner 构建阶段
/// `bundle_fushi_torrent.sh`）。默认加载必须先试这个绝对路径，不押在裸名
/// dlopen 的 RUNPATH / rpath 语义上；其余平台保持裸名。
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
    } else if (!Platform.isMacOS) {
      expect(candidates, EmbeddedTorrentEngine.defaultLibraryNames());
    }
  });

  test('macOS 先试 Contents/Frameworks 的绝对路径，再退裸名', () {
    final List<String> candidates =
        EmbeddedTorrentEngine.defaultLibraryCandidates(
            executablePath: '/Applications/fushi.app/Contents/MacOS/fushi');
    if (Platform.isMacOS) {
      expect(candidates, <String>[
        '/Applications/fushi.app/Contents/Frameworks/libfushi_torrent_ffi.dylib',
        'libfushi_torrent_ffi.dylib',
      ]);
    } else if (!Platform.isLinux) {
      expect(candidates, EmbeddedTorrentEngine.defaultLibraryNames());
    }
  });
}
