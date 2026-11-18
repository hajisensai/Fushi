import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:test/test.dart';
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
import 'package:fushi_engine/media/video/bluray/bluray_menu_info.dart';
import 'package:path/path.dart' as p;

import '../media/video/bluray_menu_info_test.dart' show indexFixture;

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

    test('remote BD index is read once per source: the page and the controller '
        'share one read; an unreadable index is not remembered', () async {
      int reads = 0;
      Uint8List? body = Uint8List(4); // unreadable at first
      final Completer<void> gate = Completer<void>();
      final RemoteDiscMenuSource source = RemoteDiscMenuSource(
        share: RemoteDiscShare(
          baseUrl: Uri.parse('http://h:1/api/library/disc/t/'),
          manifest: _manifest(
            files: const <DiscShareFile>[
              DiscShareFile(path: 'BDMV/index.bdmv', size: 4, modifiedAt: 0),
            ],
          ),
        ),
        title: 'Disc',
        readFile: (String path, int _) async {
          reads++;
          await gate.future;
          return body;
        },
      );
      // Two overlapping callers (page probe + controller open) → one read.
      final Future<BlurayMenuInfo?> page = source.readMenuInfo();
      final Future<BlurayMenuInfo?> controller = source.readMenuInfo();
      gate.complete();
      expect(await page, isNull);
      expect(await controller, isNull);
      expect(reads, 1);

      // A failed read is not remembered: the next call reads again.
      body = indexFixture();
      final BlurayMenuInfo? first = await source.readMenuInfo();
      expect(first, isNotNull);
      expect(reads, 2);

      // A parsed index is remembered: no further network read.
      expect(identical(await source.readMenuInfo(), first), isTrue);
      expect(identical(await source.readMenuInfo(), first), isTrue);
      expect(reads, 2);
    });

    test('remote BD index read that throws is not remembered', () async {
      int reads = 0;
      final RemoteDiscMenuSource source = RemoteDiscMenuSource(
        share: RemoteDiscShare(
          baseUrl: Uri.parse('http://h:1/api/library/disc/t/'),
          manifest: _manifest(
            files: const <DiscShareFile>[
              DiscShareFile(path: 'BDMV/index.bdmv', size: 4, modifiedAt: 0),
            ],
          ),
        ),
        title: 'Disc',
        readFile: (String path, int _) async {
          reads++;
          if (reads == 1) throw const SocketException('x');
          return indexFixture();
        },
      );
      await expectLater(source.readMenuInfo(), throwsA(isA<SocketException>()));
      expect(await source.readMenuInfo(), isNotNull);
      expect(reads, 2);
    });
  });

  group('远端原盘 title 在 host 上的定位（字幕管线 / 取音频）', () {
    RemoteDiscMenuSource source({
      List<RemoteDiscShareTitle> titles = const <RemoteDiscShareTitle>[
        RemoteDiscShareTitle(id: 'host/t1', path: 'BDMV/PLAYLIST/00001.mpls'),
        RemoteDiscShareTitle(id: 'host/t8', path: 'BDMV/PLAYLIST/00800.MPLS'),
      ],
      RemoteDiscTitleAudioFetch? fetchTitleAudio,
    }) => RemoteDiscMenuSource(
      share: RemoteDiscShare(
        baseUrl: Uri.parse('http://h:1/api/library/disc/t/'),
        manifest: _manifest(),
        titles: titles,
      ),
      title: 'Disc',
      readFile: (String _, int _) async => null,
      fetchTitleAudio: fetchTitleAudio,
    );

    String member(RemoteDiscMenuSource s, String name) =>
        p.join(s.identityRoot, 'BDMV', 'PLAYLIST', name);

    test('host 库里有这条 title 的行：直接用它，不带 discTitle（老 host 也认）', () {
      final RemoteDiscMenuSource s = source();
      expect(
        s.hostTitleFor(member(s, '00001.mpls')),
        const RemoteDiscHostTitle(
          videoId: 'host/t1',
          memberPath: 'BDMV/PLAYLIST/00001.mpls',
        ),
      );
      // 盘上目录 / 文件名大小写与 libbluray 报的不一致也认得出。
      expect(s.hostTitleFor(member(s, '00800.mpls'))!.videoId, 'host/t8');
    });

    test('库里没有行的 title：同盘蓝光行当锚点 + discTitle；各条 title 键互不相同', () {
      final RemoteDiscMenuSource s = source();
      final RemoteDiscHostTitle bonus = s.hostTitleFor(
        member(s, '00005.mpls'),
      )!;
      expect(bonus.videoId, 'host/t1');
      expect(bonus.discTitle, 'BDMV/PLAYLIST/00005.mpls');
      expect(bonus.memberPath, 'BDMV/PLAYLIST/00005.mpls');
      expect(bonus.key, isNot(s.hostTitleFor(member(s, '00001.mpls'))!.key));
      expect(bonus.key, isNot(s.hostTitleFor(member(s, '00006.mpls'))!.key));
    });

    test('多角度 title 的非第 1 个角度：按 title 找行，总带角度成员路径的 discTitle', () {
      final RemoteDiscMenuSource s = source();
      // host 库里有这条 title 的行：仍用它，但要 host 按第 2 个角度读。
      final RemoteDiscHostTitle angle = s.hostTitleFor(
        member(s, '00001.a2.mpls'),
      )!;
      expect(angle.videoId, 'host/t1');
      expect(angle.memberPath, 'BDMV/PLAYLIST/00001.a2.mpls');
      expect(angle.discTitle, 'BDMV/PLAYLIST/00001.a2.mpls');
      expect(angle.readsAngle, isTrue);
      expect(angle.key, isNot(s.hostTitleFor(member(s, '00001.mpls'))!.key));
      // 库里没有行的 title：同盘锚点 + 角度成员路径。
      final RemoteDiscHostTitle bonus = s.hostTitleFor(
        member(s, '00005.a3.mpls'),
      )!;
      expect(bonus.videoId, 'host/t1');
      expect(bonus.discTitle, 'BDMV/PLAYLIST/00005.a3.mpls');
      expect(bonus.readsAngle, isTrue);
      // 第 1 个角度不带后缀，老 host 也认。
      expect(s.hostTitleFor(member(s, '00001.mpls'))!.readsAngle, isFalse);
      expect(s.hostTitleFor(member(s, '00005.mpls'))!.readsAngle, isFalse);
    });

    test('DVD title：锚在这条 title 自己的行（没有就锚在同盘 DVD 行），总带 discTitle', () {
      final RemoteDiscMenuSource s = source(
        titles: const <RemoteDiscShareTitle>[
          RemoteDiscShareTitle(
            id: 'host/d1',
            path: 'VIDEO_TS/TITLE_01.dvdtitle',
          ),
          RemoteDiscShareTitle(
            id: 'host/d3',
            path: 'VIDEO_TS/TITLE_03.dvdtitle',
          ),
        ],
      );
      String dvd(String name) => p.join(s.identityRoot, 'VIDEO_TS', name);
      final RemoteDiscHostTitle own = s.hostTitleFor(dvd('TITLE_03.dvdtitle'))!;
      expect(own.videoId, 'host/d3');
      expect(own.memberPath, 'VIDEO_TS/TITLE_03.dvdtitle');
      expect(own.discTitle, 'VIDEO_TS/TITLE_03.dvdtitle');
      expect(own.readsDvd, isTrue, reason: '老 host 判 DVD title 读不到，要它声明才发');
      expect(own.readsAngle, isFalse);
      final RemoteDiscHostTitle bonus = s.hostTitleFor(
        dvd('TITLE_07.dvdtitle'),
      )!;
      expect(bonus.videoId, 'host/d1', reason: '库里没有行：同盘 DVD 行当锚点');
      expect(bonus.discTitle, 'VIDEO_TS/TITLE_07.dvdtitle');
      expect(bonus.key, isNot(own.key));
      // 蓝光会话的 title 不会锚到 DVD 行上，反之亦然。
      expect(s.hostTitleFor(member(s, '00001.mpls')), isNull);
      expect(source().hostTitleFor(dvd('TITLE_01.dvdtitle')), isNull);
      expect(source().hostTitleFor(member(s, '00001.mpls'))!.readsDvd, isFalse);
    });

    test('DVD 多角度 title 的非第 1 个角度：按不带角度的 title 找行，discTitle 带角度', () {
      final RemoteDiscMenuSource s = source(
        titles: const <RemoteDiscShareTitle>[
          RemoteDiscShareTitle(
            id: 'host/d1',
            path: 'VIDEO_TS/TITLE_01.dvdtitle',
          ),
          RemoteDiscShareTitle(
            id: 'host/d3',
            path: 'VIDEO_TS/TITLE_03.dvdtitle',
          ),
        ],
      );
      String dvd(String name) => p.join(s.identityRoot, 'VIDEO_TS', name);
      final RemoteDiscHostTitle angle = s.hostTitleFor(
        dvd('TITLE_03.a2.dvdtitle'),
      )!;
      expect(angle.videoId, 'host/d3', reason: '库里这条 title 的行');
      expect(angle.memberPath, 'VIDEO_TS/TITLE_03.a2.dvdtitle');
      expect(angle.discTitle, 'VIDEO_TS/TITLE_03.a2.dvdtitle');
      expect(angle.readsDvd, isTrue);
      expect(angle.readsDvdAngle, isTrue);
      expect(angle.readsAngle, isFalse, reason: '蓝光角度位管不到 DVD');
      expect(angle.key, isNot(s.hostTitleFor(dvd('TITLE_03.dvdtitle'))!.key));
      final RemoteDiscHostTitle bonus = s.hostTitleFor(
        dvd('TITLE_07.a3.dvdtitle'),
      )!;
      expect(bonus.videoId, 'host/d1');
      expect(bonus.discTitle, 'VIDEO_TS/TITLE_07.a3.dvdtitle');
      expect(bonus.readsDvdAngle, isTrue);
      // 第 1 个角度不带后缀：只要 host 认 DVD title。
      expect(s.hostTitleFor(dvd('TITLE_03.dvdtitle'))!.readsDvdAngle, isFalse);
    });

    test('不在这张盘的身份根下 / DVD title 没有 DVD 行可当锚点 / 没有蓝光行可当锚点 → null', () {
      final RemoteDiscMenuSource s = source();
      expect(
        s.hostTitleFor(
          p.join(
            'fushi-remote-disc',
            'other',
            'Disc 2',
            'BDMV',
            'PLAYLIST',
            '00001.mpls',
          ),
        ),
        isNull,
      );
      expect(
        s.hostTitleFor(p.join(s.identityRoot, 'VIDEO_TS', 'TITLE_01.dvdtitle')),
        isNull,
      );
      expect(
        s.hostTitleFor(p.join(s.identityRoot, 'BDMV', 'STREAM', '00001.m2ts')),
        isNull,
      );
      expect(
        source(
          titles: const <RemoteDiscShareTitle>[],
        ).hostTitleFor(member(s, '00005.mpls')),
        isNull,
      );
    });

    test('RemoteDiscActions 把 host 取音频接到会话盘源上', () async {
      final List<(RemoteDiscHostTitle, int, int?)> asked =
          <(RemoteDiscHostTitle, int, int?)>[];
      final RemoteDiscActions actions = RemoteDiscActions(
        openShare: (String _) async => RemoteDiscShare.fromJson(_issueBody())!,
        readFile: (RemoteDiscShare _, String _, int _) async => null,
        fetchTitleAudio:
            (
              RemoteDiscHostTitle title,
              File dest, {
              required int startMs,
              required int endMs,
              int? audioStreamIndex,
              int? audioStreamCount,
            }) async => asked.add((title, endMs, audioStreamIndex)),
      );
      final RemoteDiscMenuSource s = actions.menuSource(
        RemoteDiscShare.fromJson(_issueBody())!,
        'Box',
      );
      final RemoteDiscHostTitle title = s.hostTitleFor(
        member(s, '00001.mpls'),
      )!;
      await s.fetchTitleAudio!(
        title,
        File(p.join(temp.path, 'a.aac')),
        startMs: 0,
        endMs: 5000,
        audioStreamIndex: 1,
      );
      expect(asked.single, (title, 5000, 1));
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
