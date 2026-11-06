// 反馈 QAondMh4M5：网络视频来源（SFTP / WebDAV / AList）里的纯音频登记同一台服务器上的
// 网络音乐来源（此前在视频扫描里被 `files.isLocal` 门直接丢掉，两个库都进不了）。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<SourceLibraryRow> addSource({
    required String kind,
    required String transport,
    required String root,
    Map<String, Object?> config = const <String, Object?>{},
    bool recursive = true,
  }) async {
    final int id = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: root,
        mediaKind: kind,
        transport: Value<String>(transport),
        rootPath: root,
        configJson: Value<String?>(jsonEncode(config)),
        recursive: Value<bool>(recursive),
        createdAt: 1,
      ),
    );
    return (await db.getMediaSourceById(id))!;
  }

  group('adoptRemoteVideoSourceAudio', () {
    test('WebDAV: plans with URL semantics; a same-server music source '
        'covers its folder, another server does not', () async {
      const String v = 'https://dav.test/v';
      final SourceLibraryRow video = await addSource(
        kind: 'video',
        transport: 'webdav',
        root: v,
        config: <String, Object?>{'username': 'u'},
      );
      await addSource(
        kind: 'music',
        transport: 'webdav',
        root: '$v/Show/CDs',
        config: <String, Object?>{'username': 'u'},
      );
      // 另一台服务器（不同账号）上同形状的根不算覆盖。
      await addSource(
        kind: 'music',
        transport: 'webdav',
        root: '$v/Drama',
        config: <String, Object?>{'username': 'someone-else'},
      );
      final List<({String rootPath, bool recursive})> registered =
          <({String rootPath, bool recursive})>[];
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        registerRemoteSource:
            ({
              required SourceLibraryRow videoSource,
              required String rootPath,
              required bool recursive,
            }) async {
              expect(videoSource.id, video.id);
              registered.add((rootPath: rootPath, recursive: recursive));
              return null;
            },
      );
      final MusicAudioIntakeResult r = await intake.adoptRemoteVideoSourceAudio(
        videoSource: video,
        scanRoot: v,
        audioPaths: <String>[
          '$v/Show/CDs/OST/01.flac',
          '$v/Drama/Disc1/01.mp3',
          '$v/Show/ep01.flac',
        ],
        videoMediaDirs: <String>['$v/Show'],
      );
      expect(registered, <({String rootPath, bool recursive})>[
        (rootPath: '$v/Drama', recursive: true),
      ]);
      expect(r.skippedPaths, <String>['$v/Show/ep01.flac']);
    });

    test('SFTP: plans in the sftp:// namespace, registers the native remote '
        'path', () async {
      const String ns = 'sftp://nas:22';
      final SourceLibraryRow video = await addSource(
        kind: 'video',
        transport: 'sftp',
        root: '/srv/v',
        config: <String, Object?>{'host': 'nas', 'port': 22, 'username': 'u'},
      );
      final List<String> registered = <String>[];
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        registerRemoteSource:
            ({
              required SourceLibraryRow videoSource,
              required String rootPath,
              required bool recursive,
            }) async {
              registered.add(rootPath);
              return null;
            },
      );
      await intake.adoptRemoteVideoSourceAudio(
        videoSource: video,
        scanRoot: '$ns/srv/v',
        audioPaths: <String>['$ns/srv/v/OST/Disc 1/01.flac'],
        videoMediaDirs: <String>['$ns/srv/v/Show'],
      );
      expect(registered, <String>['/srv/v/OST']);
    });

    test('the real registrar copies connection settings and credentials to '
        'the new music source, then scans it', () async {
      const String v = 'https://dav.test/v';
      final SourceLibraryRow video = await addSource(
        kind: 'video',
        transport: 'webdav',
        root: v,
        config: <String, Object?>{'username': 'u'},
      );
      await SourceLibraryCredentialStore(
        db,
      ).saveSecret(video.id, password: 'pw');
      final List<SourceLibraryRow> scanned = <SourceLibraryRow>[];
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        rescanSource: (SourceLibraryRow s) async {
          scanned.add(s);
          return null;
        },
      );
      await intake.adoptRemoteVideoSourceAudio(
        videoSource: video,
        scanRoot: v,
        audioPaths: <String>['$v/OST/01.flac'],
        videoMediaDirs: const <String>[],
      );
      final SourceLibraryRow music = (await db.getMediaSourcesByKind(
        'music',
      )).single;
      expect(music.transport, 'webdav');
      expect(music.rootPath, v);
      expect(music.configJson, video.configJson);
      expect(
        (await SourceLibraryCredentialStore(db).readSecret(music.id)).password,
        'pw',
      );
      expect(scanned.single.id, music.id);
    });
  });
}
