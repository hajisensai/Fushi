import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/metadata/music_album_release_matcher.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:path/path.dart' as p;

const String _relA = '11111111-1111-4111-8111-111111111111';
const String _relB = '22222222-2222-4222-8222-222222222222';
const String _tagged = '33333333-3333-4333-8333-333333333333';

MusicReleaseTracklist _release(String id, List<List<int>> media) =>
    MusicReleaseTracklist(
      mbReleaseId: id,
      title: 'x',
      media: <MusicReleaseMedium>[
        for (int m = 0; m < media.length; m++)
          MusicReleaseMedium(
            position: m + 1,
            format: 'CD',
            tracks: <MusicReleaseTrack>[
              for (int i = 0; i < media[m].length; i++)
                MusicReleaseTrack(
                  position: i + 1,
                  title: 't$i',
                  durationMs: media[m][i],
                ),
            ],
          ),
      ],
    );

/// 按专辑名返回预置候选；`throwFor` 里的专辑名模拟断网。
class _FakeProvider implements MusicReleaseProvider {
  _FakeProvider(this.byTitle, {this.throwFor = const <String>{}});

  final Map<String, List<MusicReleaseTracklist>> byTitle;
  final Set<String> throwFor;
  final List<({String title, String? artist, List<int>? counts})> calls =
      <({String title, String? artist, List<int>? counts})>[];
  int closed = 0;

  @override
  Future<List<MusicReleaseTracklist>> searchAlbumReleases(
    String title, {
    String? artist,
    List<int>? discTrackCounts,
    int limit = 5,
  }) async {
    calls.add((title: title, artist: artist, counts: discTrackCounts));
    if (throwFor.contains(title)) {
      throw const SocketException('offline');
    }
    return byTitle[title] ?? const <MusicReleaseTracklist>[];
  }

  @override
  Future<List<MusicReleaseTracklist>> searchDiscReleases(
    String title, {
    String? artist,
    int limit = 5,
  }) => throw UnimplementedError();

  @override
  Future<MusicReleaseTracklist?> fetchReleaseTracklist(String mbReleaseId) =>
      throw UnimplementedError();

  @override
  Future<List<MusicReleaseTracklist>> lookupDiscId(
    String discId, {
    String? toc,
  }) => throw UnimplementedError();

  @override
  MusicMetadataProviderKind get providerKind =>
      MusicMetadataProviderKind.musicbrainz;

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  void close() => closed++;
}

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late DateTime now;

  Future<void> addAlbum(
    String uid,
    String title, {
    String? artist,
    String? mbReleaseId,
  }) => db
      .into(db.musicAlbums)
      .insert(
        MusicAlbumsCompanion.insert(
          albumUid: uid,
          title: title,
          albumArtistCredit: Value<String?>(artist),
          mbReleaseId: Value<String?>(mbReleaseId),
          addedAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> addTrack(
    String uid,
    String albumUid, {
    required int trackNo,
    int discNo = 1,
    int? durationMs,
  }) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: p.join(tmp.path, '$uid.flac'),
          title: 'Track $uid',
          albumUid: Value<String?>(albumUid),
          discNo: Value<int?>(discNo),
          trackNo: Value<int?>(trackNo),
          durationMs: Value<int?>(durationMs),
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
      );

  MusicAlbumReleaseMatcher matcher(_FakeProvider provider) =>
      MusicAlbumReleaseMatcher(
        database: () => db,
        provider: () => provider,
        cacheDirectory: () async => Directory(p.join(tmp.path, 'disc')),
        now: () => now,
      );

  File cacheFile() =>
      File(p.join(tmp.path, 'disc', kMusicAlbumReleaseMatchesFile));

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('music_release_match_');
    now = DateTime.utc(2026, 11, 11);
    // A：两张盘，时长对得上发行 A。
    await addAlbum('a', 'Album A', artist: 'Artist');
    await addTrack('a1', 'a', trackNo: 1, durationMs: 200500);
    await addTrack('a2', 'a', trackNo: 2, durationMs: 209000);
    await addTrack('a3', 'a', trackNo: 1, discNo: 2, durationMs: 300800);
    // B：曲数一样但时长差太多 → 记「没有」。
    await addAlbum('b', 'Album B');
    await addTrack('b1', 'b', trackNo: 1, durationMs: 100000);
    // 标签里已经有发行 id：跳过，不联网。
    await addAlbum('t', 'Tagged', mbReleaseId: _tagged);
    await addTrack('t1', 't', trackNo: 1, durationMs: 1000);
    // 缺时长：不联网，直接记「没有」。
    await addAlbum('n', 'No durations');
    await addTrack('n1', 'n', trackNo: 1);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('musicAlbumDiscDurations：按盘号分组、按曲序排；缺时长记 0', () async {
    final Map<int, List<int>> d = musicAlbumDiscDurations(
      await db.listMusicTracks(albumUid: 'a'),
    );
    expect(d, <int, List<int>>{
      1: <int>[200500, 209000],
      2: <int>[300800],
    });
    expect(
      musicAlbumDiscDurations(await db.listMusicTracks(albumUid: 'n')),
      <int, List<int>>{
        1: <int>[0],
      },
    );
  });

  test('一轮对号：可信的写缓存并发事件；对不上记 null；标签有 id / 缺时长不联网', () async {
    final _FakeProvider provider = _FakeProvider(
      <String, List<MusicReleaseTracklist>>{
        'Album A': <MusicReleaseTracklist>[
          _release(_relB, <List<int>>[
            <int>[100000, 100000],
            <int>[100000],
          ]),
          _release(_relA, <List<int>>[
            <int>[200000, 210000],
            <int>[300000],
          ]),
        ],
        'Album B': <MusicReleaseTracklist>[
          _release(_relB, <List<int>>[
            <int>[200000],
          ]),
        ],
      },
    );
    final MusicAlbumReleaseMatcher m = matcher(provider);
    final List<String> events = <String>[];
    m.matchedAlbums.listen(events.add);

    await m.schedule();
    await Future<void>.delayed(Duration.zero);

    expect(
      provider.calls.map((c) => '${c.title}|${c.artist}|${c.counts}'),
      <String>['Album A|Artist|[2, 1]', 'Album B|null|[1]'],
      reason: '按标题序；标签有 id 的 Tagged、缺时长的 No durations 不联网',
    );
    expect(provider.closed, 1);
    expect(events, <String>['a']);
    expect(await m.releaseIdOf('a'), _relA);
    expect(await m.releaseIdOf('b'), isNull);
    expect(await m.releaseIdOf('t'), isNull, reason: '标签 id 不进缓存');

    final Map<String, Object?> json =
        jsonDecode(cacheFile().readAsStringSync()) as Map<String, Object?>;
    final Map<String, Object?> albums = json['albums']! as Map<String, Object?>;
    expect(albums.keys, unorderedEquals(<String>['a', 'b', 'n']));
    expect((albums['n']! as Map<String, Object?>)['release'], isNull);
    expect(
      File('${cacheFile().path}.tmp').existsSync(),
      isFalse,
      reason: '原子写：tmp 已改名',
    );

    // 新实例从文件读缓存（重启），不联网。
    final _FakeProvider again = _FakeProvider(
      const <String, List<MusicReleaseTracklist>>{},
    );
    final MusicAlbumReleaseMatcher m2 = matcher(again);
    expect(await m2.releaseIdOf('a'), _relA);
    await m2.schedule();
    expect(again.calls, isEmpty, reason: '否定结论 30 天内不重查，肯定结论不重查');

    // 30 天后：只重查否定结论里有时长的那张（B）；缺时长的 n 也到期但不联网。
    now = now.add(const Duration(days: 30));
    await m2.schedule();
    expect(again.calls.map((c) => c.title), <String>['Album B']);
    m.dispose();
    m2.dispose();
  });

  test('网络错误：不记结论，整轮停下；下次触发重查', () async {
    final _FakeProvider offline = _FakeProvider(
      const <String, List<MusicReleaseTracklist>>{},
      throwFor: <String>{'Album A', 'Album B'},
    );
    final MusicAlbumReleaseMatcher m = matcher(offline);
    await m.schedule();
    expect(offline.calls.map((c) => c.title), <String>[
      'Album A',
    ], reason: '按标题序第一张就失败：整轮停下');
    expect(offline.closed, 1);
    expect(cacheFile().existsSync(), isFalse, reason: '网络错误不记结论');
    expect(await m.releaseIdOf('a'), isNull);
    m.dispose();
  });

  test('dispose 之后 schedule 不再联网', () async {
    final _FakeProvider provider = _FakeProvider(
      const <String, List<MusicReleaseTracklist>>{},
    );
    final MusicAlbumReleaseMatcher m = matcher(provider)..dispose();
    await m.schedule();
    expect(provider.calls, isEmpty);
  });
}
