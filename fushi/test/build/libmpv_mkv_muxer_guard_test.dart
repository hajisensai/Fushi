import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// BUG-2939（#1953）：在线视频制卡的缓冲副本（`snapshotCachedRange` → mpv
/// `dump-cache` 写 `.mkv`）要 libavformat 的 matroska muxer。上游 full flavor 把
/// muxer 全关了，Android / iOS / macOS 每次都报 `Output format not found`，失败又被
/// 静默吞掉回到远端抽取——缺了它不会有任何红，只是优化永远不生效。
///
/// 蓝光原盘菜单（PR #2012）起三端 libmpv 都是入库的自编产物，不再靠产物名里的
/// `mkvmux` 标签背书：这里直接打开构建实际使用的那份二进制，要求每个 ABI / slice
/// 的 libavformat 都编进了 `matroskaenc.c`（它的源文件名与专有选项字符串只在
/// muxer 编入时出现，demuxer 不带）。谁换回不带 muxer 的产物，这里先红。Windows
/// 的 `libmpv-2.dll` 是完整构建，本来就带。
void main() {
  const String thirdParty = '../third_party';
  final Uint8List marker = Uint8List.fromList(latin1.encode('matroskaenc'));

  bool containsBytes(List<int> haystack, Uint8List needle) {
    final int last = haystack.length - needle.length;
    for (int i = 0; i <= last; i++) {
      if (haystack[i] != needle[0]) continue;
      int j = 1;
      while (j < needle.length && haystack[i + j] == needle[j]) {
        j++;
      }
      if (j == needle.length) return true;
    }
    return false;
  }

  String vendoredDarwinArchive(String plat) {
    final String dir = '$thirdParty/media_kit_libs_${plat}_video/$plat';
    final String mk = File('$dir/Makefile').readAsStringSync();
    final RegExpMatch? m = RegExp(
      r'^MPV_XCFRAMEWORKS_VENDOR_ARCHIVE=\$\(abspath ([^)]+)\)$',
      multiLine: true,
    ).firstMatch(mk);
    expect(m, isNotNull, reason: '$plat：Makefile 没有指向入库的 libmpv 产物');
    return p.normalize(p.join(dir, m!.group(1)!));
  }

  for (final String plat in <String>['macos', 'ios']) {
    test('$plat xcframework 的每个 Avformat slice 都带 matroska muxer', () {
      final String archivePath = vendoredDarwinArchive(plat);
      final Archive tar = TarDecoder().decodeBytes(
        gzip.decode(File(archivePath).readAsBytesSync()),
      );
      final List<ArchiveFile> slices = tar.files
          .where(
            (ArchiveFile f) =>
                f.isFile &&
                // macOS 的 `Avformat.framework/Avformat` 是指向 Versions/A 的符号链接。
                !f.isSymbolicLink &&
                f.name.contains('Avformat.framework/') &&
                p.posix.basename(f.name) == 'Avformat',
          )
          .toList();
      expect(slices, isNotEmpty, reason: '$archivePath 里找不到 Avformat');
      for (final ArchiveFile slice in slices) {
        expect(
          containsBytes(slice.content as List<int>, marker),
          isTrue,
          reason:
              '${slice.name} 没有 matroskaenc：换回了没有 matroska muxer 的 '
              'libmpv，dump-cache 会恒失败',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('Android 四个 ABI 的 libmpv.so 都带 matroska muxer', () {
    const String gradleDir = '$thirdParty/media_kit_libs_android_video/android';
    final String gradle = File('$gradleDir/build.gradle').readAsStringSync();
    final RegExpMatch? m = RegExp(
      r"\.orElse\(file\('([^']+)'\)\.absolutePath\)",
    ).firstMatch(gradle);
    expect(m, isNotNull, reason: 'build.gradle 没有默认的入库 jar 目录');
    final String jarDir = p.join(gradleDir, m!.group(1)!);
    for (final String abi in <String>[
      'arm64-v8a',
      'armeabi-v7a',
      'x86_64',
      'x86',
    ]) {
      final Archive jar = ZipDecoder().decodeBytes(
        File(p.join(jarDir, 'full-$abi.jar')).readAsBytesSync(),
      );
      final ArchiveFile? so = jar.findFile('lib/$abi/libmpv.so');
      expect(so, isNotNull, reason: '$abi：jar 里没有 libmpv.so');
      expect(
        containsBytes(so!.content as List<int>, marker),
        isTrue,
        reason: '$abi 的 libmpv.so 没有 matroskaenc，dump-cache 会恒失败',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
