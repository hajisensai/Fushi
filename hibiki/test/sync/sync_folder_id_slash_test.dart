import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/webdav_sync_backend.dart';

// BUG-845: a path-style backend addresses a child file as `folderId + fileName`
// with NO separator (see WebDavOps.uploadJson). A per-book folderId therefore
// MUST end with `/`. `ensureBookFolder` appends it when it CREATES a folder, but
// ids also enter the cache from server PROPFIND hrefs
// (cacheBookFolderIds / restoreCache), and some WebDAV servers (Nutstore/坚果云)
// return collection hrefs WITHOUT a trailing slash. A slash-less cached id made
// `folderId + audioBookFileName(...)` fuse into `<root>/<title>audioBook_…` —
// spilling the file into the sync ROOT with the title glued to the file name,
// while updateAudioBookFile deleted the correct in-folder copy. These tests pin
// the invariant "every cached folderId ends with `/`", enforced at
// `ensureFolderIdTrailingSlash` on every cache-population site.

/// A slash-less collection href, exactly as a Nutstore-style server returns it.
const String _rootId = 'https://dav.example.com/hibiki-data/';
const String _slashlessBookHref = 'https://dav.example.com/hibiki-data/屍人荘の殺人';

void main() {
  group('ensureFolderIdTrailingSlash', () {
    test('appends a missing slash and leaves an existing one', () {
      expect(ensureFolderIdTrailingSlash(_slashlessBookHref),
          '$_slashlessBookHref/');
      expect(ensureFolderIdTrailingSlash('$_slashlessBookHref/'),
          '$_slashlessBookHref/');
    });
  });

  group('WebDavSyncBackend folderId trailing-slash invariant', () {
    final WebDavSyncBackend backend = WebDavSyncBackend.instance;
    setUp(backend.clearCache);
    tearDown(backend.clearCache);

    test('cacheBookFolderIds normalizes a slash-less server href', () {
      backend.cacheBookFolderIds(
          const [SyncFileRef(id: _slashlessBookHref, name: '屍人荘の殺人')]);
      expect(backend.cachedFolderIds['屍人荘の殺人'], '$_slashlessBookHref/');
    });

    test('restoreCache heals a slash-less persisted id and root id', () {
      backend.restoreCache(
        rootFolderId: 'https://dav.example.com/hibiki-data',
        titleToFolderId: const {'屍人荘の殺人': _slashlessBookHref},
      );
      expect(
          backend.cachedRootFolderId, 'https://dav.example.com/hibiki-data/');
      expect(backend.cachedFolderIds['屍人荘の殺人'], '$_slashlessBookHref/');
    });

    test(
        'ensureBookFolder cache-hit returns a slashed id so the write lands '
        'in-folder, not fused into the root', () async {
      // Seed the cache the way a compare/list flow does — with a raw href.
      backend.cacheBookFolderIds(
          const [SyncFileRef(id: _slashlessBookHref, name: '屍人荘の殺人')]);

      final String folderId = await backend.ensureBookFolder(
        bookTitle: '屍人荘の殺人',
        rootFolderId: _rootId,
      );
      expect(folderId, endsWith('/'),
          reason: 'a folderId used as a bare path prefix must end with `/`');

      // Reproduce WebDavOps.uploadJson's join (Uri.encodeComponent adds no
      // slashes, so a plain concat models the path shape).
      final String fileName = audioBookFileName(1705944232500, 123.45);
      final String writePath = '$folderId$fileName';
      expect(writePath, endsWith('/$fileName'),
          reason: 'the file must be a CHILD of the book folder');
      expect(writePath.contains('屍人荘の殺人$fileName'), isFalse,
          reason: 'the title must not fuse onto the file name (root spill)');
    });
  });

  group('InterconnectSyncBackend folderId trailing-slash invariant', () {
    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    setUp(backend.clearCache);
    tearDown(backend.clearCache);

    test('cacheBookFolderIds + ensureBookFolder cache-hit stay slashed',
        () async {
      backend.cacheBookFolderIds(
          const [SyncFileRef(id: _slashlessBookHref, name: '屍人荘の殺人')]);
      expect(backend.cachedFolderIds['屍人荘の殺人'], '$_slashlessBookHref/');

      final String folderId = await backend.ensureBookFolder(
        bookTitle: '屍人荘の殺人',
        rootFolderId: _rootId,
      );
      expect(folderId, endsWith('/'));
    });

    test('restoreCache heals slash-less persisted ids', () {
      backend.restoreCache(
        rootFolderId: 'https://dav.example.com/hibiki-data',
        titleToFolderId: const {'屍人荘の殺人': _slashlessBookHref},
      );
      expect(
          backend.cachedRootFolderId, 'https://dav.example.com/hibiki-data/');
      expect(backend.cachedFolderIds['屍人荘の殺人'], '$_slashlessBookHref/');
    });
  });
}
