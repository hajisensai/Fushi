// BUG-3665（反馈 Tz04dfBf2f）：iOS 常驻来源文件夹的安全作用域书签。
//
// 原生半边（ios/Runner/FushiDirectoryImport.swift）本机编不了，这里钉 Dart 侧契约：
//  (1) configJson 书签编解码：独立键、保留其它键、凭据红线照旧。
//  (2) 扫描前在 iOS 上激活书签（先 start 后列目录）；非 iOS 一概不调原生。
//  (3) 书签过期 → 回写原生重建的新书签；解析失败 / 没存书签 / 文件夹被挪走 →
//      lastScanError 写明原因，不列目录、不伪装成 0 个媒体。
//  (4) 持有记账：同一来源只 start 一次（含并发），release 配对 stop。
//  (5) 登记来源时书签落进 configJson；一次性导入扫完释放访问。

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_folder_access.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

/// 记录调用顺序的原生书签 fake。
class _FakeBookmarks implements SourceFolderBookmarks {
  _FakeBookmarks(this.log);

  final List<String> log;

  /// 书签 → 解析结果；缺省按「路径 = 书签里 `path:` 之后的部分」解析。
  final Map<String, SourceFolderGrant> grants = <String, SourceFolderGrant>{};
  SourceFolderAccessException? startError;
  Completer<void>? startGate;
  int startCount = 0;
  final List<String> stopped = <String>[];

  @override
  Future<SourceFolderBookmarkPick?> pickDirectoryBookmark() async => null;

  @override
  Future<SourceFolderGrant> startAccessingBookmark(String bookmark) async {
    startCount++;
    log.add('start:$bookmark');
    final Completer<void>? gate = startGate;
    if (gate != null) await gate.future;
    final SourceFolderAccessException? error = startError;
    if (error != null) throw error;
    return grants[bookmark] ??
        SourceFolderGrant(
          path: bookmark.substring('path:'.length),
          stale: false,
        );
  }

  @override
  Future<void> stopAccessingBookmark(String path) async {
    log.add('stop:$path');
    stopped.add(path);
  }
}

/// 列目录时记一笔，用来断言「先 start 后列目录」。
class _RecordingFs extends LocalSourceFileSystem {
  const _RecordingFs(this.log);

  final List<String> log;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) {
    log.add('list:$dirPath');
    return super.listFiles(dirPath, recursive: recursive);
  }
}

Future<MediaSourceRow> _insertLocal(
  FushiDatabase db, {
  required String root,
  String? bookmark,
  String mediaKind = 'book',
}) async {
  final int id = await db.insertMediaSource(
    MediaSourcesCompanion(
      label: const Value('src'),
      mediaKind: Value(mediaKind),
      transport: const Value('local'),
      rootPath: Value(normalizeSourceRootPath(root, transport: 'local')),
      configJson: sourceConfigValueForBookmark(bookmark),
      recursive: const Value(true),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ),
  );
  return (await db.getMediaSourceById(id))!;
}

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late String root;
  late List<String> log;
  late _FakeBookmarks bookmarks;

  SourceFolderAccess access({required bool ios}) =>
      SourceFolderAccess(bookmarks: bookmarks, requiresBookmark: () => ios);

  setUp(() async {
    db = _memDb();
    tmp = await Directory.systemTemp.createTemp('source_folder_access_');
    root = normalizeSourceRootPath(tmp.path, transport: 'local');
    log = <String>[];
    bookmarks = _FakeBookmarks(log);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('configJson bookmark codec', () {
    test('round-trips the bookmark under its own key', () {
      final String? json = configWithSourceBookmark(null, 'Ym9va21hcms=');
      expect(sourceBookmarkFromConfig(json), 'Ym9va21hcms=');
      expect(decodeSourceConfig(json).keys, <String>[
        kSourceConfigIosBookmarkKey,
      ]);
    });

    test('replacing the bookmark keeps the other keys', () {
      final String? json = configWithSourceBookmark(
        encodeSourceConfig(<String, Object?>{
          'host': 'h',
          'iosBookmark': 'old',
        }),
        'new',
      );
      final Map<String, Object?> cfg = decodeSourceConfig(json);
      expect(cfg['host'], 'h');
      expect(cfg[kSourceConfigIosBookmarkKey], 'new');
    });

    test('credential red line still drops passwords next to a bookmark', () {
      final String? json = encodeSourceConfig(<String, Object?>{
        kSourceConfigIosBookmarkKey: 'bm',
        'password': 'secret',
        'privateKey': 'key',
      });
      expect(decodeSourceConfig(json).keys, <String>[
        kSourceConfigIosBookmarkKey,
      ]);
      expect(sourceBookmarkFromConfig(json), 'bm');
    });

    test('missing / empty / non-string bookmark reads as null', () {
      expect(sourceBookmarkFromConfig(null), isNull);
      expect(sourceBookmarkFromConfig('{"iosBookmark":""}'), isNull);
      expect(sourceBookmarkFromConfig('{"iosBookmark":3}'), isNull);
      expect(sourceConfigValueForBookmark(null).present, isFalse);
    });
  });

  group('scanner on iOS', () {
    test('activates the bookmark before listing the root', () async {
      final MediaSourceRow row = await _insertLocal(
        db,
        root: root,
        bookmark: 'path:$root',
      );
      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
        folderAccess: access(ios: true),
      ).scan(row, fs: _RecordingFs(log));

      expect(summary.error, isNull);
      expect(log, <String>['start:path:$root', 'list:$root']);
    });

    test('stale bookmark is replaced by the refreshed one', () async {
      final MediaSourceRow row = await _insertLocal(
        db,
        root: root,
        bookmark: 'old-bookmark',
      );
      bookmarks.grants['old-bookmark'] = SourceFolderGrant(
        path: root,
        stale: true,
        refreshedBookmark: 'fresh-bookmark',
      );
      await SourceLibraryScanner(
        db,
        folderAccess: access(ios: true),
      ).scan(row, fs: _RecordingFs(log));

      final MediaSourceRow after = (await db.getMediaSourceById(row.id))!;
      expect(sourceBookmarkFromConfig(after.configJson), 'fresh-bookmark');
      expect(after.lastScanError, isNull);
    });

    test(
      'resolve failure reports an explicit reason and does not list',
      () async {
        final MediaSourceRow row = await _insertLocal(
          db,
          root: root,
          bookmark: 'path:$root',
        );
        bookmarks.startError = const SourceFolderAccessException(
          'RESOLVE_FAILED',
          'The file couldn’t be opened.',
        );
        final SourceScanSummary summary = await SourceLibraryScanner(
          db,
          folderAccess: access(ios: true),
        ).scan(row, fs: _RecordingFs(log));

        final String expected = t.media_source_folder_access_resolve_failed(
          reason: 'The file couldn’t be opened.',
        );
        expect(summary.error, expected);
        expect(summary.importedMediaCount, 0);
        expect(log.where((String e) => e.startsWith('list:')), isEmpty);
        final MediaSourceRow after = (await db.getMediaSourceById(row.id))!;
        expect(after.lastScanError, expected);
      },
    );

    test('source without a bookmark (added before the fix) says so', () async {
      final MediaSourceRow row = await _insertLocal(db, root: root);
      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
        folderAccess: access(ios: true),
      ).scan(row, fs: _RecordingFs(log));

      expect(summary.error, t.media_source_folder_access_missing);
      expect(bookmarks.startCount, 0);
      expect(log, isEmpty);
    });

    test(
      'folder moved elsewhere: stop access and report the new path',
      () async {
        final MediaSourceRow row = await _insertLocal(
          db,
          root: root,
          bookmark: 'bm',
        );
        bookmarks.grants['bm'] = const SourceFolderGrant(
          path: '/var/mobile/Moved',
          stale: false,
        );
        final SourceFolderAccess folderAccess = access(ios: true);
        final SourceScanSummary summary = await SourceLibraryScanner(
          db,
          folderAccess: folderAccess,
        ).scan(row, fs: _RecordingFs(log));

        expect(
          summary.error,
          t.media_source_folder_access_moved(path: '/var/mobile/Moved'),
        );
        expect(bookmarks.stopped, <String>['/var/mobile/Moved']);
        expect(folderAccess.isActive(row.id), isFalse);
      },
    );

    test('/private/var and /var spell the same folder', () {
      expect(
        sameSourceFolderPath('/private/var/mobile/A', '/var/mobile/A/'),
        isTrue,
      );
      expect(
        isPathUnderSourceFolder('/private/var/mobile/A/x.mkv', '/var/mobile/A'),
        isTrue,
      );
      expect(
        isPathUnderSourceFolder('/var/mobile/AB/x.mkv', '/var/mobile/A'),
        isFalse,
      );
    });
  });

  test('non-iOS never touches the native bookmark channel', () async {
    final MediaSourceRow row = await _insertLocal(
      db,
      root: root,
      bookmark: 'path:$root',
    );
    final SourceFolderAccess folderAccess = access(ios: false);
    final SourceScanSummary summary = await SourceLibraryScanner(
      db,
      folderAccess: folderAccess,
    ).scan(row, fs: _RecordingFs(log));
    await folderAccess.release(row.id);

    expect(summary.error, isNull);
    expect(bookmarks.startCount, 0);
    expect(log, <String>['list:$root']);
  });

  group('lifetime holding bookkeeping', () {
    test('concurrent activations start once; release stops once', () async {
      final MediaSourceRow row = await _insertLocal(
        db,
        root: root,
        bookmark: 'path:$root',
      );
      final SourceFolderAccess folderAccess = access(ios: true);
      bookmarks.startGate = Completer<void>();
      final Future<String?> a = folderAccess.ensureSourceAccess(db, row);
      final Future<String?> b = folderAccess.ensureSourceAccess(db, row);
      bookmarks.startGate!.complete();
      expect(await a, isNull);
      expect(await b, isNull);
      expect(await folderAccess.ensureSourceAccess(db, row), isNull);
      expect(bookmarks.startCount, 1);
      expect(folderAccess.isActive(row.id), isTrue);

      await folderAccess.release(row.id);
      await folderAccess.release(row.id);
      expect(bookmarks.stopped, <String>[root]);
      expect(folderAccess.isActive(row.id), isFalse);
    });

    test(
      'startup activation then ensureForPath covers playback paths',
      () async {
        final MediaSourceRow row = await _insertLocal(
          db,
          root: root,
          bookmark: 'path:$root',
          mediaKind: 'video',
        );
        final SourceFolderAccess folderAccess = access(ios: true);
        folderAccess.activateAllOnStartup(db);
        await folderAccess.ensureForPath(p.join(root, 'ep01.mkv'));

        expect(folderAccess.isActive(row.id), isTrue);
        expect(bookmarks.startCount, 1);
      },
    );

    test('ensureForPath activates a source the startup pass missed', () async {
      final SourceFolderAccess folderAccess = access(ios: true);
      folderAccess.activateAllOnStartup(db); // 此刻还没有来源。
      final MediaSourceRow row = await _insertLocal(
        db,
        root: root,
        bookmark: 'path:$root',
        mediaKind: 'video',
      );
      await folderAccess.ensureForPath('$root/sub/ep02.mkv');
      await folderAccess.ensureForPath('/elsewhere/clip.mkv');

      expect(folderAccess.isActive(row.id), isTrue);
      expect(bookmarks.startCount, 1);
    });
  });

  group('registering sources', () {
    test('addLocalFolderAsSource stores the bookmark in configJson', () async {
      final AddLocalFolderResult result = await addLocalFolderAsSource(
        db: db,
        mediaKind: 'book',
        path: tmp.path,
        bookmark: 'Ym9va21hcms=',
      );
      final MediaSourceRow row = (await db.getMediaSourceById(
        result.sourceId!,
      ))!;
      expect(sourceBookmarkFromConfig(row.configJson), 'Ym9va21hcms=');
    });

    test('without a bookmark a local source keeps configJson NULL', () async {
      final AddLocalFolderResult result = await addLocalFolderAsSource(
        db: db,
        mediaKind: 'book',
        path: tmp.path,
      );
      final MediaSourceRow row = (await db.getMediaSourceById(
        result.sourceId!,
      ))!;
      expect(row.configJson, isNull);
    });

    test('one-off import releases the scan-window access afterwards', () async {
      final SourceFolderAccess previous = SourceFolderAccess.instance;
      final SourceFolderAccess folderAccess = access(ios: true);
      SourceFolderAccess.instance = folderAccess;
      addTearDown(() => SourceFolderAccess.instance = previous);

      final SourceScanSummary? summary = await importLocalFolderOnceAt(
        db: db,
        mediaKind: 'book',
        path: tmp.path,
        bookmark: 'path:$root',
      );

      expect(summary?.error, isNull);
      expect(bookmarks.startCount, 1);
      expect(bookmarks.stopped, <String>[root]);
      expect(await db.getAllMediaSources(), isEmpty);
    });
  });
}
