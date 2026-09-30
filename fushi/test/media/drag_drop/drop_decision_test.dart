import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';

DroppedFiles _files({
  List<String> books = const [],
  List<String> videos = const [],
  List<String> subtitles = const [],
  List<String> audios = const [],
  List<String> playlists = const [],
  List<String> dictionaries = const [],
  List<String> urls = const [],
  List<String> torrents = const [],
}) =>
    DroppedFiles(
        books: books,
        videos: videos,
        subtitles: subtitles,
        audios: audios,
        playlists: playlists,
        dictionaries: dictionaries,
        urls: urls,
        torrents: torrents,
        unknown: const []);

void main() {
  group('decideDropIntent — books surface', () {
    test('book file -> importNewBook', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(books: ['/a.epub']),
            cardHit: false),
        DropIntent.importNewBook,
      );
    });
    test('subtitle on a card -> attachToBookCard', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(subtitles: ['/a.srt']),
            cardHit: true),
        DropIntent.attachToBookCard,
      );
    });
    test('audio not on a card -> needCardTarget', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(audios: ['/a.mp3']),
            cardHit: false),
        DropIntent.needCardTarget,
      );
    });
    test('book wins over subtitle when both dropped', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(books: ['/a.epub'], subtitles: ['/a.srt']),
            cardHit: false),
        DropIntent.importNewBook,
      );
    });
    // TODO-558 / BUG-326: 书架拖入视频 → 自动切到视频导入（不再 unsupportedSurface 只提示）。
    test('video on books surface -> importNewVideo (auto-switch)', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mkv']),
            cardHit: false),
        DropIntent.importNewVideo,
      );
    });
    // .mp4 既是 video 又是 audio：拖到书卡时仍优先挂音频（保留原行为），不误判成新建视频。
    test('mp4 on a book card -> attachToBookCard (audio, not new video)', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mp4'], audios: ['/a.mp4']),
            cardHit: true),
        DropIntent.attachToBookCard,
      );
    });
    // .mp4 拖到书架空白处（非命中卡）→ 当作视频自动切到视频导入。
    test('mp4 on books surface blank area -> importNewVideo', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mp4'], audios: ['/a.mp4']),
            cardHit: false),
        DropIntent.importNewVideo,
      );
    });

    // TODO-1306: 书架拖入网络流 URL → 自动切到视频导入（流媒体入库）。
    test('http url on books surface -> importVideoUrl (auto-switch)', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(urls: ['https://youtu.be/abc']),
            cardHit: false),
        DropIntent.importVideoUrl,
      );
    });
    // URL 优先于同拖的视频文件（浏览器拖来的是意图明确的链接）。
    test('url wins over video file on books surface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(urls: ['https://x.test/a'], videos: ['/a.mkv']),
            cardHit: false),
        DropIntent.importVideoUrl,
      );
    });

    test('unknown-only input -> ignore', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: const DroppedFiles(
                books: [],
                videos: [],
                subtitles: [],
                audios: [],
                playlists: [],
                dictionaries: [],
                urls: [],
                unknown: ['/a.bin']),
            cardHit: false),
        DropIntent.ignore,
      );
    });
  });

  group('decideDropIntent — video surface', () {
    test('video file -> importNewVideo', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(videos: ['/a.mkv']),
            cardHit: false),
        DropIntent.importNewVideo,
      );
    });
    // TODO-1306: 视频表面拖入网络流 URL → importVideoUrl。
    test('http url on video surface -> importVideoUrl', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(urls: ['https://example.com/a.mp4']),
            cardHit: false),
        DropIntent.importVideoUrl,
      );
    });
    test('url wins over playlist on video surface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(urls: ['https://x.test/a'], playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importVideoUrl,
      );
    });
    test('subtitle on a video card -> attachToVideoCard', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(subtitles: ['/a.srt']),
            cardHit: true),
        DropIntent.attachToVideoCard,
      );
    });
    test('subtitle not on a card -> needCardTarget', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(subtitles: ['/a.srt']),
            cardHit: false),
        DropIntent.needCardTarget,
      );
    });
    // 纯音频 = 无画面的视频：视频页上拖专辑曲目即新建视频条目（此前回「不支持」）。
    test('audio-only on video surface -> importNewVideo (on or off a card)', () {
      for (final bool cardHit in <bool>[true, false]) {
        expect(
          decideDropIntent(
              surface: DropSurface.video,
              files: _files(audios: ['/a.flac']),
              cardHit: cardHit),
          DropIntent.importNewVideo,
          reason: 'cardHit=$cardHit',
        );
      }
    });
    test('audio + subtitle on video surface -> importNewVideo', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(audios: ['/a.mp3'], subtitles: ['/a.srt']),
            cardHit: true),
        DropIntent.importNewVideo,
      );
    });
    test('audio-only on books surface still means audiobook material', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(audios: ['/a.flac']),
            cardHit: false),
        DropIntent.needCardTarget,
      );
    });
    test('videoLibraryMedia = videos + non-video audio, mp4 counted once', () {
      final DroppedFiles files = classifyDroppedFiles(
          <String>['/x/ep.mp4', '/x/01.flac', '/x/a.srt', '/x/02.MP3']);
      expect(files.videoLibraryMedia,
          <String>['/x/ep.mp4', '/x/01.flac', '/x/02.MP3']);
    });
    test('Blu-ray disc fragment (index.bdmv) -> addFolderAsSource', () {
      // 回归：拖 `.bdmv` 进视频页此前落 unknown → 静默无反应。
      const DroppedFiles files = DroppedFiles(
          books: <String>[],
          videos: <String>[],
          subtitles: <String>[],
          audios: <String>[],
          playlists: <String>[],
          dictionaries: <String>[],
          urls: <String>[],
          unknown: <String>[],
          blurayDiscs: <String>['/disc']);
      expect(
        decideDropIntent(
            surface: DropSurface.video, files: files, cardHit: false),
        DropIntent.addFolderAsSource,
      );
    });
    test('disc m2ts wins over importing it as a lone video', () {
      const DroppedFiles files = DroppedFiles(
          books: <String>[],
          videos: <String>['/disc/BDMV/STREAM/00001.m2ts'],
          subtitles: <String>[],
          audios: <String>[],
          playlists: <String>[],
          dictionaries: <String>[],
          urls: <String>[],
          unknown: <String>[],
          blurayDiscs: <String>['/disc']);
      expect(
        decideDropIntent(
            surface: DropSurface.video, files: files, cardHit: false),
        DropIntent.addFolderAsSource,
      );
    });
    test('disc on the books surface is not silently eaten', () {
      const DroppedFiles files = DroppedFiles(
          books: <String>[],
          videos: <String>[],
          subtitles: <String>[],
          audios: <String>[],
          playlists: <String>[],
          dictionaries: <String>[],
          urls: <String>[],
          unknown: <String>[],
          blurayDiscs: <String>['/disc']);
      expect(
        decideDropIntent(
            surface: DropSurface.books, files: files, cardHit: false),
        DropIntent.unsupportedSurface,
      );
    });
    test('m3u8 playlist -> importNewPlaylist', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
    test('playlist wins over video when both dropped', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(videos: ['/a.mkv'], playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
  });

  group('decideDropIntent — playlist on books surface', () {
    // TODO-558 / BUG-326: 书架拖入 m3u8 → 自动切到视频导入（解析多集），不再只提示。
    test('m3u8 on books surface -> importNewPlaylist (auto-switch)', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
    // 播放列表比单视频更具体：两者同拖时优先播放列表（与 video 表面对称）。
    test('playlist wins over video on books surface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mkv'], playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
  });

  // BT 种子：三个表面都路由到下载中心「添加任务」对话框——种子不属于任何库页，
  // 落点只决定预填的内容类型。此前落 unknown → ignore，用户拖进去毫无反应。
  group('decideDropIntent — torrent', () {
    for (final DropSurface surface in DropSurface.values) {
      test('.torrent on $surface -> importTorrent', () {
        expect(
          decideDropIntent(
              surface: surface,
              files: _files(torrents: ['/a.torrent']),
              cardHit: false),
          DropIntent.importTorrent,
        );
      });
    }
    // 种子是用户拖的实体文件，同批夹带的 URL 字符串让位。
    test('torrent wins over url on video surface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(torrents: ['/a.torrent'], urls: ['https://x.test/a']),
            cardHit: false),
        DropIntent.importTorrent,
      );
    });
    // 文件夹仍优先：拖一整个目录进视频页要的是登记扫描根，不是里面的种子。
    test('folder wins over torrent on video surface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: const DroppedFiles(
                books: [],
                videos: [],
                subtitles: [],
                audios: [],
                playlists: [],
                dictionaries: [],
                urls: [],
                directories: ['/season'],
                torrents: ['/a.torrent'],
                unknown: []),
            cardHit: false),
        DropIntent.addFolderAsSource,
      );
    });
    // 书架：书文件优先（那是本页主业），种子只在没有书时接管。
    test('book wins over torrent on books surface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(books: ['/a.epub'], torrents: ['/a.torrent']),
            cardHit: false),
        DropIntent.importNewBook,
      );
    });
  });
}
