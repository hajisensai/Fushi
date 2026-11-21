// Reuse the files native-asset build hooks download, across worktrees.
//
// Why (2026-11-20): every fresh worktree's first `flutter test` re-downloaded
// pdfium (pdfium_dart 0.2.5, ~17 s from GitHub) and sqlite3 (sqlite3 3.5.2,
// ~2 s) into its own `.dart_tool/hooks_runner/shared/<pkg>/build/`. Those
// downloads are addressed by content, not by worktree path:
//   sqlite3/build/download-<first 8 hex of the file's sha256>/<lib>
//   pdfium_dart/build/chromium_<release>/<platform>-<arch>/<lib>
// so they can be copied in before the hook runs; the hooks find them and skip
// the download. Everything else under hooks_runner (input.json, hook.dill,
// dependency hashes) records absolute paths of the worktree that wrote it and
// is never copied.
//
// Verification before copying is mandatory:
// - sqlite3's hook re-checks the full sha256 of an existing file; we check the
//   8-hex prefix its directory name carries, so a truncated file is not copied.
// - pdfium_dart's hook only checks `File.exists()` (hook/build.dart
//   `_downloadPdfium`), and writes the file non-atomically. A half-written or
//   truncated library would be taken as-is and fail at load time, so pdfium
//   files are copied only when their sha256 matches [kPdfiumSha256].
//
// Tests: test/tools/worktree_seed_hook_downloads_test.dart.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'worktree_env.dart';

/// sha256 of the library pdfium_dart 0.2.5's hook extracts from
/// https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F7811
/// (`pdfium-<platform>-<arch>.tgz`, member `bin/pdfium.dll` / `lib/libpdfium.*`).
///
/// Collected 2026-11-20: each archive was downloaded, its sha256 matched the
/// digest GitHub lists for the release asset, and the member was hashed. The
/// four platforms present in local worktrees (win-x64, android-arm/arm64/x64)
/// hashed identically on disk. A pdfium_dart bump that changes the release
/// directory (`chromium_<n>`) simply finds no pin here and copies nothing.
const Map<String, String> kPdfiumSha256 = <String, String>{
  'chromium_7811/android-arm/libpdfium.so':
      '3d67be8a7f8a4f77e5a91530fbab69e0b27a8f4f4db5d4a0df512fbfaf40bd27',
  'chromium_7811/android-arm64/libpdfium.so':
      'ef8c440d29e2a0820a65554487d23020bd88756ee2d6aad8f8fb59bab3b2eb14',
  'chromium_7811/android-x64/libpdfium.so':
      'dd8c2880d41baf4c6406d5d2bf0c1beffe42b45e756ff08a9c612ad35d5a5c64',
  'chromium_7811/android-x86/libpdfium.so':
      '1f17b13f9a6dbbd7ac0ce5c1a82e74e50486c175f6d55d8c876f187b58362add',
  'chromium_7811/linux-arm/libpdfium.so':
      '47d514fc6f058df90bf8671bf0c7d82e5a9ab36a1224d0787a7305edd4974caf',
  'chromium_7811/linux-arm64/libpdfium.so':
      'f2cd46ddeb297a54082aac22eb23f21030bdd9cee4ac513a341e07dd9c51bcc7',
  'chromium_7811/linux-x64/libpdfium.so':
      'd106072a29b3689a5d6739948f98a97fe3ec82f5a1c309dc44e86f6c549fb44e',
  'chromium_7811/linux-x86/libpdfium.so':
      '02475862d602c74c7c5cbb1436d33bf4b404d3b1ea96d68b427398ed5fee8811',
  'chromium_7811/mac-arm64/libpdfium.dylib':
      '9f2b17bc233ee8ed2fa0fc794d39015f419bd22d8264c6bbb023365daa221fb5',
  'chromium_7811/mac-x64/libpdfium.dylib':
      '2c3d717277e2c9bdb1cc032045ea70bb1ebec0d19a32319a56b332cdaed7bf82',
  'chromium_7811/win-arm64/pdfium.dll':
      '0b4b52d6efe1858d565c600164af870c9954b8446e1a4a042b13a81672d23143',
  'chromium_7811/win-x64/pdfium.dll':
      '019b6ee6e54e5508002e43c5199b00f6caca26d32dd23c7bb229ff6855cd5394',
  'chromium_7811/win-x86/pdfium.dll':
      '4cee79604c985a058deeaf319ea7f4e1eed775b085c842001f602f35dfbefd8c',
};

/// A file younger than this may still be being written by a running hook.
const Duration kHookFileSettle = Duration(minutes: 2);

/// `<repo>/.dart_tool/hooks_runner/shared`: the hooks' shared output root.
String hookSharedRoot(String repoRoot) =>
    p.join(repoRoot, '.dart_tool', 'hooks_runner', 'shared');

final RegExp _sqliteRel = RegExp(
  r'^sqlite3/build/download-([0-9a-f]{8})/[^/]+$',
);
final RegExp _pdfiumRel = RegExp(
  r'^pdfium_dart/build/(chromium_[0-9]+/[a-z]+-[a-z0-9]+/[^/]+)$',
);

/// Whether [rel] (`/`-separated, relative to [hookSharedRoot]) is a
/// content-addressed download this tool may copy. Temp files, input.json,
/// hook.dill, `.lock` and per-input build directories are not.
bool isHookDownloadPath(String rel) =>
    !_isTempName(rel) && (_sqliteRel.hasMatch(rel) || _pdfiumRel.hasMatch(rel));

/// sqlite3's hook downloads to `<lib>.tmp` and renames; this tool copies via
/// `<file>.seeding-<pid>`. Neither is a finished download.
bool _isTempName(String rel) =>
    rel.endsWith('.tmp') || RegExp(r'\.seeding-[0-9]+$').hasMatch(rel);

/// Whether a file at [rel] with content hash [sha256Hex] may be copied:
/// sqlite3 downloads must match the hash prefix in their directory name,
/// pdfium downloads the pinned hash in [pins].
bool hookDownloadVerifies(
  String rel,
  String sha256Hex, {
  Map<String, String> pins = kPdfiumSha256,
}) {
  final RegExpMatch? sqlite = _sqliteRel.firstMatch(rel);
  if (sqlite != null) return sha256Hex.startsWith(sqlite.group(1)!);
  final RegExpMatch? pdfium = _pdfiumRel.firstMatch(rel);
  if (pdfium != null) return pins[pdfium.group(1)!] == sha256Hex;
  return false;
}

/// Content-addressed download files under [sharedRoot], as relative
/// `/`-separated paths. Missing roots yield nothing.
List<String> listHookDownloads(String sharedRoot) {
  final List<String> out = <String>[];
  final List<String> globs = <String>[
    p.join(sharedRoot, 'sqlite3', 'build'),
    p.join(sharedRoot, 'pdfium_dart', 'build'),
  ];
  for (final String base in globs) {
    final Directory dir = Directory(base);
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity e in dir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (e is! File) continue;
      final String rel = p
          .relative(e.path, from: sharedRoot)
          .replaceAll(r'\', '/');
      if (isHookDownloadPath(rel)) out.add(rel);
    }
  }
  out.sort();
  return out;
}

/// What [seedHookDownloads] did.
class HookSeedReport {
  HookSeedReport();

  /// Relative paths copied into the target, with the source root they came from.
  final Map<String, String> copied = <String, String>{};

  /// Relative paths the target already had.
  final List<String> present = <String>[];

  /// Relative paths seen in a source but rejected (empty, still being written,
  /// hash mismatch, no pin), with the reason.
  final Map<String, String> rejected = <String, String>{};

  /// Relative paths newly stored in the machine-wide cache.
  final List<String> cached = <String>[];
}

String _sha256Of(File f) => sha256.convert(f.readAsBytesSync()).toString();

/// Copy [src] to [dst] through a temp name in the same directory, so a reader
/// (a hook, or another setup) never sees a partial file.
void _copyAtomically(File src, String dst) {
  Directory(p.dirname(dst)).createSync(recursive: true);
  final String tmp = '$dst.seeding-$pid';
  src.copySync(tmp);
  File(tmp).renameSync(dst);
}

/// Copy verified hook downloads into [targetShared] from [sourceShared] roots
/// (machine cache first, then sibling worktrees — order is preference), and
/// store anything verified that the cache at [cacheRoot] lacks.
///
/// A file is taken from a source only when it is non-empty, unmodified for
/// [settle] before [now], and passes [hookDownloadVerifies]. Files the target
/// already has are left alone.
HookSeedReport seedHookDownloads({
  required String targetShared,
  required List<String> sourceShared,
  String? cacheRoot,
  DateTime? now,
  Duration settle = kHookFileSettle,
  Map<String, String> pins = kPdfiumSha256,
}) {
  final HookSeedReport report = HookSeedReport();
  final DateTime cutoff = (now ?? DateTime.now()).subtract(settle);
  final List<String> sources = <String>[
    if (cacheRoot != null) cacheRoot,
    ...sourceShared.where((String s) => !samePath(s, targetShared)),
  ];
  final Set<String> done = <String>{};
  for (final String source in sources) {
    for (final String rel in listHookDownloads(source)) {
      if (done.contains(rel)) continue;
      final String dst = p.join(targetShared, rel);
      final File dstFile = File(dst);
      if (dstFile.existsSync() && dstFile.lengthSync() > 0) {
        done.add(rel);
        report.rejected.remove(rel);
        report.present.add(rel);
        _storeInCache(dstFile, rel, cacheRoot, cutoff, pins, report);
        continue;
      }
      final File src = File(p.join(source, rel));
      final FileStat stat = src.statSync();
      if (stat.size <= 0) {
        report.rejected[rel] = 'empty in $source';
        continue;
      }
      if (stat.modified.isAfter(cutoff)) {
        report.rejected[rel] =
            'modified within ${settle.inSeconds} s in $source';
        continue;
      }
      if (!hookDownloadVerifies(rel, _sha256Of(src), pins: pins)) {
        report.rejected[rel] = 'sha256 does not verify in $source';
        continue;
      }
      _copyAtomically(src, dst);
      done.add(rel);
      report.rejected.remove(rel);
      report.copied[rel] = source;
      if (source != cacheRoot) {
        _storeInCache(File(dst), rel, cacheRoot, null, pins, report);
      }
    }
  }
  return report;
}

/// Put [file] (already verified when [cutoff] is null) into the cache at
/// [cacheRoot] under [rel] if the cache lacks it.
void _storeInCache(
  File file,
  String rel,
  String? cacheRoot,
  DateTime? cutoff,
  Map<String, String> pins,
  HookSeedReport report,
) {
  if (cacheRoot == null) return;
  final String dst = p.join(cacheRoot, rel);
  final File dstFile = File(dst);
  if (dstFile.existsSync() && dstFile.lengthSync() > 0) return;
  if (cutoff != null) {
    final FileStat stat = file.statSync();
    if (stat.size <= 0 || stat.modified.isAfter(cutoff)) return;
    if (!hookDownloadVerifies(rel, _sha256Of(file), pins: pins)) return;
  }
  _copyAtomically(file, dst);
  report.cached.add(rel);
}
