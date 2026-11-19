// 拍板台 jeNKF9u0WJ：音乐来源里的视频容器进曲库（本地 MV），曲目行标「MV」，看画面复用
// 视频播放页——首次观看登记进视频库并标「MV」标签。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_local_video.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/external_video.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

MusicTrackRow _track(String path, {String? codec, int? bitrate}) =>
    MusicTrackRow(
      trackUid: path,
      path: path,
      title: 't',
      codec: codec,
      bitrate: bitrate,
      isLossless: false,
      fileMtimeAt: 1,
      fileSize: 1,
      hasEmbeddedCover: false,
      addedAt: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isVideoMediaPath / isMusicLocalVideoTrack', () {
    test('视频容器（含 mp4、大小写）算 MV，纯音频与非媒体不算', () {
      for (final String p in <String>[
        '/m/a.mkv',
        r'D:\Music\b.MP4',
        '/m/c.webm',
        'https://h/x/d.m4v?sig=1',
      ]) {
        expect(isVideoMediaPath(p), isTrue, reason: p);
      }
      for (final String p in <String>[
        '/m/a.flac',
        '/m/a.mka',
        '/m/a.ass',
        '/m/.mkv',
        '/m/noext',
        '',
      ]) {
        expect(isVideoMediaPath(p), isFalse, reason: p);
      }
      expect(isMusicLocalVideoTrack(_track('/m/Song MV.mkv')), isTrue);
      expect(isMusicLocalVideoTrack(_track('/m/Song.flac')), isFalse);
    });

    test('网络来源的 MV 标 MV，但不算可在视频播放页看的本地 MV', () {
      for (final String path in <String>[
        'https://dav.example/music/Song MV.mkv',
        'sftp://nas/music/Song MV.mkv',
        'http://alist.local/d/music/Song MV.mp4?sign=1',
      ]) {
        expect(isMusicVideoTrack(_track(path)), isTrue, reason: path);
        expect(isMusicLocalVideoTrack(_track(path)), isFalse, reason: path);
      }
      // 本机绝对路径的写法随平台（path 包按当前平台判），这里只用两端都认的根路径。
      expect(
        isMusicLocalVideoTrack(_track('/storage/emulated/0/Music/MV.mkv')),
        isTrue,
      );
      expect(isMusicLocalVideoTrack(_track('relative/Song MV.mkv')), isFalse);
      LocaleSettings.setLocale(AppLocale.en);
      expect(
        musicLocalTrackBadges(_track('sftp://nas/m/a.mkv', codec: 'unknown')),
        <String>['MV'],
      );
    });

    test('徽章段：MV 在前、格式徽章在后；纯音频不标 MV', () {
      LocaleSettings.setLocale(AppLocale.en);
      expect(
        musicLocalTrackBadges(_track('/m/a.mkv', codec: 'unknown')),
        <String>['MV'],
      );
      expect(
        musicLocalTrackBadges(_track('/m/a.mp4', codec: 'aac', bitrate: 256)),
        <String>['MV', 'AAC 256k'],
      );
      expect(
        musicLocalTrackBadges(_track('/m/a.mp3', codec: 'mp3', bitrate: 320)),
        <String>['MP3 320k'],
      );
    });
  });

  group('ensureMusicVideoInVideoLibrary', () {
    late FushiDatabase db;
    late VideoBookRepository repo;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = VideoBookRepository(db);
    });
    tearDown(() => db.close());

    Future<List<String>> tagsOf(String bookUid) async => <String>[
      for (final BookTagRow t in await db.getTagsForVideoBook(bookUid)) t.name,
    ];

    test('首次观看：按外部视频身份登记（不复制、原路径）并标 MV；再看复用同一行', () async {
      const String path = '/music/Artist/Song MV.mkv';
      final String uid = await ensureMusicVideoInVideoLibrary(db, path);
      expect(uid, externalVideoBookUid(path));
      final VideoBookRow? row = await repo.getByBookUid(uid);
      expect(row, isNotNull);
      expect(row!.videoPath, path);
      expect(row.title, 'Song MV');
      expect(await tagsOf(uid), <String>[kMusicVideoTagName]);

      // 用户删掉 MV 标签后再看：复用旧行、不把标签加回来。
      final int tagId = await db.getOrCreateTagByName(kMusicVideoTagName);
      await db.removeTagFromVideoBook(uid, tagId);
      expect(await ensureMusicVideoInVideoLibrary(db, path), uid);
      expect(await tagsOf(uid), isEmpty);
      expect(
        (await db.select(db.videoBooks).get()).length,
        1,
        reason: '同一个文件只有一行',
      );
    });

    test('文件已在视频库（别的身份导入）：复用那一行，不动用户标签', () async {
      const String path = '/video/Song MV.mkv';
      await repo.saveVideoBook(
        const VideoBooksCompanion(
          bookUid: Value<String>('video/Song MV.mkv'),
          title: Value<String>('Song MV'),
          videoPath: Value<String>(path),
        ),
      );
      final String uid = await ensureMusicVideoInVideoLibrary(db, path);
      expect(uid, 'video/Song MV.mkv');
      expect(await tagsOf(uid), isEmpty);
      expect((await db.select(db.videoBooks).get()).length, 1);
    });
  });
}
