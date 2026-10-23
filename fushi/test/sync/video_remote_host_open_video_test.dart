import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi/src/sync/video_remote_library_port.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 点播（`library` / `openVideo`）：电脑上没开视频时，手机也能从电脑视频库里
/// 选片让电脑播放。
void main() {
  late FushiDatabase db;
  late List<String> opened;
  late VideoRemoteException? openFailure;
  late List<VideoRemoteLibraryItem> library;
  late VideoRemoteHost host;
  int serial = 0;

  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) => host.handle(operation, <String, dynamic>{
    'requestId': 'request_${++serial}',
    ...data,
  }, 'phone');

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    opened = <String>[];
    openFailure = null;
    library = const <VideoRemoteLibraryItem>[
      VideoRemoteLibraryItem(
        bookUid: 'a',
        title: 'ぼっち・ざ・ろっく！ 第1話',
        collection: 'ぼっち・ざ・ろっく！',
        positionMs: 61000,
        lastPlayedAt: 20,
      ),
      VideoRemoteLibraryItem(bookUid: 'b', title: '葬送のフリーレン 第2話'),
      VideoRemoteLibraryItem(bookUid: 'c', title: 'Movie'),
    ];
    host = VideoRemoteHost(
      favorites: () => FavoriteSentenceRepository(db),
      library: VideoRemoteLibrary(
        list: () async => library,
        open: (String bookUid) async {
          final VideoRemoteException? failure = openFailure;
          if (failure != null) throw failure;
          opened.add(bookUid);
        },
      ),
    );
    await host.handle('snapshot', <String, dynamic>{}, 'phone');
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
  });

  test('advertises on-demand playback without an open video', () async {
    final Map<String, Object?> snapshot = await host.handle(
      'snapshot',
      <String, dynamic>{},
      'phone',
    );
    expect(snapshot['available'], isFalse);
    expect(snapshot['capabilities'], <String>[videoRemoteCapabilityOpenVideo]);
  });

  test('lists the library with search and paging', () async {
    final Map<String, Object?> all = await call('library');
    expect(all['total'], 3);
    expect(all['currentBookUid'], isNull);
    expect(
      (all['items']! as List<Object?>).map(
        (Object? item) => (item! as Map<String, Object?>)['bookUid'],
      ),
      <String>['a', 'b', 'c'],
    );
    expect((all['items']! as List<Object?>).first, <String, Object?>{
      'bookUid': 'a',
      'title': 'ぼっち・ざ・ろっく！ 第1話',
      'collection': 'ぼっち・ざ・ろっく！',
      'positionMs': 61000,
      'lastPlayedAt': 20,
    });

    // 统一搜索口径：片假名 / 平假名、大小写都能命中；合集名也可搜。
    final Map<String, Object?> kana = await call('library', <String, dynamic>{
      'query': 'フリーれん',
    });
    expect(kana['total'], 1);
    final Map<String, Object?> lower = await call('library', <String, dynamic>{
      'query': 'movie',
    });
    expect(lower['total'], 1);

    final Map<String, Object?> page = await call('library', <String, dynamic>{
      'offset': 1,
      'limit': 1,
    });
    expect(page['total'], 3);
    expect(page['offset'], 1);
    expect(
      (page['items']! as List<Object?>).single,
      containsPair('bookUid', 'b'),
    );
  });

  test(
    'library items carry the cover version only when there is a cover',
    () async {
      library = const <VideoRemoteLibraryItem>[
        VideoRemoteLibraryItem(bookUid: 'a', title: 'A', coverVersion: 1234),
        VideoRemoteLibraryItem(bookUid: 'b', title: 'B'),
      ];
      final List<Object?> items = (await call('library'))['items']! as List;
      expect(items.first, containsPair('coverVersion', 1234));
      expect(items.last, isNot(contains('coverVersion')));
    },
  );

  test('cover version is the cover file mtime, null without a file', () async {
    final Directory dir = await Directory.systemTemp.createTemp('vr_cover');
    addTearDown(() => dir.delete(recursive: true));
    final File cover = File('${dir.path}/cover.jpg')
      ..writeAsBytesSync(<int>[1]);
    final DateTime mtime = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    cover.setLastModifiedSync(mtime);
    expect(
      await videoRemoteCoverVersion(cover.path),
      mtime.millisecondsSinceEpoch,
    );
    expect(await videoRemoteCoverVersion('${dir.path}/missing.jpg'), isNull);
    expect(await videoRemoteCoverVersion(dir.path), isNull);
    expect(await videoRemoteCoverVersion(null), isNull);
    expect(await videoRemoteCoverVersion(''), isNull);
  });

  test(
    'openVideo hands the bookUid to the app without an open video',
    () async {
      expect(await call('openVideo', <String, dynamic>{'bookUid': 'b'}), {
        'ok': true,
      });
      expect(opened, <String>['b']);
    },
  );

  test(
    'openVideo rejects a missing bookUid and surfaces adapter codes',
    () async {
      await expectLater(
        call('openVideo'),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException e) => e.code,
            'code',
            'invalid_argument',
          ),
        ),
      );
      openFailure = const VideoRemoteException(409, 'host_busy');
      await expectLater(
        call('openVideo', <String, dynamic>{'bookUid': 'a'}),
        throwsA(
          isA<VideoRemoteException>()
              .having((VideoRemoteException e) => e.status, 'status', 409)
              .having((VideoRemoteException e) => e.code, 'code', 'host_busy'),
        ),
      );
      expect(opened, isEmpty);
    },
  );

  test('a host without a library neither advertises nor answers', () async {
    final VideoRemoteHost bare = VideoRemoteHost(
      favorites: () => FavoriteSentenceRepository(db),
    );
    addTearDown(bare.dispose);
    final Map<String, Object?> snapshot = await bare.handle(
      'snapshot',
      <String, dynamic>{},
      'phone',
    );
    expect(snapshot['capabilities'], isEmpty);
    for (final String operation in <String>['library', 'openVideo']) {
      await expectLater(
        bare.handle(operation, <String, dynamic>{
          'requestId': 'r_$operation',
          'bookUid': 'a',
        }, 'phone'),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException e) => e.code,
            'code',
            videoRemoteActionUnsupported,
          ),
        ),
      );
    }
  });

  test(
    'library listing: recently played first, collection names attached',
    () async {
      Future<void> insert(
        String uid,
        String title, {
        int? playedAt,
        int? importedAt,
        int positionMs = 0,
      }) => db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: title,
          videoPath: '/videos/$uid.mp4',
          lastPlayedAt: Value<int?>(playedAt),
          importedAt: Value<int?>(importedAt),
          lastPositionMs: Value<int>(positionMs),
        ),
      );
      await insert('old', 'Old import', importedAt: 1);
      await insert('new', 'New import', importedAt: 5);
      await insert('played', 'Episode 3', playedAt: 100, positionMs: 4200);
      await insert('earlier', 'Episode 1', playedAt: 50);
      final int collection = await db.createMediaCollection('Show');
      await db.addToCollection(collection, MediaKind.video, 'played');

      final List<VideoRemoteLibraryItem> items = await listVideoRemoteLibrary(
        db,
      );
      expect(items.map((VideoRemoteLibraryItem item) => item.bookUid), <String>[
        'played',
        'earlier',
        'new',
        'old',
      ]);
      expect(items.first.collection, 'Show');
      expect(items.first.positionMs, 4200);
      expect(items[1].collection, isNull);
    },
  );
}
