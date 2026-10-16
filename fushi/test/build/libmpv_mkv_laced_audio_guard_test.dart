import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// BUG-3453：libmpv 必须带 `patches/mkv-laced-audio-timestamps.patch`。
///
/// mkvmerge 把 Opus 每 8 帧打成一个 lacing 块、且不写 `DefaultDuration`；上游 mpv
/// 的 mkv demuxer 只给块里第一帧时间戳，其余帧 PTS/DTS 为空。在线视频制卡的缓冲
/// 副本走 `dump-cache`，FFmpeg 的 matroska muxer 把这些空时间戳的帧全部拒收
/// （`non monotonically increasing dts ... >= NOPTS` / `Failed writing packet`），
/// mpv 却照样报成功：副本里只剩约 1/8 的音频，制出来的片段只有 0.2～0.4 秒碎音频。
///
/// 补丁让后续帧按各自时长顺推时间戳（Opus 读包头 TOC；其余编码在有 BlockDuration
/// 时按帧数均分，与 FFmpeg 的 matroska demuxer 同法）。本守卫钉住：补丁内容、构建
/// 脚本应用并用真库验证它、打包产物的 provenance 记录与仓内补丁逐字节一致（换了
/// 补丁却没重编 / 重新 vendor 会在这里红）。真库验证：
/// `tool/bluray/verify_mkv_lace_dump.py`（夹具 `tool/bluray/tests/laced-opus.mkv`）。
void main() {
  const String pkg = '../third_party/media_kit_libs_windows_video';
  final File patch = File('$pkg/patches/mkv-laced-audio-timestamps.patch');

  test('补丁按帧时长顺推 lacing 后续帧的时间戳', () {
    expect(patch.existsSync(), isTrue);
    final String text = patch.readAsStringSync();
    expect(text, contains('+++ b/demux/demux_mkv.c'));
    // Opus 帧长来自包头 TOC（RFC 6716 3.1）。
    expect(text, contains('+static int mkv_opus_packet_samples('));
    expect(text, contains('!strcmp(track->codec_id, "A_OPUS")'));
    // 首帧仍走原分支（时间戳不变），后续帧才用顺推值。
    final int original = text.indexOf(
      ' if (i == 0 || track->default_duration) {',
    );
    final int derived = text.indexOf(
      '+            } else if (lace_pts != MP_NOPTS_VALUE) {',
    );
    final int advance = text.indexOf(
      '+                lace_pts = frame_duration > 0',
    );
    expect(original, greaterThanOrEqualTo(0));
    expect(derived, greaterThan(original));
    expect(advance, greaterThan(derived));
    // 编进二进制的可识别字符串：Android / Darwin 构建用它确认补丁生效。
    expect(text, contains('without DefaultDuration'));
  });

  test('构建脚本在既有补丁之后应用它，并用真库跑 dump 验证', () {
    final String script = File(
      '../tool/bluray/build_libmpv.ps1',
    ).readAsStringSync();
    final int crop = script.indexOf(r'patches\gpu-dumb-mode-hwdec-crop.patch');
    final int lace = script.indexOf(
      r'patches\mkv-laced-audio-timestamps.patch',
    );
    final int verify = script.indexOf('verify_mkv_lace_dump.py');
    expect(crop, greaterThanOrEqualTo(0));
    expect(lace, greaterThan(crop));
    expect(verify, greaterThan(lace));
    expect(File('../tool/bluray/tests/laced-opus.mkv').existsSync(), isTrue);
  });

  test('移动端本地构建脚本也带上同一份补丁', () {
    expect(
      File('../tool/bluray/platforms/build_android.sh').readAsStringSync(),
      contains('patches/mkv-laced-audio-timestamps.patch'),
    );
    expect(
      File('../tool/bluray/platforms/build_darwin.sh').readAsStringSync(),
      contains('patches/mpv-mkv-laced-audio-timestamps.patch'),
    );
    expect(
      File(
        '../tool/bluray/platforms/patches/darwin-build.patch',
      ).readAsStringSync(),
      contains(
        r'+    patch -p1 <${../../../patches/mpv-mkv-laced-audio-timestamps.patch}',
      ),
    );
  });

  test('vendored Windows libmpv 的 provenance 记录的正是这份补丁', () {
    final Map<String, dynamic> provenance =
        jsonDecode(
              File('$pkg/native-source-provenance.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final Map<String, dynamic> demuxPatches =
        provenance['demux_patches'] as Map<String, dynamic>;
    expect(
      demuxPatches['mkv-laced-audio-timestamps.patch'],
      sha256.convert(patch.readAsBytesSync()).toString(),
      reason:
          'patch changed without rebuilding and re-vendoring libmpv '
          '(tool/bluray/build_libmpv.ps1)',
    );
    final String cmake = File('$pkg/windows/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('-mkvlace1.7z"'));
  });

  // 补丁的 trace 字符串只在它编进去时出现在二进制里：直接打开构建实际使用的
  // 那份产物逐个 slice 找（同 libmpv_mkv_muxer_guard_test 的做法）。
  final Uint8List marker = Uint8List.fromList(
    latin1.encode('without DefaultDuration'),
  );

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

  for (final String plat in <String>['macos', 'ios']) {
    test('$plat xcframework 的每个 Mpv slice 都带这份补丁', () {
      final String dir = '../third_party/media_kit_libs_${plat}_video/$plat';
      final RegExpMatch? m = RegExp(
        r'^MPV_XCFRAMEWORKS_VENDOR_ARCHIVE=\$\(abspath ([^)]+)\)$',
        multiLine: true,
      ).firstMatch(File('$dir/Makefile').readAsStringSync());
      expect(m, isNotNull, reason: '$plat：Makefile 没有指向入库的 libmpv 产物');
      final Archive tar = TarDecoder().decodeBytes(
        gzip.decode(
          File(p.normalize(p.join(dir, m!.group(1)!))).readAsBytesSync(),
        ),
      );
      final List<ArchiveFile> slices = tar.files
          .where(
            (ArchiveFile f) =>
                f.isFile &&
                !f.isSymbolicLink &&
                f.name.contains('Mpv.framework/') &&
                p.posix.basename(f.name) == 'Mpv',
          )
          .toList();
      expect(slices, isNotEmpty);
      for (final ArchiveFile slice in slices) {
        expect(
          containsBytes(slice.content as List<int>, marker),
          isTrue,
          reason:
              '${slice.name} 没有 mkv-laced-audio-timestamps.patch：dump-cache '
              '会丢掉 mkvmerge Opus 每个 lacing 块里第一帧之后的音频',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
