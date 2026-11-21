// Contract for fushi/tool/worktree_seed/hook_downloads.dart: only
// content-addressed hook downloads are copied between worktrees, and only after
// their content verifies (pdfium_dart's hook trusts mere existence).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/worktree_seed/hook_downloads.dart';
import '../../tool/worktree_seed/worktree_env.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

File _write(String root, String rel, List<int> bytes, {DateTime? mtime}) {
  final File f = File(p.join(root, rel));
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  f.setLastModifiedSync(
    mtime ?? DateTime.now().subtract(const Duration(hours: 1)),
  );
  return f;
}

void main() {
  late Directory tmp;
  late String target;
  late String sibling;
  late String cache;
  final List<int> pdfBytes = utf8.encode('pdfium-bytes');
  final List<int> sqlBytes = utf8.encode('sqlite-bytes');
  late String sqlRel;
  const String pdfRel = 'pdfium_dart/build/chromium_1/win-x64/pdfium.dll';
  late Map<String, String> pins;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hook_seed_');
    target = p.join(tmp.path, 'target');
    sibling = p.join(tmp.path, 'sibling');
    cache = p.join(tmp.path, 'cache');
    sqlRel =
        'sqlite3/build/download-${_sha(sqlBytes).substring(0, 8)}/sqlite3.dll';
    pins = <String, String>{'chromium_1/win-x64/pdfium.dll': _sha(pdfBytes)};
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'pinned chromium_7811 table covers the platforms flutter test uses here',
    () {
      expect(kPdfiumSha256.keys, contains('chromium_7811/win-x64/pdfium.dll'));
      for (final String sha in kPdfiumSha256.values) {
        expect(sha, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    },
  );

  test('only content-addressed downloads are candidates', () {
    expect(isHookDownloadPath(sqlRel), isTrue);
    expect(isHookDownloadPath(pdfRel), isTrue);
    expect(isHookDownloadPath('sqlite3/build/dbb4653d72/input.json'), isFalse);
    expect(
      isHookDownloadPath('sqlite3/build/download-0c2d3bfc/x.dll.tmp/y'),
      isFalse,
    );
    expect(
      isHookDownloadPath('pdfium_dart/build/dbb4653d72/output.json'),
      isFalse,
    );
    expect(isHookDownloadPath('sqlite3/.lock'), isFalse);
    expect(
      isHookDownloadPath('sqlite3/build/download-0c2d3bfc/sqlite3.dll.tmp'),
      isFalse,
    );
    expect(isHookDownloadPath('$pdfRel.seeding-1234'), isFalse);
  });

  test('copies verified files from a sibling and stores them in the cache', () {
    _write(sibling, sqlRel, sqlBytes);
    _write(sibling, pdfRel, pdfBytes);
    _write(sibling, 'sqlite3/build/dbb4653d72/input.json', utf8.encode('{}'));
    final HookSeedReport r = seedHookDownloads(
      targetShared: target,
      sourceShared: <String>[sibling],
      cacheRoot: cache,
      pins: pins,
    );
    expect(r.copied.keys, unorderedEquals(<String>[sqlRel, pdfRel]));
    expect(File(p.join(target, pdfRel)).readAsBytesSync(), pdfBytes);
    expect(File(p.join(target, sqlRel)).readAsBytesSync(), sqlBytes);
    expect(
      File(p.join(target, 'sqlite3/build/dbb4653d72/input.json')).existsSync(),
      isFalse,
    );
    expect(r.cached, unorderedEquals(<String>[sqlRel, pdfRel]));
    expect(File(p.join(cache, pdfRel)).readAsBytesSync(), pdfBytes);
    // No temp names left behind.
    expect(
      Directory(
        target,
      ).listSync(recursive: true).whereType<File>().map((File f) => f.path),
      everyElement(isNot(contains('.seeding'))),
    );
  });

  test('a truncated pdfium (hash not pinned) is never copied', () {
    _write(sibling, pdfRel, pdfBytes.sublist(0, 4));
    final HookSeedReport r = seedHookDownloads(
      targetShared: target,
      sourceShared: <String>[sibling],
      cacheRoot: cache,
      pins: pins,
    );
    expect(r.copied, isEmpty);
    expect(r.rejected[pdfRel], contains('sha256'));
    expect(File(p.join(target, pdfRel)).existsSync(), isFalse);
    expect(File(p.join(cache, pdfRel)).existsSync(), isFalse);
  });

  test('pdfium of an unpinned release is not copied', () {
    const String other = 'pdfium_dart/build/chromium_2/win-x64/pdfium.dll';
    _write(sibling, other, pdfBytes);
    final HookSeedReport r = seedHookDownloads(
      targetShared: target,
      sourceShared: <String>[sibling],
      pins: pins,
    );
    expect(r.copied, isEmpty);
  });

  test('sqlite3 file whose hash does not match its directory is skipped', () {
    const String bad = 'sqlite3/build/download-00000000/sqlite3.dll';
    _write(sibling, bad, sqlBytes);
    final HookSeedReport r = seedHookDownloads(
      targetShared: target,
      sourceShared: <String>[sibling],
      pins: pins,
    );
    expect(r.copied, isEmpty);
    expect(r.rejected.keys, <String>[bad]);
  });

  test('empty and still-being-written files are skipped', () {
    final DateTime now = DateTime.now();
    _write(sibling, sqlRel, <int>[]);
    _write(
      sibling,
      pdfRel,
      pdfBytes,
      mtime: now.subtract(const Duration(seconds: 30)),
    );
    final HookSeedReport r = seedHookDownloads(
      targetShared: target,
      sourceShared: <String>[sibling],
      now: now,
      pins: pins,
    );
    expect(r.copied, isEmpty);
    expect(r.rejected[sqlRel], contains('empty'));
    expect(r.rejected[pdfRel], contains('modified within'));
  });

  test(
    'cache is preferred, later sources fill gaps, target files are kept',
    () {
      final String sibling2 = p.join(tmp.path, 'sibling2');
      _write(cache, pdfRel, pdfBytes);
      _write(sibling, pdfRel, pdfBytes);
      _write(sibling, sqlRel, <int>[]);
      _write(sibling2, sqlRel, sqlBytes);
      final HookSeedReport r = seedHookDownloads(
        targetShared: target,
        sourceShared: <String>[sibling, sibling2],
        cacheRoot: cache,
        pins: pins,
      );
      expect(r.copied[pdfRel], cache);
      expect(r.copied[sqlRel], sibling2);
      expect(
        r.rejected,
        isEmpty,
        reason: 'a file resolved later is not reported as skipped',
      );

      final HookSeedReport again = seedHookDownloads(
        targetShared: target,
        sourceShared: <String>[sibling, sibling2],
        cacheRoot: cache,
        pins: pins,
      );
      expect(again.copied, isEmpty);
      expect(again.present, unorderedEquals(<String>[pdfRel, sqlRel]));
    },
  );

  test('the target worktree is never its own source', () {
    _write(target, pdfRel, pdfBytes);
    final HookSeedReport r = seedHookDownloads(
      targetShared: target,
      sourceShared: <String>[target],
      pins: pins,
    );
    expect(r.copied, isEmpty);
    expect(r.present, isEmpty);
  });

  group('worktree_env', () {
    test('parseWorktreeList keeps git order', () {
      const String porcelain =
          'worktree D:/a\nHEAD 1\nbranch refs/heads/x\n\nworktree D:/b\nHEAD 2\ndetached\n';
      expect(parseWorktreeList(porcelain), <String>['D:/a', 'D:/b']);
    });

    test('seedCacheRoot: override, LOCALAPPDATA, XDG, HOME', () {
      expect(
        seedCacheRoot(<String, String>{
          'FUSHI_SEED_CACHE': '/x',
          'LOCALAPPDATA': '/l',
        }),
        '/x',
      );
      expect(
        seedCacheRoot(<String, String>{'LOCALAPPDATA': '/l'}),
        p.join('/l', 'fushi-heavy'),
      );
      expect(
        seedCacheRoot(<String, String>{'XDG_CACHE_HOME': '/c'}),
        p.join('/c', 'fushi-heavy'),
      );
      expect(
        seedCacheRoot(<String, String>{'HOME': '/h'}),
        p.join('/h', '.cache', 'fushi-heavy'),
      );
      expect(seedCacheRoot(<String, String>{}), isNull);
    });
  });
}
