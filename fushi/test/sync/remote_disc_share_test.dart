import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/media/video/disc/remote_disc_actions.dart';
import 'package:fushi/src/media/video/disc/remote_disc_download.dart';
import 'package:fushi/src/media/video/disc/remote_disc_menu_source.dart';
import 'package:fushi/src/sync/remote_disc_share.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:path/path.dart' as p;

// 远端原盘第二期 client 侧：共享会话解析、整盘下载（续传 / 取消 / 校验）、落地认领、
// 按盘分组、流式能力判定与缓冲提示判据。

DiscShareManifest _manifest({
  DiscShareLayout layout = DiscShareLayout.directory,
  DiscFormat format = DiscFormat.bluray,
  List<DiscShareFile>? files,
}) => DiscShareManifest(
  discKey: 'd' * 40,
  name: 'Disc 2',
  format: format,
  layout: layout,
  aacs: false,
  files:
      files ??
      const <DiscShareFile>[
        DiscShareFile(path: 'BDMV/index.bdmv', size: 4, modifiedAt: 0),
        DiscShareFile(path: 'BDMV/PLAYLIST/00001.mpls', size: 3, modifiedAt: 0),
        DiscShareFile(path: 'BDMV/STREAM/00001.m2ts', size: 10, modifiedAt: 0),
      ],
);

Map<String, Object?> _issueBody({
  String baseUrl = 'https://192.168.1.2:8765/api/library/disc/tok/',
  Object? titles,
}) => <String, Object?>{
  'token': 'tok',
  'baseUrl': baseUrl,
  'manifest': _manifest().toJson(),
  'titles':
      titles ??
      <Object?>[
        <String, Object?>{'id': 'host/t1', 'path': 'BDMV/PLAYLIST/00001.mpls'},
      ],
};

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('fushi_remote_disc'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('RemoteDiscShare.fromJson', () {
    test('parses the issue body', () {
      final RemoteDiscShare share = RemoteDiscShare.fromJson(_issueBody())!;
      expect(share.manifest.name, 'Disc 2');
      expect(share.titles.single.id, 'host/t1');
      expect(
        share.nativeDevice,
        'https://192.168.1.2:8765/api/library/disc/tok/',
      );
      expect(
        share.fileUrl('BDMV/STREAM/00001.m2ts').toString(),
        'https://192.168.1.2:8765/api/library/disc/tok/files/BDMV/STREAM/00001.m2ts',
      );
    });

    test('file URLs encode each segment', () {
      final RemoteDiscShare share = RemoteDiscShare.fromJson(_issueBody())!;
      expect(
        share.fileUrl('BDMV/JAR/a b#.jar').path,
        '/api/library/disc/tok/files/BDMV/JAR/a%20b%23.jar',
      );
    });

    test('an image share hands libmpv the image URL', () {
      final RemoteDiscShare share = RemoteDiscShare(
        baseUrl: Uri.parse('http://h:1/api/library/disc/t/'),
        manifest: _manifest(
          layout: DiscShareLayout.image,
          format: DiscFormat.dvd,
          files: const <DiscShareFile>[
            DiscShareFile(path: 'MY DVD.iso', size: 9, modifiedAt: 0),
          ],
        ),
      );
      expect(
        share.nativeDevice,
        'http://h:1/api/library/disc/t/files/MY%20DVD.iso',
      );
    });

    test('rejects bad base URLs and drops unsafe titles', () {
      expect(
        RemoteDiscShare.fromJson(_issueBody(baseUrl: 'file:///x/')),
        isNull,
      );
      expect(
        RemoteDiscShare.fromJson(
          _issueBody(baseUrl: 'http://h:1/api/library/disc/tok'),
        ),
        isNull,
        reason: 'base must end with /',
      );
      final RemoteDiscShare share = RemoteDiscShare.fromJson(
        _issueBody(
          titles: <Object?>[
            <String, Object?>{'id': 'a', 'path': '../../etc/passwd'},
            <String, Object?>{'id': 'b', 'path': 'BDMV/PLAYLIST/00002.mpls'},
          ],
        ),
      )!;
      expect(share.titles.map((RemoteDiscShareTitle t) => t.id), <String>['b']);
    });
  });

  group('downloadRemoteDisc', () {
    final List<int> payload = List<int>.generate(10, (int i) => i);

    Future<void> fetchAll(
      DiscShareFile file,
      File dest, {
      void Function(int received, int? total)? onBytes,
      Future<void>? cancelSignal,
    }) async {
      await dest.writeAsBytes(payload.sublist(0, file.size));
      onBytes?.call(file.size, file.size);
    }

    test('lands every file and reports whole-disc progress', () async {
      final String root = p.join(temp.path, 'Disc 2');
      final List<(int, int)> progress = <(int, int)>[];
      await downloadRemoteDisc(
        manifest: _manifest(),
        localRoot: root,
        fetch: fetchAll,
        onBytes: (int r, int t) => progress.add((r, t)),
      );
      expect(
        File(p.join(root, 'BDMV', 'STREAM', '00001.m2ts')).lengthSync(),
        10,
      );
      expect(File(p.join(root, 'BDMV', 'index.bdmv')).lengthSync(), 4);
      expect(progress.first, (0, 17));
      expect(progress.last, (17, 17));
    });

    test('skips files that already landed complete (resume)', () async {
      final String root = p.join(temp.path, 'Disc 2');
      File(p.join(root, 'BDMV', 'index.bdmv'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<String> fetched = <String>[];
      await downloadRemoteDisc(
        manifest: _manifest(),
        localRoot: root,
        fetch:
            (
              DiscShareFile file,
              File dest, {
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal,
            }) async {
              fetched.add(file.path);
              await fetchAll(file, dest);
            },
      );
      expect(fetched, <String>[
        'BDMV/PLAYLIST/00001.mpls',
        'BDMV/STREAM/00001.m2ts',
      ]);
    });

    test('a short landing is an error, not a finished disc', () async {
      await expectLater(
        downloadRemoteDisc(
          manifest: _manifest(),
          localRoot: p.join(temp.path, 'Disc 2'),
          fetch:
              (
                DiscShareFile file,
                File dest, {
                void Function(int received, int? total)? onBytes,
                Future<void>? cancelSignal,
              }) => dest.writeAsBytes(<int>[1]),
        ),
        throwsStateError,
      );
    });

    test('cancel stops before the next file', () async {
      final Completer<void> cancel = Completer<void>();
      final List<String> fetched = <String>[];
      await expectLater(
        downloadRemoteDisc(
          manifest: _manifest(),
          localRoot: p.join(temp.path, 'Disc 2'),
          cancelSignal: cancel.future,
          fetch:
              (
                DiscShareFile file,
                File dest, {
                void Function(int received, int? total)? onBytes,
                Future<void>? cancelSignal,
              }) async {
                fetched.add(file.path);
                await fetchAll(file, dest);
                cancel.complete();
                await Future<void>.delayed(Duration.zero);
              },
        ),
        throwsA(isA<RemoteDownloadCancelled>()),
      );
      expect(fetched, hasLength(1));
    });

    test('an image lands as one file at the local root', () async {
      final String iso = p.join(temp.path, 'DVD.iso');
      await downloadRemoteDisc(
        manifest: _manifest(
          layout: DiscShareLayout.image,
          format: DiscFormat.dvd,
          files: const <DiscShareFile>[
            DiscShareFile(path: 'DVD.iso', size: 6, modifiedAt: 0),
          ],
        ),
        localRoot: iso,
        fetch: fetchAll,
      );
      expect(File(iso).lengthSync(), 6);
    });

    test('discard removes the tree and the empty disc-key folder', () async {
      final String root = remoteDiscLocalRoot(temp.path, _manifest());
      File(p.join(root, 'BDMV', 'index.bdmv'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      expect(await discardRemoteDiscDownload(root), isTrue);
      expect(Directory(p.dirname(root)).existsSync(), isFalse);
      expect(p.basename(root), 'Disc 2');
    });
  });

  test(
    'registerDownloadedRemoteDisc claims the host rows as local rows',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final String root = p.join(temp.path, 'Disc 2');
      File(p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'))
        ..createSync(recursive: true)
        ..writeAsStringSync('MPLS');
      final RemoteDiscShare share = RemoteDiscShare(
        baseUrl: Uri.parse('http://h:1/api/library/disc/t/'),
        manifest: _manifest(),
        titles: const <RemoteDiscShareTitle>[
          RemoteDiscShareTitle(id: 'host/t1', path: 'BDMV/PLAYLIST/00001.mpls'),
          RemoteDiscShareTitle(id: 'host/t9', path: 'BDMV/PLAYLIST/00009.mpls'),
        ],
      );
      final ({List<String> registered, List<String> missing}) result =
          await registerDownloadedRemoteDisc(
            repo: VideoBookRepository(db),
            adoption: RemoteCollectionAdoptionService(db),
            share: share,
            localRoot: root,
            remoteById: <String, RemoteVideoInfo>{
              'host/t1': const RemoteVideoInfo(
                id: 'host/t1',
                title: 'Main feature',
                importedAt: 42,
                collection: RemoteCollectionMembership(
                  collectionName: 'Box',
                  collectionType: 'playlist',
                  sortIndex: 0,
                ),
              ),
            },
          );
      expect(result.registered, <String>['host/t1']);
      expect(result.missing, <String>['host/t9']);
      final VideoBookRow row = (await db.getVideoBookByBookUid('host/t1'))!;
      expect(row.title, 'Main feature');
      expect(row.videoPath, p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'));
      expect(discRootForMemberPath(row.videoPath), root);
      expect(row.importedAt, 42);
    },
  );

  group('groupRemoteDiscMembers', () {
    RemoteVideoInfo member(String id) =>
        RemoteVideoInfo(id: id, title: id, fileName: '$id.mpls');

    RemoteDiscShare shareFor(String key, List<String> ids) => RemoteDiscShare(
      baseUrl: Uri.parse('http://h:1/api/library/disc/$key/'),
      manifest: DiscShareManifest(
        discKey: key * 40,
        name: 'Disc $key',
        format: DiscFormat.bluray,
        layout: DiscShareLayout.directory,
        aacs: false,
        files: const <DiscShareFile>[
          DiscShareFile(path: 'BDMV/index.bdmv', size: 1, modifiedAt: 0),
        ],
      ),
      titles: <RemoteDiscShareTitle>[
        for (final String id in ids)
          RemoteDiscShareTitle(id: id, path: 'BDMV/PLAYLIST/$id.mpls'),
      ],
    );

    test('one share per disc, failures reported per member', () async {
      final List<String> asked = <String>[];
      final ({List<RemoteDiscShare> shares, List<RemoteVideoInfo> failed})
      grouped = await groupRemoteDiscMembers(
        <RemoteVideoInfo>[
          member('a1'),
          member('a2'),
          member('b1'),
          member('x'),
        ],
        (String id) async {
          asked.add(id);
          if (id == 'x') throw const SocketException('gone');
          return id.startsWith('a')
              ? shareFor('a', <String>['a1', 'a2'])
              : shareFor('b', <String>['b1']);
        },
      );
      expect(asked, <String>['a1', 'b1', 'x'], reason: '同盘的 a2 不再问');
      expect(
        grouped.shares.map((RemoteDiscShare s) => s.manifest.name),
        <String>['Disc a', 'Disc b'],
      );
      expect(grouped.failed.single.id, 'x');
    });

    test('an old host aborts the whole grouping', () async {
      await expectLater(
        groupRemoteDiscMembers(<RemoteVideoInfo>[
          member('a1'),
        ], (String _) async => throw const RemoteDiscShareUnsupported()),
        throwsA(isA<RemoteDiscShareUnsupported>()),
      );
    });
  });

  group('stream capability', () {
    test('remote rule: host, folder DVD, then the BD-J rules', () {
      DiscMenuUnavailableReason? rule({
        bool shareSupported = true,
        bool dvdFolder = false,
        bool requiresJava = false,
        DiscMenuPlatform platform = DiscMenuPlatform.windows,
      }) => resolveRemoteDiscMenuAvailability(
        shareSupported: shareSupported,
        dvdFolder: dvdFolder,
        requiresJava: requiresJava,
        platform: platform,
        bdjComponentInstallable: true,
      );
      expect(rule(), isNull);
      expect(
        rule(shareSupported: false),
        DiscMenuUnavailableReason.remoteHostTooOld,
      );
      expect(rule(dvdFolder: true), DiscMenuUnavailableReason.remoteDvdFolder);
      expect(
        rule(requiresJava: true, platform: DiscMenuPlatform.android),
        DiscMenuUnavailableReason.mobileBdj,
      );
    });

    test('probe maps share failures to exact reasons', () async {
      Future<RemoteDiscProbe> probe(
        Future<RemoteDiscShare> Function(String) open,
      ) => probeRemoteDiscMenu(
        actions: RemoteDiscActions(
          openShare: open,
          readFile: (RemoteDiscShare _, String _, int _) async => null,
        ),
        videoId: 'v',
        title: 'Box',
        platform: DiscMenuPlatform.windows,
        bdjComponentInstallable: true,
      );
      expect(
        (await probe(
          (String _) async => throw const RemoteDiscShareUnsupported(),
        )).unavailable,
        DiscMenuUnavailableReason.remoteHostTooOld,
      );
      expect(
        (await probe(
          (String _) async => throw const SocketException('x'),
        )).unavailable,
        DiscMenuUnavailableReason.remoteUnreachable,
      );
      final RemoteDiscProbe ok = await probe(
        (String _) async => RemoteDiscShare.fromJson(_issueBody())!,
      );
      expect(ok.unavailable, isNull);
      expect(ok.source!.title, 'Box');
      expect(ok.source!.identityRoot, contains('d' * 40));
    });

    test('remote BD index is read from the share (BACKUP fallback)', () async {
      final List<String> read = <String>[];
      final RemoteDiscMenuSource source = RemoteDiscMenuSource(
        share: RemoteDiscShare(
          baseUrl: Uri.parse('http://h:1/api/library/disc/t/'),
          manifest: _manifest(
            files: const <DiscShareFile>[
              DiscShareFile(path: 'BDMV/index.bdmv', size: 4, modifiedAt: 0),
              DiscShareFile(
                path: 'BDMV/BACKUP/index.bdmv',
                size: 4,
                modifiedAt: 0,
              ),
            ],
          ),
        ),
        title: 'Disc',
        readFile: (String path, int _) async {
          read.add(path);
          return Uint8List(4); // too short: not a valid index
        },
      );
      expect(await source.readMenuInfo(), isNull);
      expect(read, <String>['BDMV/index.bdmv', 'BDMV/BACKUP/index.bdmv']);
    });
  });

  test('buffering monitor: three stalls after playback within the window', () {
    final RemoteDiscBufferingMonitor monitor = RemoteDiscBufferingMonitor();
    DateTime at(int s) => DateTime(2026, 10, 24).add(Duration(seconds: s));
    // Opening buffer before anything played does not count.
    expect(monitor.update(buffering: true, now: at(0)), isFalse);
    expect(monitor.update(buffering: false, now: at(2)), isFalse);
    expect(monitor.update(buffering: true, now: at(10)), isFalse);
    expect(monitor.update(buffering: false, now: at(11)), isFalse);
    expect(monitor.update(buffering: true, now: at(200)), isFalse);
    expect(monitor.update(buffering: false, now: at(201)), isFalse);
    // 10 s stall fell out of the 2-minute window.
    expect(monitor.update(buffering: true, now: at(250)), isFalse);
    expect(monitor.update(buffering: false, now: at(251)), isFalse);
    expect(monitor.update(buffering: true, now: at(260)), isTrue);
    expect(monitor.update(buffering: false, now: at(261)), isFalse);
    expect(
      monitor.update(buffering: true, now: at(262)),
      isFalse,
      reason: 'once per session',
    );
  });

  test('member file names that are disc titles', () {
    expect(isRemoteDiscMemberFileName('00800.MPLS'), isTrue);
    expect(isRemoteDiscMemberFileName('TITLE_01.dvdtitle'), isTrue);
    expect(isRemoteDiscMemberFileName('ep01.mkv'), isFalse);
    expect(isRemoteDiscMemberFileName(null), isFalse);
  });
}
