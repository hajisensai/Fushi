import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/android_vendored_libmpv.dart';

/// BUG-3499：libmpv 必须带 `patches/mkv-laced-audio-timestamps.patch`。
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
///
/// BUG-3500：同一条 dump-cache 链路上还有 `patches/recorder-video-dts.patch`。
/// Matroska 不存 DTS；recorder 见 demux_mkv 挂了 `lav_codecpar` 就不设
/// `video_delay`，libavformat 于是令 DTS = PTS，带 B 帧的 HEVC/H.264 每个重排帧都被
/// 拒收，副本视频只剩少数可解码帧（卡片视频花屏）。补丁让 recorder 自己按重排缓冲
/// 推 DTS，种子取本段起点。真库验证同一脚本（夹具 `tool/bluray/tests/open-gop-hevc.mkv`）。
void main() {
  const String pkg = '../third_party/media_kit_libs_windows_video';
  final File patch = File('$pkg/patches/mkv-laced-audio-timestamps.patch');
  final File dtsPatch = File('$pkg/patches/recorder-video-dts.patch');

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

  test('recorder 补丁给缺 DTS 的视频包按重排缓冲推 DTS，种子取本段起点', () {
    expect(dtsPatch.existsSync(), isTrue);
    final String text = dtsPatch.readAsStringSync();
    expect(text, contains('+++ b/common/recorder.c'));
    expect(text, contains('+static double guess_dts('));
    // 种子是本段输出起点 rebase_ts，不是首包 PTS（open GOP 前导帧 PTS 更早）。
    expect(text, contains('+            buf[i] = rst->owner->rebase_ts;'));
    // 只补视频、只补缺的；已有 DTS 的包（lavf 来源）原样不动。
    expect(
      text,
      contains(
        '+    if (mpkt.dts == MP_NOPTS_VALUE && mpkt.pts != MP_NOPTS_VALUE &&\n'
        '+        rst->sh->type == STREAM_VIDEO)\n'
        '+        mpkt.dts = guess_dts(rst, mpkt.pts);',
      ),
    );
    // 每次重新开始写一段（seek / 断点续写）都重新播种。
    expect(text, contains('+        rst->dts_seeded = false;'));
    // 编进二进制的可识别字符串：Android / Darwin 构建用它确认补丁生效。
    expect(text, contains('Deriving missing DTS'));
  });

  test('构建脚本在既有补丁之后应用它们，并用真库跑 dump 验证', () {
    final String script = File(
      '../tool/bluray/build_libmpv.ps1',
    ).readAsStringSync();
    final int crop = script.indexOf(r'patches\gpu-dumb-mode-hwdec-crop.patch');
    final int lace = script.indexOf(
      r'patches\mkv-laced-audio-timestamps.patch',
    );
    final int dts = script.indexOf(r'patches\recorder-video-dts.patch');
    final int verify = script.indexOf('verify_mkv_lace_dump.py');
    expect(crop, greaterThanOrEqualTo(0));
    expect(lace, greaterThan(crop));
    expect(dts, greaterThan(lace));
    expect(verify, greaterThan(dts));
    expect(File('../tool/bluray/tests/laced-opus.mkv').existsSync(), isTrue);
    expect(File('../tool/bluray/tests/open-gop-hevc.mkv').existsSync(), isTrue);
    final String verifier = File(
      '../tool/bluray/verify_mkv_lace_dump.py',
    ).readAsStringSync();
    expect(verifier, contains('"open-gop-hevc.mkv", "video"'));
  });

  test('移动端本地构建脚本也带上同样的补丁', () {
    final String android = File(
      '../tool/bluray/platforms/build_android.sh',
    ).readAsStringSync();
    expect(android, contains('patches/mkv-laced-audio-timestamps.patch'));
    expect(android, contains('patches/mpv/recorder-video-dts.patch'));
    final String darwin = File(
      '../tool/bluray/platforms/build_darwin.sh',
    ).readAsStringSync();
    expect(darwin, contains('patches/mpv-mkv-laced-audio-timestamps.patch'));
    expect(darwin, contains('patches/mpv-recorder-video-dts.patch'));
    final String nix = File(
      '../tool/bluray/platforms/patches/darwin-build.patch',
    ).readAsStringSync();
    expect(
      nix,
      contains(
        r'+    patch -p1 <${../../../patches/mpv-mkv-laced-audio-timestamps.patch}',
      ),
    );
    expect(
      nix,
      contains(
        r'+    patch -p1 <${../../../patches/mpv-recorder-video-dts.patch}',
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
    for (final File file in <File>[patch, dtsPatch]) {
      expect(
        demuxPatches[p.basename(file.path)],
        sha256.convert(file.readAsBytesSync()).toString(),
        reason:
            '${p.basename(file.path)} changed without rebuilding and '
            're-vendoring libmpv (tool/bluray/build_libmpv.ps1)',
      );
    }
    final String cmake = File('$pkg/windows/CMakeLists.txt').readAsStringSync();
    // `-mkvdts1` must stay in the pinned archive name; `-ffu1` (unified
    // FFmpeg rebuild) may follow it.
    expect(cmake, matches(RegExp(r'-mkvdts1(-ffu\d+)?\.7z"')));
  });

  // 补丁的 trace / debug 字符串只在它编进去时出现在二进制里：直接打开构建实际
  // 使用的那份产物逐个 slice 找（同 libmpv_mkv_muxer_guard_test 的做法）。
  final Map<String, Uint8List> markers = <String, Uint8List>{
    'mkv-laced-audio-timestamps.patch': Uint8List.fromList(
      latin1.encode('without DefaultDuration'),
    ),
    'recorder-video-dts.patch': Uint8List.fromList(
      latin1.encode('Deriving missing DTS'),
    ),
  };

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
        for (final MapEntry<String, Uint8List> marker in markers.entries) {
          expect(
            containsBytes(slice.content as List<int>, marker.value),
            isTrue,
            reason:
                '${slice.name} 没有 ${marker.key}：dump-cache 会丢掉 mkvmerge '
                'Opus lacing 帧 / Matroska B 帧视频',
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('Android 每个 ABI 的 libmpv.so 都带这两份补丁', () {
    final Map<String, dynamic> provenance =
        jsonDecode(
              File(
                '$androidLibmpvVendorDirectory/provenance.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final Map<String, dynamic> patches =
        provenance['patches'] as Map<String, dynamic>;
    for (final File file in <File>[patch, dtsPatch]) {
      expect(
        patches['patches/mpv/${p.basename(file.path)}'],
        sha256
            .convert(
              utf8.encode(file.readAsStringSync().replaceAll('\r\n', '\n')),
            )
            .toString(),
        reason: 'Rebuild Android jars after changing ${file.path}',
      );
    }
    int abis = 0;
    for (final ({String abi, String contents, String codec}) lib in verifiedAndroidLibmpv()) {
      abis++;
      expect(
        lib.contents,
        contains('without DefaultDuration'),
        reason: lib.abi,
      );
      expect(lib.contents, contains('Deriving missing DTS'), reason: lib.abi);
    }
    // arm64-v8a / armeabi-v7a / x86_64 (Flutter has no 32-bit x86 target).
    expect(abis, 3);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
