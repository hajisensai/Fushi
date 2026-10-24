import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/sync/disc_share_routes.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

import '../dvd_fixture.dart';
import '../dvd_iso_fixture.dart';

/// 一张蓝光目录盘：index + 一条 MPLS + 一段码流 + CERTIFICATE；[aacs] 时带 AACS/。
Directory _writeBluray(Directory parent, {bool aacs = false}) {
  final Directory root = Directory(p.join(parent.path, 'Disc 2'))
    ..createSync(recursive: true);
  void put(String relative, List<int> bytes) {
    final File file = File(
      p.joinAll(<String>[root.path, ...relative.split('/')]),
    )..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  put('BDMV/index.bdmv', utf8.encode('INDX0200') + List<int>.filled(24, 0));
  put('BDMV/MovieObject.bdmv', utf8.encode('MOBJ0200'));
  put('BDMV/PLAYLIST/00000.mpls', utf8.encode('MPLS0200'));
  put('BDMV/CLIPINF/00000.clpi', utf8.encode('HDMV0200'));
  put('BDMV/STREAM/00000.m2ts', List<int>.generate(6144, (int i) => i & 0xff));
  put('CERTIFICATE/id.bdmv', utf8.encode('BDID0200'));
  if (aacs) put('AACS/Unit_Key_RO.inf', List<int>.filled(64, 7));
  return root;
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('fushi_disc_share'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('buildDiscShareManifest', () {
    test('明文蓝光副本：BDMV + CERTIFICATE，AACS/ 不下发', () async {
      final Directory root = _writeBluray(temp, aacs: true);
      final DiscShareManifest? manifest = await buildDiscShareManifest(
        root.path,
        isEncryptedStream: (_) async => false,
      );
      expect(manifest, isNotNull);
      expect(manifest!.format, DiscFormat.bluray);
      expect(manifest.layout, DiscShareLayout.directory);
      expect(manifest.name, 'Disc 2');
      expect(manifest.aacs, isFalse);
      expect(manifest.files.map((DiscShareFile f) => f.path), <String>[
        'BDMV/CLIPINF/00000.clpi',
        'BDMV/MovieObject.bdmv',
        'BDMV/PLAYLIST/00000.mpls',
        'BDMV/STREAM/00000.m2ts',
        'BDMV/index.bdmv',
        'CERTIFICATE/id.bdmv',
      ]);
      expect(manifest.fileAt('BDMV/STREAM/00000.m2ts')!.size, 6144);
      expect(manifest.discKey, discShareKeyForRoot(root.path));
    });

    test('仍有密文码流：带上 AACS/ 并标 aacs', () async {
      final Directory root = _writeBluray(temp, aacs: true);
      final List<String> probed = <String>[];
      final DiscShareManifest? manifest = await buildDiscShareManifest(
        root.path,
        isEncryptedStream: (String path) async {
          probed.add(p.basename(path));
          return true;
        },
      );
      expect(probed, <String>['00000.m2ts']);
      expect(manifest!.aacs, isTrue);
      expect(manifest.fileAt('AACS/Unit_Key_RO.inf'), isNotNull);
    });

    test('UHD：index.bdmv 头为 INDX0300', () async {
      final Directory root = _writeBluray(temp);
      File(
        p.join(root.path, 'BDMV', 'index.bdmv'),
      ).writeAsBytesSync(utf8.encode('INDX0300') + List<int>.filled(24, 0));
      final DiscShareManifest? manifest = await buildDiscShareManifest(
        root.path,
        isEncryptedStream: (_) async => false,
      );
      expect(manifest!.format, DiscFormat.uhdBluray);
    });

    test('DVD 目录：只收 VIDEO_TS/', () async {
      final String root = p.join(temp.path, 'MOVIE_DVD');
      writeTvDvdFixture(root);
      File(p.join(root, 'notes.txt')).writeAsStringSync('not part of the disc');
      final DiscShareManifest? manifest = await buildDiscShareManifest(root);
      expect(manifest!.format, DiscFormat.dvd);
      expect(manifest.layout, DiscShareLayout.directory);
      expect(
        manifest.files.every(
          (DiscShareFile f) => f.path.startsWith('VIDEO_TS/'),
        ),
        isTrue,
      );
      expect(manifest.fileAt('VIDEO_TS/VIDEO_TS.IFO'), isNotNull);
    });

    test('DVD 镜像：单个文件', () async {
      final String folder = p.join(temp.path, 'folder');
      writeTvDvdFixture(folder);
      final String iso = p.join(temp.path, 'SHOW.iso');
      writeIsoFromFolderDisc(folder, iso);
      final DiscShareManifest? manifest = await buildDiscShareManifest(iso);
      expect(manifest!.layout, DiscShareLayout.image);
      expect(manifest.format, DiscFormat.dvd);
      expect(manifest.files.single.path, 'SHOW.iso');
      expect(manifest.files.single.size, File(iso).lengthSync());
    });

    test('不是盘：null', () async {
      expect(await buildDiscShareManifest(temp.path), isNull);
    });
  });

  group('DiscShareManifest 序列化', () {
    test('往返一致', () async {
      final Directory root = _writeBluray(temp);
      final DiscShareManifest manifest = (await buildDiscShareManifest(
        root.path,
        isEncryptedStream: (_) async => false,
      ))!;
      final DiscShareManifest? back = DiscShareManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())),
      );
      expect(back, isNotNull);
      expect(back!.toJson(), manifest.toJson());
      expect(back.totalBytes, manifest.totalBytes);
    });

    Map<String, Object?> withFile(String path) => <String, Object?>{
      'version': kDiscShareManifestVersion,
      'discKey': 'a' * 40,
      'name': 'Disc 1',
      'format': 'bluray',
      'layout': 'directory',
      'aacs': false,
      'files': <Object?>[
        <String, Object?>{'path': path, 'size': 1, 'modifiedAt': 0},
      ],
    };

    test('不安全路径整份拒收', () {
      for (final String bad in <String>[
        '../etc/passwd',
        'BDMV/../../x',
        '/abs/path',
        r'BDMV\STREAM\00000.m2ts',
        'C:/Windows/x',
        'BDMV//x',
        'BDMV/./x',
        'BDMV/con?.bdmv',
      ]) {
        expect(DiscShareManifest.fromJson(withFile(bad)), isNull, reason: bad);
      }
      expect(
        DiscShareManifest.fromJson(withFile('BDMV/index.bdmv')),
        isNotNull,
      );
    });

    test('未知版本 / 重复路径拒收', () {
      expect(
        DiscShareManifest.fromJson(<String, Object?>{
          ...withFile('BDMV/index.bdmv'),
          'version': kDiscShareManifestVersion + 1,
        }),
        isNull,
      );
      expect(
        DiscShareManifest.fromJson(<String, Object?>{
          ...withFile('BDMV/index.bdmv'),
          'files': <Object?>[
            <String, Object?>{'path': 'BDMV/a', 'size': 1, 'modifiedAt': 0},
            <String, Object?>{'path': 'bdmv/A', 'size': 1, 'modifiedAt': 0},
          ],
        }),
        isNull,
      );
    });

    test('resolveDiscShareFilePath 只认清单内路径', () async {
      final Directory root = _writeBluray(temp);
      final DiscShareManifest manifest = (await buildDiscShareManifest(
        root.path,
        isEncryptedStream: (_) async => false,
      ))!;
      expect(
        resolveDiscShareFilePath(root.path, manifest, 'BDMV/index.bdmv'),
        p.join(root.path, 'BDMV', 'index.bdmv'),
      );
      expect(resolveDiscShareFilePath(root.path, manifest, 'BDMV'), isNull);
      expect(
        resolveDiscShareFilePath(
          root.path,
          manifest,
          '../Disc 2/BDMV/index.bdmv',
        ),
        isNull,
      );
    });
  });

  group('DiscShareTokenStore', () {
    test('读盘续期，空闲超时作废', () {
      DateTime now = DateTime(2026, 10, 24, 12);
      final DiscShareTokenStore store = DiscShareTokenStore(now: () => now);
      final DiscShareManifest manifest = _manifest();
      final String token = store.issue(discRoot: '/disc', manifest: manifest);
      now = now.add(const Duration(minutes: 29));
      expect(store.touch(token), isNotNull);
      now = now.add(const Duration(minutes: 29));
      expect(store.touch(token), isNotNull, reason: '上一次读已续期');
      now = now.add(const Duration(minutes: 31));
      expect(store.touch(token), isNull);
    });

    test('签发起超过 maxAge 无论是否在读都作废', () {
      DateTime now = DateTime(2026, 10, 24, 12);
      final DiscShareTokenStore store = DiscShareTokenStore(now: () => now);
      final String token = store.issue(
        discRoot: '/disc',
        manifest: _manifest(),
      );
      for (int i = 0; i < 25; i++) {
        now = now.add(const Duration(minutes: 29));
        store.touch(token);
      }
      expect(store.touch(token), isNull);
    });

    test('满了淘汰最久没用的', () {
      DateTime now = DateTime(2026, 10, 24, 12);
      final DiscShareTokenStore store = DiscShareTokenStore(
        now: () => now,
        capacity: 2,
      );
      final String a = store.issue(discRoot: '/a', manifest: _manifest());
      now = now.add(const Duration(seconds: 1));
      final String b = store.issue(discRoot: '/b', manifest: _manifest());
      now = now.add(const Duration(seconds: 1));
      store.touch(a);
      store.issue(discRoot: '/c', manifest: _manifest());
      expect(store.length, 2);
      expect(store.touch(a), isNotNull);
      expect(store.touch(b), isNull);
    });
  });

  group('handleDiscShareRequest', () {
    late Directory root;
    late DiscShareTokenStore store;
    late String token;

    setUp(() async {
      root = _writeBluray(temp);
      store = DiscShareTokenStore();
      token = store.issue(
        discRoot: root.path,
        manifest: (await buildDiscShareManifest(
          root.path,
          isEncryptedStream: (_) async => false,
        ))!,
      );
    });

    Future<shelf.Response> get(String path, {Map<String, String>? headers}) {
      final shelf.Request request = shelf.Request(
        'GET',
        Uri.parse('http://127.0.0.1/${path.substring(1)}'),
        headers: headers,
      );
      return handleDiscShareRequest(store, request, 'GET', path);
    }

    test('清单', () async {
      final shelf.Response res = await get(
        '/api/library/disc/$token/manifest.json',
      );
      expect(res.statusCode, 200);
      final DiscShareManifest? back = DiscShareManifest.fromJson(
        jsonDecode(await res.readAsString()),
      );
      expect(back!.fileAt('BDMV/index.bdmv'), isNotNull);
    });

    test('文件 Range → 206', () async {
      final shelf.Response res = await get(
        '/api/library/disc/$token/files/BDMV/STREAM/00000.m2ts',
        headers: <String, String>{'range': 'bytes=10-19'},
      );
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], 'bytes 10-19/6144');
      final List<int> body = await res
          .read()
          .expand((List<int> c) => c)
          .toList();
      expect(body, List<int>.generate(10, (int i) => 10 + i));
      expect(res.headers['etag'], startsWith('"disc-6144-'));
    });

    test('清单外 / 穿越 / 坏 token', () async {
      expect(
        (await get('/api/library/disc/$token/files/BDMV')).statusCode,
        404,
      );
      expect(
        (await get(
          '/api/library/disc/$token/files/../Disc 2/BDMV/index.bdmv',
        )).statusCode,
        404,
      );
      expect(
        (await get('/api/library/disc/nope/files/BDMV/index.bdmv')).statusCode,
        401,
      );
      expect((await get('/api/library/disc/$token/other')).statusCode, 404);
    });

    test('签发体：baseUrl 与请求同源、以 / 结尾', () {
      final Map<String, Object?> body = discShareIssueBody(
        token: 'tok',
        requestedUri: Uri.parse('https://[::1]:8765/api/library/videos/x/disc'),
        manifest: _manifest(),
      );
      expect(body['baseUrl'], 'https://[::1]:8765/api/library/disc/tok/');
      expect(
        isDiscShareSessionPath('api/library/disc/tok/manifest.json'),
        isTrue,
      );
      expect(isDiscShareSessionPath('api/library/videos/x/disc'), isFalse);
    });
  });
}

DiscShareManifest _manifest() => DiscShareManifest(
  discKey: 'b' * 40,
  name: 'Disc',
  format: DiscFormat.bluray,
  layout: DiscShareLayout.directory,
  aacs: false,
  files: <DiscShareFile>[
    const DiscShareFile(path: 'BDMV/index.bdmv', size: 1, modifiedAt: 0),
  ],
);
