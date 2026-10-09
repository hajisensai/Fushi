import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const String androidLibmpvVendorDirectory =
    '../third_party/media_kit_libs_android_video/android/native/bluray-menu-v1';

/// Checks actual packaged bytes independently of artifact naming conventions.
Iterable<({String abi, String contents})> verifiedAndroidLibmpv() sync* {
  const Map<String, int> machines = <String, int>{
    'arm64-v8a': 183,
    'armeabi-v7a': 40,
    'x86_64': 62,
    'x86': 3,
  };
  final Map<String, Object?> manifest =
      (jsonDecode(
                File(
                  '$androidLibmpvVendorDirectory/sha256.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)
          .cast<String, Object?>();
  expect(
    manifest.keys.toSet(),
    machines.keys.map((String abi) => 'full-$abi.jar').toSet(),
  );
  expect(manifest.values.toSet(), hasLength(machines.length));
  final Map<String, dynamic> provenance =
      jsonDecode(
            File(
              '$androidLibmpvVendorDirectory/provenance.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final Map<String, dynamic> patches =
      provenance['patches'] as Map<String, dynamic>;
  for (final MapEntry<String, String> patch in const <String, String>{
    'patches/mpv/disc-navigation-state.patch':
        '../third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch',
    'patches/mpv/mpv_gl_dovi_p5.patch':
        '../tool/bluray/platforms/patches/mpv-gl-dovi-p5.patch',
  }.entries) {
    final String source = File(
      patch.value,
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      patches[patch.key],
      sha256.convert(utf8.encode(source)).toString(),
      reason: 'Rebuild Android jars after changing ${patch.value}',
    );
  }
  for (final MapEntry<String, int> entry in machines.entries) {
    final String abi = entry.key;
    final Uint8List jar = File(
      '$androidLibmpvVendorDirectory/full-$abi.jar',
    ).readAsBytesSync();
    expect(
      sha256.convert(jar).toString(),
      manifest['full-$abi.jar'],
      reason: abi,
    );
    final Archive archive = ZipDecoder().decodeBytes(jar);
    for (final String name in <String>[
      'libmpv.so',
      'libmediakitandroidhelper.so',
    ]) {
      final ArchiveFile? library = archive.findFile('lib/$abi/$name');
      expect(library, isNotNull, reason: '$abi/$name missing');
      final List<int> bytes = library!.content as List<int>;
      _verifyElf(bytes, entry.value, '$abi/$name');
    }
    final List<int> mpv =
        archive.findFile('lib/$abi/libmpv.so')!.content as List<int>;
    yield (abi: abi, contents: latin1.decode(mpv, allowInvalid: true));
  }
}

void _verifyElf(List<int> bytes, int machine, String what) {
  expect(bytes.take(4), <int>[0x7f, 0x45, 0x4c, 0x46], reason: what);
  expect(bytes[5], 1, reason: '$what must be little-endian');
  final Uint8List view = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final ByteData data = ByteData.sublistView(view);
  expect(data.getUint16(18, Endian.little), machine, reason: what);
  expect(bytes[4], machine == 183 || machine == 62 ? 2 : 1, reason: what);
  final bool is64 = bytes[4] == 2;
  final int offset = is64
      ? data.getUint64(32, Endian.little)
      : data.getUint32(28, Endian.little);
  final int size = data.getUint16(is64 ? 54 : 42, Endian.little);
  final int count = data.getUint16(is64 ? 56 : 44, Endian.little);
  int loadCount = 0;
  for (int i = 0; i < count; i++) {
    final int header = offset + i * size;
    if (data.getUint32(header, Endian.little) != 1) continue;
    loadCount++;
    final int alignment = is64
        ? data.getUint64(header + 48, Endian.little)
        : data.getUint32(header + 28, Endian.little);
    expect(alignment, greaterThanOrEqualTo(16384), reason: '$what LOAD $i');
  }
  expect(loadCount, greaterThan(0), reason: what);
}
