import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_root_migration.dart';
import 'package:hibiki/src/sync/sync_utils.dart';

/// Fushi 改名迁移（hibiki-data → fushi-data）：五 backend 共用的三段骨架
/// [migrateLegacySyncRoot]、host 侧本地目录迁移 [migrateLegacySyncRootDirectory]、
/// 以及陈旧持久化缓存过滤（[syncFolderIdEmbedsLegacyRoot] +
/// [SyncFolderCache.restoreCache]——不过滤的话根缓存命中会永远短路掉迁移）。
void main() {
  group('migrateLegacySyncRoot', () {
    test('新根已存在 → 直接返回，不探测旧根、不改名', () async {
      final List<String> probed = <String>[];
      bool renamed = false;

      final String? result = await migrateLegacySyncRoot<String>(
        find: (String name) async {
          probed.add(name);
          return name == kSyncRootFolderName ? 'new-root-id' : null;
        },
        renameLegacy: (String legacy) async {
          renamed = true;
          return legacy;
        },
        onRenameError: (Object e, StackTrace st) =>
            fail('unexpected rename error: $e'),
      );

      expect(result, 'new-root-id');
      expect(probed, <String>[kSyncRootFolderName]);
      expect(renamed, isFalse);
    });

    test('新根不存在、旧根存在 → 改名并返回改名后定位符', () async {
      final List<String> probed = <String>[];
      String? renamedFrom;

      final String? result = await migrateLegacySyncRoot<String>(
        find: (String name) async {
          probed.add(name);
          return name == kLegacySyncRootFolderName ? '/hibiki-data' : null;
        },
        renameLegacy: (String legacy) async {
          renamedFrom = legacy;
          return '/fushi-data';
        },
        onRenameError: (Object e, StackTrace st) =>
            fail('unexpected rename error: $e'),
      );

      expect(result, '/fushi-data');
      expect(renamedFrom, '/hibiki-data');
      expect(probed, <String>[kSyncRootFolderName, kLegacySyncRootFolderName]);
    });

    test('都不存在 → 返回 null（调用方新建），不改名', () async {
      bool renamed = false;

      final String? result = await migrateLegacySyncRoot<String>(
        find: (String name) async => null,
        renameLegacy: (String legacy) async {
          renamed = true;
          return legacy;
        },
        onRenameError: (Object e, StackTrace st) =>
            fail('unexpected rename error: $e'),
      );

      expect(result, isNull);
      expect(renamed, isFalse);
    });

    test('改名失败 → 留痕降级返回 null（按无旧根继续）', () async {
      Object? logged;

      final String? result = await migrateLegacySyncRoot<String>(
        find: (String name) async =>
            name == kLegacySyncRootFolderName ? '/hibiki-data' : null,
        renameLegacy: (String legacy) async =>
            throw StateError('rename refused'),
        onRenameError: (Object e, StackTrace st) => logged = e,
      );

      expect(result, isNull);
      expect(logged, isA<StateError>());
    });

    test('find 的异常原样上抛（同步失败不属于迁移降级范围）', () async {
      expect(
        () => migrateLegacySyncRoot<String>(
          find: (String name) async => throw const SocketException('down'),
          renameLegacy: (String legacy) async => legacy,
          onRenameError: (Object e, StackTrace st) =>
              fail('must not be called'),
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('migrateLegacySyncRootDirectory (host 本地磁盘)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_root_migration_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String child(String name) => '${tmp.path}${Platform.pathSeparator}$name';

    test('旧目录存在、新目录不存在 → 整目录改名，内容原地保留', () async {
      final Directory legacy = Directory(child(kLegacySyncRootFolderName))
        ..createSync();
      File('${legacy.path}${Platform.pathSeparator}progress_1.json')
          .writeAsStringSync('{"p":1}');

      await migrateLegacySyncRootDirectory(
        syncDataDir: tmp.path,
        onError: (Object e, StackTrace st) => fail('unexpected error: $e'),
      );

      expect(legacy.existsSync(), isFalse);
      final Directory renamed = Directory(child(kSyncRootFolderName));
      expect(renamed.existsSync(), isTrue);
      expect(
        File('${renamed.path}${Platform.pathSeparator}progress_1.json')
            .readAsStringSync(),
        '{"p":1}',
      );
    });

    test('新目录已存在 → 幂等跳过，旧目录不动', () async {
      Directory(child(kSyncRootFolderName)).createSync();
      final Directory legacy = Directory(child(kLegacySyncRootFolderName))
        ..createSync();

      await migrateLegacySyncRootDirectory(
        syncDataDir: tmp.path,
        onError: (Object e, StackTrace st) => fail('unexpected error: $e'),
      );

      expect(legacy.existsSync(), isTrue);
      expect(Directory(child(kSyncRootFolderName)).existsSync(), isTrue);
    });

    test('两者都不存在 → 无操作、不报错', () async {
      await migrateLegacySyncRootDirectory(
        syncDataDir: tmp.path,
        onError: (Object e, StackTrace st) => fail('unexpected error: $e'),
      );

      expect(Directory(child(kSyncRootFolderName)).existsSync(), isFalse);
      expect(Directory(child(kLegacySyncRootFolderName)).existsSync(), isFalse);
    });

    test('rename 失败（新名被同名文件占位）→ onError 留痕，不抛出', () async {
      // Directory.exists 对文件路径返回 false，于是走 rename；把目录 rename 到
      // 已有同名文件上在各平台都失败 → 走 onError 降级路径。
      File(child(kSyncRootFolderName)).writeAsStringSync('occupied');
      Directory(child(kLegacySyncRootFolderName)).createSync();

      Object? logged;
      await migrateLegacySyncRootDirectory(
        syncDataDir: tmp.path,
        onError: (Object e, StackTrace st) => logged = e,
      );

      expect(logged, isNotNull);
      // 降级语义：旧目录原地保留，数据没丢。
      expect(Directory(child(kLegacySyncRootFolderName)).existsSync(), isTrue);
    });
  });

  group('syncFolderIdEmbedsLegacyRoot（陈旧缓存判据）', () {
    test('按路径段命中各后端形态的旧根路径', () {
      // Dropbox / WebDAV / FTP / SFTP / 互联 的持久化 folderId 形态。
      expect(syncFolderIdEmbedsLegacyRoot('/hibiki-data'), isTrue);
      expect(syncFolderIdEmbedsLegacyRoot('/hibiki-data/BookTitle'), isTrue);
      expect(
        syncFolderIdEmbedsLegacyRoot('https://h:8080/dav/hibiki-data/'),
        isTrue,
      );
      expect(syncFolderIdEmbedsLegacyRoot('/home/u/hibiki-data'), isTrue);
      expect(syncFolderIdEmbedsLegacyRoot('hibiki-data'), isTrue);
      expect(syncFolderIdEmbedsLegacyRoot('hibiki-data/Title'), isTrue);
    });

    test('段边界：子串同形的书名/新根路径不误杀', () {
      expect(syncFolderIdEmbedsLegacyRoot('/fushi-data/Title'), isFalse);
      expect(
          syncFolderIdEmbedsLegacyRoot('/fushi-data/hibiki-database'), isFalse);
      expect(syncFolderIdEmbedsLegacyRoot('my-hibiki-data'), isFalse);
      // Google Drive 不透明 ID（无斜杠、非整串旧根名）不受影响。
      expect(syncFolderIdEmbedsLegacyRoot('1AbC_hibiki-dataXyZ'), isFalse);
    });
  });

  group('SyncFolderCache.restoreCache 过滤陈旧旧根缓存', () {
    test('嵌旧根名的 root/书条目被丢弃，干净条目保留', () {
      final _CacheHost host = _CacheHost();
      host.restoreCache(
        rootFolderId: '/hibiki-data',
        titleToFolderId: <String, String>{
          'Old Book': '/hibiki-data/Old Book',
          'New Book': '/fushi-data/New Book',
        },
      );

      // 陈旧 root 被丢弃 → findOrCreateRootFolder 会真正跑（迁移得以发生）。
      expect(host.cachedRootFolderId, isNull);
      expect(host.cachedFolderIds, <String, String>{
        'New Book': '/fushi-data/New Book',
      });
    });

    test('不透明 ID（Google Drive 形态）原样保留', () {
      final _CacheHost host = _CacheHost();
      host.restoreCache(
        rootFolderId: '1OpaqueDriveId',
        titleToFolderId: <String, String>{'Book': '1AnotherOpaqueId'},
      );

      expect(host.cachedRootFolderId, '1OpaqueDriveId');
      expect(
          host.cachedFolderIds, <String, String>{'Book': '1AnotherOpaqueId'});
    });
  });
}

class _CacheHost with SyncFolderCache {}
