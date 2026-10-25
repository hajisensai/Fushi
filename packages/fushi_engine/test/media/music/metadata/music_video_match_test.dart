import 'package:fushi_engine/media/music/metadata/music_video_match.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:test/test.dart';

YoutubeSearchHit _hit(
  String title,
  String channel, {
  Duration? duration = const Duration(minutes: 4, seconds: 30),
}) => YoutubeSearchHit(
  videoId: 'abcdefghijk',
  title: title,
  channelName: channel,
  channelId: 'UC0',
  duration: duration,
);

void main() {
  group('本地 MV 文件名预筛', () {
    test('标题必须在文件名里；艺人与 MV 标记加分', () {
      expect(
        scoreLocalMusicVideoName('Lemon.mkv', title: 'Lemon', artist: '米津玄師'),
        closeTo(0.6, 1e-9),
      );
      expect(
        scoreLocalMusicVideoName(
          '米津玄師 - Lemon (Official MV).mp4',
          title: 'Lemon',
          artist: '米津玄師',
        ),
        closeTo(0.95, 1e-9),
      );
      expect(scoreLocalMusicVideoName('Orange MV.mp4', title: 'Lemon'), 0);
      // 版本注记不影响：「Lemon (TV size)」的 MV 文件名只写 Lemon。
      expect(
        scoreLocalMusicVideoName('Lemon.mp4', title: 'Lemon (TV size)'),
        greaterThan(0),
      );
    });

    test('声纹接受门：置信度 + 命中长度', () {
      expect(
        acceptMusicVideoAlignment(
          confidence: 0.8,
          matched: const Duration(seconds: 40),
          songDurationMs: 250000,
        ),
        isTrue,
      );
      expect(
        acceptMusicVideoAlignment(
          confidence: 0.4,
          matched: const Duration(seconds: 200),
          songDurationMs: 250000,
        ),
        isFalse,
      );
      // 短歌：命中 20 s 但覆盖 80% 也认。
      expect(
        acceptMusicVideoAlignment(
          confidence: 0.9,
          matched: const Duration(seconds: 20),
          songDurationMs: 25000,
        ),
        isTrue,
      );
      expect(
        acceptMusicVideoAlignment(
          confidence: 0.9,
          matched: const Duration(seconds: 12),
          songDurationMs: 250000,
        ),
        isFalse,
      );
    });
  });

  group('YouTube 高置信判定', () {
    const int song = 255826;
    test('艺人官方频道 + 歌名：高置信', () {
      final YoutubeMusicVideoScore s = scoreYoutubeMusicVideo(
        _hit('米津玄師 MV「Lemon」', '米津玄師'),
        title: 'Lemon',
        artist: '米津玄師',
        songDurationMs: song,
      );
      expect(s.highConfidence, isTrue);
      expect(s.confidence, greaterThan(0.8));
    });

    test('Topic 频道（音源）/ 歌词视频 / 翻唱 / 时长离谱：都不算', () {
      for (final YoutubeSearchHit h in <YoutubeSearchHit>[
        _hit('Lemon', '米津玄師 - Topic'),
        _hit('米津玄師 - Lemon (Lyric Video)', '米津玄師'),
        _hit('Lemon 歌ってみた', 'someone'),
        _hit('米津玄師 Lemon MV', '米津玄師', duration: const Duration(hours: 1)),
        _hit('Lemon MV', 'random uploader'),
      ]) {
        expect(
          scoreYoutubeMusicVideo(
            h,
            title: 'Lemon',
            artist: '米津玄師',
            songDurationMs: song,
          ).highConfidence,
          isFalse,
          reason: '${h.title} / ${h.channelName}',
        );
      }
    });

    test('频道名含艺人 + MV 标记：高置信（唱片公司官方频道形态）', () {
      expect(
        scoreYoutubeMusicVideo(
          _hit('LiSA『紅蓮華』-MUSiC CLiP-', 'LiSA Official YouTube'),
          title: '紅蓮華',
          artist: 'LiSA',
          songDurationMs: 239000,
        ).highConfidence,
        isFalse, // 没有 MV 标记词（MUSiC CLiP 不在标记表里）：宁可漏，不误绑
      );
      expect(
        scoreYoutubeMusicVideo(
          _hit('LiSA 紅蓮華 Official Music Video', 'LiSA Official YouTube'),
          title: '紅蓮華',
          artist: 'LiSA',
          songDurationMs: 239000,
        ).highConfidence,
        isTrue,
      );
    });

    test('搜索词', () {
      expect(
        youtubeMusicVideoQuery(title: 'Lemon (TV size)', artist: '米津玄師'),
        '米津玄師 Lemon MV',
      );
      expect(youtubeMusicVideoQuery(title: 'Lemon'), 'Lemon MV');
    });
  });

  test('动画集引用往返', () {
    final String ref = animeEpisodeMusicVideoRef('vb#weird', 3);
    expect(parseAnimeEpisodeMusicVideoRef(ref), (
      bookUid: 'vb#weird',
      episodeIndex: 3,
    ));
    expect(parseAnimeEpisodeMusicVideoRef('nope'), isNull);
    expect(parseAnimeEpisodeMusicVideoRef('x#-1'), isNull);
  });
}
