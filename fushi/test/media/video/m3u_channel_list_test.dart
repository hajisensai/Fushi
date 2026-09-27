// STRM 流指针与 M3U / IPTV 频道列表的纯解析（fushi_engine）：
// - parseM3uExtinf：引号内逗号不切、属性小写、时长 -1、坏行容错；
// - parseM3uChannels：tvg-* / group-title / #EXTGRP、相对条目按基址解析；
// - isHlsStreamPlaylist：HLS media / master 是单条流，频道列表不是；
// - parseM3u8：标题改走引号感知解析后，带属性的 EXTINF 不再切错位；
// - strm_file：目标行、分类、路径判据；封面回填不碰 rtsp / .strm。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/media/video/strm_file.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show isLocalFrameExtractableVideoSource;

const String _iptvList = '''
#EXTM3U x-tvg-url="http://epg.example/guide.xml"
#EXTINF:-1 tvg-id="nhk.jp" tvg-name="NHK G" tvg-logo="http://logo.example/nhk.png" group-title="News, JP",NHK 総合
http://iptv.example/nhk/index.m3u8
#EXTINF:-1 tvg-name="BS1" group-title="Sports",
rtsp://cam.example:554/bs1
#EXTINF:-1,Plain Name, with comma
#EXTGRP:Misc
udp://@239.0.0.1:1234
http://iptv.example/bare/stream.ts
''';

const String _hlsMedia = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:120
#EXTINF:6.0,
seg120.ts
#EXTINF:6.0,
seg121.ts
''';

const String _hlsMaster = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
high/index.m3u8
''';

void main() {
  group('parseM3uExtinf', () {
    test('引号内逗号不切分，属性键小写、值剥引号，时长 -1', () {
      final M3uExtinf info = parseM3uExtinf(
        '#EXTINF:-1 TVG-ID="a" tvg-name="N, X" group-title="G,1",Display, Name',
      );
      expect(info.durationSeconds, -1);
      expect(info.attributes['tvg-id'], 'a');
      expect(info.attributes['tvg-name'], 'N, X');
      expect(info.attributes['group-title'], 'G,1');
      expect(info.displayName, 'Display, Name');
    });

    test('坏行容错：缺逗号 / 缺时长 / 未闭合引号都不抛', () {
      expect(parseM3uExtinf('#EXTINF:').displayName, '');
      expect(parseM3uExtinf('#EXTINF:abc').durationSeconds, isNull);
      final M3uExtinf unclosed = parseM3uExtinf('#EXTINF:-1 tvg-name="oops,x');
      expect(unclosed.displayName, '');
      final M3uExtinf bare = parseM3uExtinf('#EXTINF:10.5,Title');
      expect(bare.durationSeconds, 10.5);
      expect(bare.displayName, 'Title');
      expect(bare.attributes, isEmpty);
    });
  });

  group('parseM3uChannels', () {
    test('显示名 / tvg-name / basename 三级回退，属性与分组落位', () {
      final List<M3uChannel> channels =
          parseM3uChannels(content: _iptvList, baseDir: '/lists');
      expect(channels, hasLength(4));

      expect(channels[0].title, 'NHK 総合');
      expect(channels[0].url, 'http://iptv.example/nhk/index.m3u8');
      expect(channels[0].tvgId, 'nhk.jp');
      expect(channels[0].tvgName, 'NHK G');
      expect(channels[0].tvgLogo, 'http://logo.example/nhk.png');
      expect(channels[0].groupTitle, 'News, JP');

      // 逗号后为空 → 退 tvg-name；rtsp 地址原样。
      expect(channels[1].title, 'BS1');
      expect(channels[1].url, 'rtsp://cam.example:554/bs1');
      expect(channels[1].groupTitle, 'Sports');

      // #EXTGRP 兜底分组；显示名里的逗号保留。
      expect(channels[2].title, 'Plain Name, with comma');
      expect(channels[2].groupTitle, 'Misc');
      expect(channels[2].url, 'udp://@239.0.0.1:1234');

      // 无 EXTINF 的裸行：标题回退 basename，属性全空（上一条的属性不串过来）。
      expect(channels[3].title, 'stream.ts');
      expect(channels[3].groupTitle, isNull);
      expect(channels[3].tvgLogo, isNull);
    });

    test('相对条目按远端列表目录解析；CRLF 与 BOM 容错', () {
      final List<M3uChannel> channels = parseM3uChannels(
        content: '\uFEFF#EXTM3U\r\n#EXTINF:-1,Ch 1\r\nch1/live.m3u8\r\n',
        baseDir: 'https://host.example/iptv',
      );
      expect(channels, hasLength(1));
      expect(channels.single.title, 'Ch 1');
      expect(channels.single.url, 'https://host.example/iptv/ch1/live.m3u8');
      expect(channels.single.toPlaylistEntry().path, channels.single.url);
    });
  });

  group('isHlsStreamPlaylist', () {
    test('HLS media / master 是单条流', () {
      expect(isHlsStreamPlaylist(_hlsMedia), isTrue);
      expect(isHlsStreamPlaylist(_hlsMaster), isTrue);
    });

    test('频道列表 / 分集清单不是（#EXT-X-VERSION 与 #EXTINF 不算判据）', () {
      expect(isHlsStreamPlaylist(_iptvList), isFalse);
      expect(
        isHlsStreamPlaylist('#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:-1,A\na.mkv\n'),
        isFalse,
      );
    });
  });

  test('parseM3u8：带属性的 EXTINF 取引号外逗号后的标题', () {
    final List<PlaylistEntry> entries = parseM3u8(
      content: '#EXTINF:-1 group-title="A, B",第1話\nep1.mkv\n'
          '#EXTINF:-1 tvg-name="Fallback",\nep2.mkv\n',
      baseDir: '/v',
    );
    expect(entries.map((PlaylistEntry e) => e.title).toList(),
        <String>['第1話', 'Fallback']);
  });

  group('strm_file', () {
    test('parseStrmTarget：跳过 BOM / 空行 / 注释，取首条', () {
      expect(
        parseStrmTarget('\uFEFF\n# comment\r\n  https://a.example/v.mp4  \nx'),
        'https://a.example/v.mp4',
      );
      expect(parseStrmTarget('# only\n\n'), isNull);
      expect(parseStrmTarget(''), isNull);
    });

    test('classifyStrmTarget：网络流 / 本地路径 / 不支持', () {
      expect(
          classifyStrmTarget('https://a/b.m3u8'), StrmTargetKind.networkStream);
      expect(classifyStrmTarget('rtmp://live.example/app/key'),
          StrmTargetKind.networkStream);
      expect(classifyStrmTarget('udp://@239.0.0.1:1234'),
          StrmTargetKind.networkStream);
      expect(classifyStrmTarget(r'D:\Movies\a.mkv'), StrmTargetKind.localPath);
      expect(classifyStrmTarget('/mnt/media/a.mkv'), StrmTargetKind.localPath);
      expect(classifyStrmTarget('file:///mnt/a.mkv'), StrmTargetKind.localPath);
      expect(
          classifyStrmTarget(r'\\nas\share\a.mkv'), StrmTargetKind.localPath);
      expect(classifyStrmTarget('plugin://plugin.video.x/?id=1'),
          StrmTargetKind.unsupported);
      expect(classifyStrmTarget('movies/a.mkv'), StrmTargetKind.unsupported);
    });

    test('isStrmPath：本地与来源库网络条目，忽略 query；目录名里的点不算', () {
      expect(isStrmPath(r'D:\lib\Show S01E01.STRM'), isTrue);
      expect(isStrmPath('https://nas/dav/Show%20S01E01.strm?x=1'), isTrue);
      expect(isStrmPath('/a.strm/b.mkv'), isFalse);
      expect(isStrmPath('https://nas/dav/a.mkv'), isFalse);
      expect(isStrmPath(''), isFalse);
    });

    test('isNetworkStreamUrl 覆盖直播协议，本地路径与无 host 不算', () {
      expect(isNetworkStreamUrl('rtsp://cam/1'), isTrue);
      expect(isNetworkStreamUrl('https://a/b'), isTrue);
      expect(isNetworkStreamUrl(r'C:\a.mkv'), isFalse);
      expect(isNetworkStreamUrl('http://'), isFalse);
      expect(isNetworkStreamUrl('smb://nas/a.mkv'), isFalse);
    });

    test('封面回填候选不含 rtsp / udp 频道与 .strm 流指针', () {
      expect(isLocalFrameExtractableVideoSource('rtsp://cam/1'), isFalse);
      expect(isLocalFrameExtractableVideoSource('udp://@239.0.0.1:1'), isFalse);
      expect(isLocalFrameExtractableVideoSource('/v/a.strm'), isFalse);
      expect(isLocalFrameExtractableVideoSource('/v/a.mkv'), isTrue);
    });
  });
}
