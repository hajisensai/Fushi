// Guard: on Windows the player (libmpv-2.dll) and card mining (ffmpeg.exe /
// ffprobe.exe) run on ONE FFmpeg - the unified FFmpeg of tool/ffmpeg-unified,
// renamed to private fbd*.dll inside the vendored libmpv runtime archive.
//
// What used to go wrong: two independent FFmpeg builds (MSYS2 9.0.1 for the
// player, a --disable-everything 7.1.5 "ffmpeg-min" for mining) drifted apart,
// so videos could play but not be mined (missing filters / muxers / decoders),
// and the mining binary lacked the tls_pin_sha256 patch. These checks read the
// committed manifests (no unpacking) and fail when the shared closure, the
// recipe provenance or the release wiring regresses.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show md5, sha256;
import 'package:flutter_test/flutter_test.dart';

const String _lib = '../third_party/media_kit_libs_windows_video';

Map<String, String> _recipe() {
  final Map<String, String> out = <String, String>{};
  for (final String line in File(
    '../tool/ffmpeg-unified/recipe.env',
  ).readAsLinesSync()) {
    if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
    final int i = line.indexOf('=');
    out[line.substring(0, i)] = line.substring(i + 1).trim();
  }
  return out;
}

List<Map<String, dynamic>> _manifest() =>
    (jsonDecode(File('$_lib/native-runtime-manifest.json').readAsStringSync())
            as List<dynamic>)
        .cast<Map<String, dynamic>>();

Map<String, dynamic> _entry(String name) => _manifest().firstWhere(
  (Map<String, dynamic> e) => (e['name'] as String).toLowerCase() == name,
  orElse: () => fail('runtime manifest has no $name'),
);

List<String> _imports(String name) =>
    ((_entry(name)['imports_and_forwarders'] as List<dynamic>).cast<String>())
        .map((String s) => s.toLowerCase())
        .toList();

void main() {
  const Set<String> systemDlls = <String>{
    'advapi32.dll',
    'bcrypt.dll',
    'crypt32.dll',
    'gdi32.dll',
    'kernel32.dll',
    'kernelbase.dll',
    'msvcrt.dll',
    'ncrypt.dll',
    'ole32.dll',
    'oleaut32.dll',
    'secur32.dll',
    'shell32.dll',
    'user32.dll',
    'ws2_32.dll',
    'shlwapi.dll',
  };

  test('ffmpeg.exe / ffprobe.exe ship in the libmpv runtime closure', () {
    final Set<String> names = _manifest()
        .map((Map<String, dynamic> e) => (e['name'] as String).toLowerCase())
        .toSet();
    for (final String exe in <String>[
      'ffmpeg.exe',
      'ffprobe.exe',
      'libmpv-2.dll',
    ]) {
      expect(names, contains(exe), reason: 'runtime manifest must carry $exe');
    }
    // Every private import of the programs resolves inside the shipped closure;
    // anything else must be a Windows system DLL.
    for (final String exe in <String>['ffmpeg.exe', 'ffprobe.exe']) {
      for (final String dll in _imports(exe)) {
        expect(
          names.contains(dll) || systemDlls.contains(dll),
          isTrue,
          reason:
              '$exe imports $dll, which is neither in the shipped closure '
              'nor a system DLL',
        );
      }
    }
  });

  test('player and mining load the SAME FFmpeg libraries', () {
    final Set<String> mpv = _imports('libmpv-2.dll').toSet();
    for (final String exe in <String>['ffmpeg.exe', 'ffprobe.exe']) {
      final Set<String> ffLibs = _imports(exe)
          .where(
            (String d) =>
                RegExp(r'^fbd(odec|ormat|til|ilter|cale|esample)-').hasMatch(d),
          )
          .toSet();
      expect(ffLibs, isNotEmpty, reason: '$exe imports no FFmpeg library?');
      // libmpv links libavcodec/format/util/filter/swscale/swresample; the
      // programs must import exactly those same private files.
      expect(
        mpv.containsAll(ffLibs.where((String d) => !d.startsWith('fbdevice'))),
        isTrue,
        reason:
            'ffmpeg/ffprobe FFmpeg libs $ffLibs are not the ones libmpv '
            'loads ($mpv): two FFmpeg builds would ship again',
      );
    }
  });

  test(
    'the shipped FFmpeg is the unified recipe build (version, commit, patches)',
    () {
      final Map<String, String> recipe = _recipe();
      final List<dynamic> packages =
          jsonDecode(
                File(
                  '$_lib/native-dependency-packages.json',
                ).readAsStringSync(),
              )
              as List<dynamic>;
      final Map<String, dynamic> unified = packages
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (Map<String, dynamic> p) => p['name'] == 'fushi-unified-ffmpeg',
            orElse: () => fail('no fushi-unified-ffmpeg provenance entry'),
          );
      expect(unified['version'], recipe['FFMPEG_VERSION']);
      expect(unified['upstream_commit'], recipe['FFMPEG_COMMIT']);
      final Map<String, String> repoPatches = <String, String>{
        for (final File f
            in Directory('../tool/ffmpeg-unified/patches/ffmpeg')
                .listSync()
                .whereType<File>()
                .where((File f) => f.path.endsWith('.patch')))
          f.uri.pathSegments.last: sha256
              .convert(f.readAsBytesSync())
              .toString(),
      };
      expect(
        (unified['patches'] as Map<String, dynamic>).cast<String, String>(),
        repoPatches,
        reason:
            'the vendored runtime was built from a different patch set than '
            'tool/ffmpeg-unified/patches/ffmpeg - rebuild and re-vendor it',
      );
      // MSYS2's own FFmpeg package must not sneak back into the closure.
      expect(
        packages.cast<Map<String, dynamic>>().map(
          (Map<String, dynamic> p) => p['name'],
        ),
        isNot(contains('mingw-w64-x86_64-ffmpeg')),
      );
    },
  );

  test('CMake pins the unified archive and its MD5 matches', () {
    final String cmake = File(
      '$_lib/windows/CMakeLists.txt',
    ).readAsStringSync();
    final String name = RegExp(
      r'set\(LIBMPV "([^"]+)"\)',
    ).firstMatch(cmake)!.group(1)!;
    final String pinned = RegExp(
      r'set\(LIBMPV_MD5 "([0-9a-f]+)"\)',
    ).firstMatch(cmake)!.group(1)!;
    expect(
      name,
      contains('-ffu'),
      reason: 'archive suffix marks the unified FFmpeg build',
    );
    final File archive = File('$_lib/vendored/$name');
    expect(archive.existsSync(), isTrue, reason: 'missing ${archive.path}');
    expect(md5.convert(archive.readAsBytesSync()).toString(), pinned);
  });

  test('release-desktop relies on the runtime closure, not ffmpeg-min', () {
    final String workflow = File(
      '../.github/workflows/release-desktop.yml',
    ).readAsStringSync();
    expect(
      workflow,
      isNot(contains('ffmpeg-min')),
      reason:
          'the minimal desktop ffmpeg is gone; ffmpeg.exe comes from the '
          'libmpv runtime (runtime-files.cmake)',
    );
    expect(
      workflow,
      isNot(contains('gh run download')),
      reason: 'no cross-workflow artifact supply (TODO-416)',
    );
    expect(
      workflow,
      contains('tool/ffmpeg-unified/verify_ffmpeg_capabilities.py'),
    );
    expect(workflow, contains('tool/ffmpeg-unified/smoke-test.sh'));
    expect(
      Directory('../third_party/ffmpeg-min/windows').existsSync(),
      isFalse,
      reason: 'a second Windows FFmpeg must not be vendored again',
    );
  });
}
