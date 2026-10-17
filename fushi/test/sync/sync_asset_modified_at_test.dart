import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/ftp_sync_backend.dart';
import 'package:fushi/src/sync/google_drive_handler.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 各同步后端把「服务端修改时间」映射进 [AssetEntry.modifiedAt]（UTC 毫秒）。
///
/// SRS 同步拿它当服务器时间（写探针文件再读回），时区或字段取错 = 多设备排程时间轴错位，
/// 所以每个后端都用带真实形状的响应断言：取对字段、换算成 UTC、拿不到就为 null。
void main() {
  // 2026-10-14T08:15:30.123Z
  final int t = DateTime.utc(
    2026,
    10,
    14,
    8,
    15,
    30,
    123,
  ).millisecondsSinceEpoch;
  final int tSec = DateTime.utc(2026, 10, 14, 8, 15, 30).millisecondsSinceEpoch;

  group('syncIsoTimestampMs', () {
    test('Z / 偏移量都换成同一个 UTC 时刻', () {
      expect(syncIsoTimestampMs('2026-10-14T08:15:30.123Z'), t);
      expect(syncIsoTimestampMs('2026-10-14T17:15:30.123+09:00'), t);
      expect(syncIsoTimestampMs('2026-10-14T08:15:30Z'), tSec);
    });

    test('不带时区（会按本机时区解释）与非字符串一律 null', () {
      expect(syncIsoTimestampMs('2026-10-14T08:15:30'), isNull);
      expect(syncIsoTimestampMs(null), isNull);
      expect(syncIsoTimestampMs(12), isNull);
      expect(syncIsoTimestampMs('garbage'), isNull);
    });
  });

  group('Google Drive', () {
    tearDown(() => GoogleDriveHandler.instance.clearCache());

    test('files.list 请求 modifiedTime，并映射为 UTC 毫秒', () async {
      final List<Uri> requests = <Uri>[];
      final MockClient client = MockClient((http.Request req) async {
        requests.add(req.url);
        return http.Response(
          jsonEncode(<String, Object?>{
            'files': <Object?>[
              <String, Object?>{
                'id': 'f1',
                'name': 'probe',
                'mimeType': 'application/octet-stream',
                'size': '1',
                'modifiedTime': '2026-10-14T08:15:30.123Z',
              },
              <String, Object?>{
                'id': 'd1',
                'name': 'writer',
                'mimeType': 'application/vnd.google-apps.folder',
                'modifiedTime': '2026-10-14T08:15:30.123Z',
              },
              <String, Object?>{
                'id': 'f2',
                'name': 'no-time',
                'mimeType': 'application/octet-stream',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      GoogleDriveHandler.instance.debugUseDriveApi(drive.DriveApi(client));

      final List<AssetEntry> entries = await GoogleDriveHandler.instance
          .listChildrenRaw('parent');

      expect(requests, hasLength(1));
      expect(
        requests.single.queryParameters['fields'],
        contains('modifiedTime'),
      );
      expect(entries.map((AssetEntry e) => e.name), <String>[
        'probe',
        'writer',
        'no-time',
      ]);
      expect(entries[0].modifiedAt, t);
      expect(entries[0].sizeBytes, 1);
      expect(entries[1].isFolder, isTrue);
      expect(entries[2].modifiedAt, isNull);
    });
  });

  group('OneDrive', () {
    test('取顶层 lastModifiedDateTime，不取客户端自报的 fileSystemInfo', () {
      final AssetEntry e = oneDriveItemToAssetEntry(<String, dynamic>{
        'id': 'ABC!123',
        'name': 'probe',
        'size': 1,
        'lastModifiedDateTime': '2026-10-14T08:15:30.123Z',
        'fileSystemInfo': <String, dynamic>{
          'lastModifiedDateTime': '1999-01-01T00:00:00Z',
        },
        'file': <String, dynamic>{'mimeType': 'application/octet-stream'},
      });
      expect(e.id, 'ABC!123');
      expect(e.isFolder, isFalse);
      expect(e.sizeBytes, 1);
      expect(e.modifiedAt, t);
    });

    test('文件夹条目照常映射；缺字段为 null', () {
      final AssetEntry e = oneDriveItemToAssetEntry(<String, dynamic>{
        'id': 'F!1',
        'name': 'writer',
        'folder': <String, dynamic>{'childCount': 0},
      });
      expect(e.isFolder, isTrue);
      expect(e.modifiedAt, isNull);
    });
  });

  group('Dropbox', () {
    test('取 server_modified（不取 client_modified）', () {
      final AssetEntry e = dropboxEntryToAssetEntry(<String, dynamic>{
        '.tag': 'file',
        'name': 'probe',
        'path_lower': '/fushi-data/fushi-srs/p/w/probe',
        'path_display': '/fushi-data/fushi-srs/p/w/probe',
        'size': 1,
        'client_modified': '1999-01-01T00:00:00Z',
        'server_modified': '2026-10-14T08:15:30Z',
      });
      expect(e.id, '/fushi-data/fushi-srs/p/w/probe');
      expect(e.sizeBytes, 1);
      expect(e.modifiedAt, tSec);
    });

    test('文件夹条目没有修改时间', () {
      final AssetEntry e = dropboxEntryToAssetEntry(<String, dynamic>{
        '.tag': 'folder',
        'name': 'w',
        'path_lower': '/fushi-data/fushi-srs/p/w',
      });
      expect(e.isFolder, isTrue);
      expect(e.modifiedAt, isNull);
      expect(e.sizeBytes, isNull);
    });
  });

  group('WebDAV', () {
    test('PROPFIND 请求体要 getlastmodified', () {
      expect(WebDavOps.propfindBody, contains('<d:getlastmodified/>'));
    });

    test('解析 RFC 1123 getlastmodified（含带属性的写法）为 UTC 毫秒', () {
      final WebDavOps ops = WebDavOps(
        baseUrl: 'https://dav.example',
        username: 'u',
        password: 'p',
      );
      const String xml =
          '<?xml version="1.0"?>'
          '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/dav/w/</D:href><D:propstat><D:prop>'
          '<D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/w/probe</D:href><D:propstat><D:prop>'
          '<D:resourcetype/>'
          '<D:getlastmodified>Wed, 14 Oct 2026 08:15:30 GMT</D:getlastmodified>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/w/iis</D:href><D:propstat><D:prop>'
          '<D:getlastmodified xmlns:b="urn:uuid:c2f41010-65b3-11d1-a29f-00aa00c14882/" '
          'b:dt="dateTime.rfc1123">Wed, 14 Oct 2026 08:15:30 GMT</D:getlastmodified>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/w/bad</D:href><D:propstat><D:prop>'
          '<D:getlastmodified>not a date</D:getlastmodified>'
          '</D:prop></D:propstat></D:response>'
          '</D:multistatus>';
      final List<DavEntry> entries = ops.parsePropfindResponse(
        xml,
        'https://dav.example/dav/w/',
      );
      final Map<String, DavEntry> byName = <String, DavEntry>{
        for (final DavEntry e in entries) e.displayName: e,
      };
      expect(byName['w']!.modifiedAt, isNull);
      expect(byName['probe']!.modifiedAt, tSec);
      expect(byName['iis']!.modifiedAt, tSec);
      expect(byName['bad']!.modifiedAt, isNull);
    });

    test('parseDavLastModified 接受 RFC 850 / asctime 旧格式', () {
      expect(parseDavLastModified('Wednesday, 14-Oct-26 08:15:30 GMT'), tSec);
      expect(parseDavLastModified('Wed Oct 14 08:15:30 2026'), tSec);
      expect(parseDavLastModified(''), isNull);
      expect(parseDavLastModified(null), isNull);
    });
  });

  group('互联（FushiSyncServer 的 WebDAV）', () {
    late Directory tempDir;
    late FushiSyncServer server;
    late String token;
    late File probe;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fushi_mtime_server_');
      final Directory dir = Directory(
        '${tempDir.path}/sync-data/$kSyncRootFolderName/fushi-srs/w',
      );
      await dir.create(recursive: true);
      probe = File('${dir.path}/probe');
      await probe.writeAsBytes(<int>[1]);
      token = FushiSyncServer.generateToken();
      server = FushiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: true,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await tempDir.delete(recursive: true);
    });

    test('PROPFIND 带回文件在 host 上的修改时间（秒级），目录为 null', () async {
      final String base = 'http://localhost:${server.port}';
      final WebDavOps ops = WebDavOps(
        baseUrl: base,
        username: 'hibiki',
        password: token,
      );
      try {
        final List<DavEntry> children = await ops.propfindChildren(
          '$base/$kSyncRootFolderName/fushi-srs/',
        );
        final DavEntry w = children.firstWhere(
          (DavEntry e) => e.displayName == 'w',
        );
        expect(w.isCollection, isTrue);
        expect(w.modifiedAt, isNull);

        final List<DavEntry> files = await ops.propfindChildren(
          '$base/$kSyncRootFolderName/fushi-srs/w/',
        );
        final DavEntry p = files.firstWhere(
          (DavEntry e) => e.displayName == 'probe',
        );
        final int expected =
            (await probe.stat()).modified.toUtc().millisecondsSinceEpoch ~/
            1000 *
            1000;
        expect(p.modifiedAt, expected);
      } finally {
        ops.close(force: true);
      }
    });
  });

  group('FTP MDTM', () {
    test('RFC 3659 应答（UTC）换成毫秒；可带小数秒与 213 前缀', () {
      expect(ftpMdtmReplyToMs('213 20261014081530'), tSec);
      expect(ftpMdtmReplyToMs('20261014081530'), tSec);
      expect(ftpMdtmReplyToMs('213 20261014081530.123'), t);
      expect(ftpMdtmReplyToMs('213 20261014081530.1'), tSec + 100);
      expect(ftpMdtmReplyToMs('213 20261014081530.123456'), t);
    });

    test('格式不符或日期越界返回 null', () {
      expect(ftpMdtmReplyToMs('550 probe: No such file'), isNull);
      expect(ftpMdtmReplyToMs('213 2026101408153'), isNull);
      expect(ftpMdtmReplyToMs('213 20261332081530'), isNull);
      expect(ftpMdtmReplyToMs('213 20261014256030'), isNull);
    });
  });

  group('SFTP', () {
    test('ATTRS.mtime 秒 → 毫秒；缺省为 null', () {
      expect(sftpMtimeToMs(tSec ~/ 1000), tSec);
      expect(sftpMtimeToMs(null), isNull);
    });
  });
}
