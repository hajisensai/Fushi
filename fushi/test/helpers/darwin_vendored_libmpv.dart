import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

typedef DarwinLibmpvSlice = ({
  String platform,
  String identity,
  String mpv,
  String codec,
});

const Map<String, String> _darwinPackages = <String, String>{
  'macos': '../third_party/media_kit_libs_macos_video',
  'ios': '../third_party/media_kit_libs_ios_video',
};

final Map<String, List<DarwinLibmpvSlice>> _verified =
    <String, List<DarwinLibmpvSlice>>{};

/// Verifies the actual archive and every CPU slice, independent of its name.
List<DarwinLibmpvSlice> verifiedDarwinLibmpv(String platform) =>
    _verified.putIfAbsent(platform, () => _verifyDarwinLibmpv(platform));

List<DarwinLibmpvSlice> _verifyDarwinLibmpv(String platform) {
  final String package = _darwinPackages[platform]!;
  final Map<String, dynamic> provenance =
      jsonDecode(File('$package/native/provenance.json').readAsStringSync())
          as Map<String, dynamic>;
  final Uint8List compressed = File(
    '$package/native/${provenance['archive']}',
  ).readAsBytesSync();
  final String digest = sha256.convert(compressed).toString();
  expect(digest, provenance['archive_sha256'], reason: platform);
  final String makefile = File(
    '$package/$platform/Makefile',
  ).readAsStringSync();
  expect(makefile, contains('MPV_XCFRAMEWORKS_SHA256SUM=$digest'));
  expect(makefile, contains(r'cp "$(MPV_XCFRAMEWORKS_VENDOR_ARCHIVE)"'));
  expect(makefile, isNot(contains('curl -L')));
  for (final MapEntry<String, String> patch in const <String, String>{
    'native_navigation_patch_sha256':
        '../third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch',
    'dovi_patch_sha256':
        '../tool/bluray/platforms/patches/mpv-gl-dovi-p5.patch',
  }.entries) {
    final String text = File(
      patch.value,
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      provenance[patch.key],
      sha256.convert(utf8.encode(text)).toString(),
      reason: 'Rebuild $platform after changing ${patch.value}',
    );
  }
  final Archive archive = TarDecoder().decodeBytes(
    GZipDecoder().decodeBytes(compressed),
  );
  final List<DarwinLibmpvSlice> result = <DarwinLibmpvSlice>[];
  for (final ArchiveFile file in archive) {
    if (!file.isFile || file.isSymbolicLink || !file.name.endsWith('/Mpv')) {
      continue;
    }
    final String identifier = file.name
        .split('Mpv.xcframework/')[1]
        .split('/')[0];
    // Unified FFmpeg (tool/ffmpeg-unified): libmpv carries no FFmpeg of its
    // own; Mpv links @rpath/libavcodec.framework, shipped once by the FFmpeg
    // side of the app. The codec bytes come from that same build.
    expect(
      archive.files.any((ArchiveFile f) => f.name.contains('Avcodec.xcframework')),
      isFalse,
      reason: '$platform libmpv archive must not package its own FFmpeg',
    );
    final Map<String, Uint8List> mpv = _machoSlices(file.content as List<int>);
    final Map<String, Uint8List> codec = _machoSlices(
      _unifiedLibavcodec(platform, identifier),
    );
    expect(codec.keys.toSet(), mpv.keys.toSet());
    final String variant = identifier.contains('simulator')
        ? 'simulator'
        : platform == 'ios'
        ? 'device'
        : 'desktop';
    for (final String cpu in mpv.keys) {
      result.add((
        platform: platform,
        identity: '$variant:$cpu',
        mpv: latin1.decode(mpv[cpu]!),
        codec: latin1.decode(codec[cpu]!),
      ));
    }
  }
  expect(
    result.map((DarwinLibmpvSlice slice) => slice.identity).toList()..sort(),
    platform == 'ios'
        ? <String>['device:arm64', 'simulator:arm64', 'simulator:x86_64']
        // Fushi ships Apple Silicon only on macOS.
        : <String>['desktop:arm64'],
    reason: '$platform must contain every supported CPU slice exactly once',
  );
  return result;
}

/// The unified FFmpeg's libavcodec for the libmpv slice [identifier]:
/// iOS from the FFmpegKitNext plugin's xcframework, macOS from the unified
/// layout archive media_kit_libs_macos_video bundles into Contents/Frameworks.
List<int> _unifiedLibavcodec(String platform, String identifier) {
  if (platform == 'ios') {
    final File f = File(
      '../third_party/ffmpeg_kit_next_flutter/ios/ffmpeg_kit_next_flutter/'
      'Frameworks/libavcodec.xcframework/$identifier/libavcodec.framework/libavcodec',
    );
    expect(f.existsSync(), isTrue, reason: 'unified FFmpeg slice ${f.path}');
    return f.readAsBytesSync();
  }
  final Archive layout = TarDecoder().decodeBytes(
    GZipDecoder().decodeBytes(
      File('../third_party/media_kit_libs_macos_video/native/'
              'ffmpeg-unified-macos.tar.gz')
          .readAsBytesSync(),
    ),
  );
  final ArchiveFile? f =
      layout.findFile('Frameworks/libavcodec.framework/Versions/A/libavcodec');
  expect(f, isNotNull, reason: 'unified FFmpeg macOS libavcodec');
  return f!.content as List<int>;
}

Map<String, Uint8List> _machoSlices(List<int> bytes) {
  final Uint8List buffer = bytes is Uint8List
      ? bytes
      : Uint8List.fromList(bytes);
  final ByteData data = ByteData.sublistView(buffer);
  final int magic = data.getUint32(0);
  if (magic == 0xcafebabe || magic == 0xcafebabf) {
    final bool wide = magic == 0xcafebabf;
    final int count = data.getUint32(4);
    expect(count, inInclusiveRange(1, 16));
    final Map<String, Uint8List> result = <String, Uint8List>{};
    for (int index = 0; index < count; index++) {
      final int entry = 8 + index * (wide ? 32 : 20);
      final int offset = wide
          ? data.getUint64(entry + 8)
          : data.getUint32(entry + 8);
      final int size = wide
          ? data.getUint64(entry + 16)
          : data.getUint32(entry + 12);
      final Map<String, Uint8List> slice = _machoSlices(
        Uint8List.sublistView(buffer, offset, offset + size),
      );
      expect(result.keys.toSet().intersection(slice.keys.toSet()), isEmpty);
      result.addAll(slice);
    }
    return result;
  }
  expect(magic, 0xcffaedfe, reason: 'Expected a little-endian 64-bit Mach-O');
  expect(data.getUint32(12, Endian.little), 6, reason: 'Expected a dylib');
  final int cpu = data.getUint32(4, Endian.little);
  expect(cpu, anyOf(0x01000007, 0x0100000c));
  return <String, Uint8List>{cpu == 0x0100000c ? 'arm64' : 'x86_64': buffer};
}
