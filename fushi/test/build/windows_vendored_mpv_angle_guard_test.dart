import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-1172 source-scan guard: the Windows media_kit video libraries (libmpv +
/// ANGLE) are vendored into the repo so a clean Windows build is fully
/// self-contained and never downloads .7z archives from GitHub at CMake
/// configure time.
///
/// Root cause: `third_party/media_kit_libs_windows_video/windows/CMakeLists.txt`
/// used `file(DOWNLOAD)` to fetch `mpv-dev-*.7z` and `ANGLE.7z` and hard
/// FATAL_ERROR'd on any network/integrity hiccup ("Integrity check failed"),
/// making Windows CI intermittently red. Worse, the upstream libmpv host
/// (zhongfly/mpv-winbuild) prunes old releases on a ~30-day window, so a pinned
/// asset can 404 outright. TODO-1137 mirrored libmpv to a permanent release, but
/// the archives were still downloaded at build time. Fix (TODO-1172): both
/// archives are committed under `../vendored/` and CMake reads + MD5-verifies the
/// local copy. This test guards the mechanism so it cannot silently regress to a
/// network fetch and so the committed archives stay real (not empty/LFS/wrong).
void main() {
  // Tests run with CWD = `fushi/`; the vendored package lives at workspace root.
  const String pkgRoot = '../third_party/media_kit_libs_windows_video';
  final File cmakeFile = File('$pkgRoot/windows/CMakeLists.txt');

  String cmake() {
    expect(cmakeFile.existsSync(), isTrue,
        reason: 'expected CMakeLists at ${cmakeFile.absolute.path}');
    return cmakeFile.readAsStringSync();
  }

  String setValue(String text, String name) {
    final RegExp pattern = RegExp(r'set\(' + name + r'\s+"([^"]+)"\)');
    final RegExpMatch? m = pattern.firstMatch(text);
    expect(m, isNotNull, reason: 'CMakeLists must define set($name "...")');
    return m!.group(1)!;
  }

  // CMake source with comments masked, so the download regression guards match
  // real commands and never a mention of file(DOWNLOAD) in a comment.
  // TODO-2477: shared maskHashComments — equal-length masking that also strips
  // trailing `# ...` comments, which the old whole-line filter let through.
  String codeOnly(String text) => maskHashComments(text);

  void expectRealSevenZip(File archive) {
    expect(archive.existsSync(), isTrue,
        reason: 'vendored archive must exist at ${archive.absolute.path} '
            '(TODO-1172); CMake reads it instead of downloading');
    final List<int> bytes = archive.readAsBytesSync();
    // Never an empty/LFS-pointer/placeholder; the real 7z archives are MBs.
    expect(bytes.length, greaterThan(1024 * 1024),
        reason: '${archive.path} is suspiciously small (${bytes.length} '
            'bytes) - likely a placeholder, not the real archive');
    // 7z signature: 37 7A BC AF 27 1C.
    const List<int> magic = <int>[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];
    expect(bytes.length, greaterThanOrEqualTo(magic.length));
    expect(bytes.sublist(0, magic.length), equals(magic),
        reason: '${archive.path} does not start with the 7z magic bytes');
  }

  test('libmpv archive is vendored, real, and MD5 matches the CMake pin', () {
    final String text = cmake();
    final String name = setValue(text, 'LIBMPV');
    final String md5Pin = setValue(text, 'LIBMPV_MD5');
    final File archive = File('$pkgRoot/vendored/$name');

    expectRealSevenZip(archive);
    final String actual = md5.convert(archive.readAsBytesSync()).toString();
    expect(actual, equals(md5Pin),
        reason: 'vendored $name MD5 ($actual) must match the pinned '
            'LIBMPV_MD5 ($md5Pin); a mismatch means the wrong build was '
            'vendored and CMake would FATAL at configure time');
  });

  test('ANGLE archive is vendored, real, and MD5 matches the CMake pin', () {
    final String text = cmake();
    final String name = setValue(text, 'ANGLE');
    final String md5Pin = setValue(text, 'ANGLE_MD5');
    final File archive = File('$pkgRoot/vendored/$name');

    expectRealSevenZip(archive);
    final String actual = md5.convert(archive.readAsBytesSync()).toString();
    expect(actual, equals(md5Pin),
        reason: 'vendored $name MD5 ($actual) must match the pinned '
            'ANGLE_MD5 ($md5Pin)');
  });

  test(
      'CMakeLists reads the vendored archives and never downloads at build time',
      () {
    final String text = codeOnly(cmake());

    // Regression fence: no runtime GitHub download of the archives.
    expect(text.contains('file(DOWNLOAD'), isFalse,
        reason:
            'CMake must not download the .7z at configure time (TODO-1172); '
            'a network/integrity hiccup would FATAL the whole Windows build');
    expect(text.contains('download_and_verify('), isFalse,
        reason: 'the old downloading helper must be gone; use '
            'verify_vendored_archive on the committed local copy');

    // The vendored mechanism must be wired.
    expect(text.contains('verify_vendored_archive('), isTrue,
        reason: 'CMake must verify the committed archive locally');
    expect(RegExp(r'get_filename_component\(\s*VENDORED_DIR').hasMatch(text),
        isTrue,
        reason: 'VENDORED_DIR must resolve the committed archive directory');

    // Both archive paths must come from VENDORED_DIR, not a build-dir download.
    expect(text.contains(r'set(LIBMPV_ARCHIVE "${VENDORED_DIR}/${LIBMPV}")'),
        isTrue,
        reason: 'LIBMPV_ARCHIVE must point at the vendored copy');
    expect(
        text.contains(r'set(ANGLE_ARCHIVE "${VENDORED_DIR}/${ANGLE}")'), isTrue,
        reason: 'ANGLE_ARCHIVE must point at the vendored copy');
  });
}
