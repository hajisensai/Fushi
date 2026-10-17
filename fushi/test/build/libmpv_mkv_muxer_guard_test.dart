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
/// 统一 FFmpeg（tool/ffmpeg-unified）后，libmpv 不再自带 FFmpeg：它动态链接 app
/// 里那一份统一 FFmpeg 的 libavformat。所以「dump-cache 有 matroska muxer」= 两件事
/// 同时成立：
///   1. 入库的 libmpv 真的链接统一 FFmpeg 的 libavformat（Apple：Mpv 的
///      `@rpath/libavformat.framework/libavformat`；Android：libmpv.so 的
///      `DT_NEEDED libavformat.so`），而不是又塞了一份私有 FFmpeg；
///   2. 统一 FFmpeg 的每份 libavformat 都编进了 `matroskaenc.c`（源文件名只在 muxer
///      编入时出现）——这一条由 ffmpeg_unified_mobile_guard_test 逐 ABI / 切片钉住，
///      这里再对 libmpv 实际会加载的那一份复核。
/// Windows 的 ffu 运行时由 ffmpeg_unified_windows_runtime_guard_test 钉住。
void main() {
  const String thirdParty = '../third_party';
  final Uint8List marker = Uint8List.fromList(latin1.encode('matroskaenc'));

  bool containsBytes(List<int> haystack, List<int> needle) {
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
    test('$plat：Mpv 链接统一 FFmpeg 的 libavformat，且那份带 matroska muxer', () {
      final Archive tar = TarDecoder().decodeBytes(
        gzip.decode(File(vendoredDarwinArchive(plat)).readAsBytesSync()),
      );
      final List<ArchiveFile> mpv = tar.files
          .where((ArchiveFile f) =>
              f.isFile && !f.isSymbolicLink && p.posix.basename(f.name) == 'Mpv')
          .toList();
      expect(mpv, isNotEmpty);
      for (final ArchiveFile slice in mpv) {
        expect(
          containsBytes(slice.content as List<int>,
              latin1.encode('@rpath/libavformat.framework/libavformat')),
          isTrue,
          reason: '${slice.name} 不链接统一 FFmpeg 的 libavformat',
        );
      }
      expect(
        tar.files.any((ArchiveFile f) => f.name.contains('Avformat.framework/')),
        isFalse,
        reason: 'libmpv 归档又带了私有 FFmpeg（Avformat.framework）',
      );

      final List<List<int>> formats = <List<int>>[];
      if (plat == 'ios') {
        for (final String slice in <String>[
          'ios-arm64',
          'ios-arm64_x86_64-simulator',
        ]) {
          formats.add(File('$thirdParty/ffmpeg_kit_next_flutter/ios/'
                  'ffmpeg_kit_next_flutter/Frameworks/libavformat.xcframework/'
                  '$slice/libavformat.framework/libavformat')
              .readAsBytesSync());
        }
      } else {
        final Archive layout = TarDecoder().decodeBytes(gzip.decode(
            File('$thirdParty/media_kit_libs_macos_video/native/'
                    'ffmpeg-unified-macos.tar.gz')
                .readAsBytesSync()));
        formats.add(layout
            .findFile('Frameworks/libavformat.framework/Versions/A/libavformat')!
            .content as List<int>);
      }
      for (final List<int> format in formats) {
        expect(containsBytes(format, marker), isTrue,
            reason: '$plat 统一 FFmpeg 的 libavformat 没有 matroskaenc，dump-cache 会恒失败');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('Android：libmpv.so 链接 AAR 里的 libavformat.so，且那份带 matroska muxer', () {
    const String gradleDir = '$thirdParty/media_kit_libs_android_video/android';
    final String gradle = File('$gradleDir/build.gradle').readAsStringSync();
    final RegExpMatch? m = RegExp(
      r"\.orElse\(file\('([^']+)'\)\.absolutePath\)",
    ).firstMatch(gradle);
    expect(m, isNotNull, reason: 'build.gradle 没有默认的入库 jar 目录');
    final String jarDir = p.join(gradleDir, m!.group(1)!);
    final Archive aar = ZipDecoder().decodeBytes(File(
            '$thirdParty/ffmpeg_kit_next_flutter/android/libs/ffmpeg-kit-next.aar')
        .readAsBytesSync());
    for (final String abi in <String>['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      final Archive jar = ZipDecoder().decodeBytes(
        File(p.join(jarDir, 'full-$abi.jar')).readAsBytesSync(),
      );
      final ArchiveFile? so = jar.findFile('lib/$abi/libmpv.so');
      expect(so, isNotNull, reason: '$abi：jar 里没有 libmpv.so');
      expect(
        containsBytes(so!.content as List<int>, latin1.encode('libavformat.so')),
        isTrue,
        reason: '$abi 的 libmpv.so 不依赖 libavformat.so（统一 FFmpeg）',
      );
      expect(
        containsBytes(so.content as List<int>, marker),
        isFalse,
        reason: '$abi 的 libmpv.so 自己带了 matroskaenc：又静态塞了一份私有 FFmpeg',
      );
      final ArchiveFile? format = aar.findFile('jni/$abi/libavformat.so');
      expect(format, isNotNull, reason: '$abi：AAR 里没有 libavformat.so');
      expect(containsBytes(format!.content as List<int>, marker), isTrue,
          reason: '$abi 统一 FFmpeg 的 libavformat.so 没有 matroskaenc');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
