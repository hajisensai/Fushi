import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/m3u8_playlist.dart';
import 'package:path/path.dart' as p;

/// 龙女仆「观看顺序.m3u8」样例片段：标准扩展 M3U，`#EXTINF:-1,<中文标题>` +
/// 下一行 Windows 反斜杠相对路径（相对 m3u8 所在目录）。
const String _dragonMaidSample = '''
#EXTM3U

#EXTINF:-1,【S1】第01话 史上最强女仆登场！（其实是龙）
Season 01\\Miss Kobayashi's Dragon Maid - S01E01.mkv
#EXTINF:-1,【S1】第02话 第二只龙·康娜！（完全是在惯她了）
Season 01\\Miss Kobayashi's Dragon Maid - S01E02.mkv

#EXTINF:-1,【OVA】情人节与温泉！（请不要期待太多）
Season 00\\Miss Kobayashi's Dragon Maid - S00E01.mkv
''';

void main() {
  group('parseM3u8', () {
    test('解析龙女仆样例：条数/标题/绝对路径（反斜杠归一化）', () {
      const String baseDir = r'D:\video\Miss Kobayashi' 's Dragon Maid';
      final List<PlaylistEntry> entries = parseM3u8(
        content: _dragonMaidSample,
        baseDir: baseDir,
      );

      expect(entries.length, 3);

      expect(entries[0].title, '【S1】第01话 史上最强女仆登场！（其实是龙）');
      expect(entries[1].title, '【S1】第02话 第二只龙·康娜！（完全是在惯她了）');
      expect(entries[2].title, '【OVA】情人节与温泉！（请不要期待太多）');

      // 路径：baseDir + 相对路径（\\ 归一化），用 path 包断言以兼容平台分隔符。
      expect(
        entries[0].path,
        p.normalize(p.join(
          baseDir,
          "Season 01/Miss Kobayashi's Dragon Maid - S01E01.mkv",
        )),
      );
      expect(
        entries[1].path,
        p.normalize(p.join(
          baseDir,
          "Season 01/Miss Kobayashi's Dragon Maid - S01E02.mkv",
        )),
      );
      expect(
        entries[2].path,
        p.normalize(p.join(
          baseDir,
          "Season 00/Miss Kobayashi's Dragon Maid - S00E01.mkv",
        )),
      );
    });

    test('跳过空行与非 EXTINF 注释行', () {
      const String content = '''
#EXTM3U
# 这是一条普通注释，不是 EXTINF

#EXTINF:-1,标题A
a.mkv
#EXTINF:-1,标题B
sub/b.mkv
''';
      final List<PlaylistEntry> entries = parseM3u8(
        content: content,
        baseDir: '/base',
      );
      expect(entries.length, 2);
      expect(entries[0].title, '标题A');
      expect(entries[1].title, '标题B');
    });

    test('无 EXTINF 标题的裸路径行也作为一集（标题回退为文件名）', () {
      const String content = '''
#EXTM3U
plain.mkv
''';
      final List<PlaylistEntry> entries = parseM3u8(
        content: content,
        baseDir: '/base',
      );
      expect(entries.length, 1);
      expect(entries[0].title, 'plain.mkv');
    });

    test('toJson/fromJson 往返', () {
      const PlaylistEntry entry = PlaylistEntry(title: 't', path: '/a/b.mkv');
      final PlaylistEntry round = PlaylistEntry.fromJson(entry.toJson());
      expect(round.title, 't');
      expect(round.path, '/a/b.mkv');
    });
  });

  group('PlaylistEntry positionMs', () {
    test('默认 positionMs=0', () {
      const PlaylistEntry entry = PlaylistEntry(title: 't', path: '/a.mkv');
      expect(entry.positionMs, 0);
    });

    test('toJson/fromJson 往返带 positionMs', () {
      const PlaylistEntry entry =
          PlaylistEntry(title: 't', path: '/a.mkv', positionMs: 12345);
      final PlaylistEntry round = PlaylistEntry.fromJson(entry.toJson());
      expect(round.positionMs, 12345);
    });

    test('fromJson 兼容旧数据（缺 positionMs 字段回退 0）', () {
      final PlaylistEntry round = PlaylistEntry.fromJson(
        <String, dynamic>{'title': 't', 'path': '/a.mkv'},
      );
      expect(round.positionMs, 0);
    });

    test('copyWith 只改 positionMs，保留 title/path', () {
      const PlaylistEntry entry = PlaylistEntry(title: 't', path: '/a.mkv');
      final PlaylistEntry next = entry.copyWith(positionMs: 999);
      expect(next.title, 't');
      expect(next.path, '/a.mkv');
      expect(next.positionMs, 999);
      // 原对象不变（不可变更新）。
      expect(entry.positionMs, 0);
    });
  });

  group('updateEntryPosition', () {
    final List<PlaylistEntry> base = <PlaylistEntry>[
      const PlaylistEntry(title: 'e0', path: '/0.mkv'),
      const PlaylistEntry(title: 'e1', path: '/1.mkv', positionMs: 5000),
      const PlaylistEntry(title: 'e2', path: '/2.mkv'),
    ];

    test('更新目标集的 position，其它集不变', () {
      final List<PlaylistEntry> next = updateEntryPosition(base, 0, 3000);
      expect(next[0].positionMs, 3000);
      expect(next[1].positionMs, 5000); // 未动
      expect(next[2].positionMs, 0);
    });

    test('切集保存当前集 + 恢复目标集 position 全流程', () {
      // 在第 0 集播到 8000ms，切到第 1 集（恢复其 5000ms），再回第 0 集应回 8000。
      List<PlaylistEntry> eps = base;
      eps = updateEntryPosition(eps, 0, 8000); // 保存当前集（0）进度
      expect(eps[0].positionMs, 8000);
      // 目标集（1）原本保存的 position 用作恢复点。
      expect(eps[1].positionMs, 5000);
      // 第 1 集播一会儿后再切走，保存第 1 集进度。
      eps = updateEntryPosition(eps, 1, 9000);
      expect(eps[1].positionMs, 9000);
      // 回到第 0 集仍是 8000。
      expect(eps[0].positionMs, 8000);
    });

    test('越界 index 原样返回', () {
      expect(identical(updateEntryPosition(base, -1, 100), base), isTrue);
      expect(identical(updateEntryPosition(base, 3, 100), base), isTrue);
    });

    test('负 position clamp 到 0', () {
      final List<PlaylistEntry> next = updateEntryPosition(base, 2, -50);
      expect(next[2].positionMs, 0);
    });
  });

  group('playlist auto-advance and next-subtitle prewarm helpers', () {
    final List<PlaylistEntry> entries = <PlaylistEntry>[
      const PlaylistEntry(title: 'e0', path: '/video/e0.mkv'),
      const PlaylistEntry(title: 'e1', path: '/video/e1.mkv', positionMs: 7000),
      const PlaylistEntry(title: 'e2', path: '/video/e2.mkv'),
    ];

    test('completed on a non-last episode advances to the next index', () {
      expect(nextPlaylistIndexAfterCompletion(entries, 0), 1);
      expect(nextPlaylistIndexAfterCompletion(entries, 1), 2);
    });

    test('completed on the last episode or non-playlist does not advance', () {
      expect(nextPlaylistIndexAfterCompletion(entries, 2), isNull);
      expect(
        nextPlaylistIndexAfterCompletion(
          const <PlaylistEntry>[
            PlaylistEntry(title: 'only', path: '/only.mkv')
          ],
          0,
        ),
        isNull,
      );
      expect(nextPlaylistIndexAfterCompletion(entries, -1), isNull);
      expect(nextPlaylistIndexAfterCompletion(entries, 3), isNull);
    });

    test('next episode subtitle prewarm returns next path and dedupes it', () {
      expect(
        nextPlaylistPathToPrewarm(
          entries: entries,
          currentIndex: 0,
          lastPrewarmedPath: null,
        ),
        '/video/e1.mkv',
      );
      expect(
        nextPlaylistPathToPrewarm(
          entries: entries,
          currentIndex: 0,
          lastPrewarmedPath: '/video/e1.mkv',
        ),
        isNull,
      );
      expect(
        nextPlaylistPathToPrewarm(
          entries: entries,
          currentIndex: 2,
          lastPrewarmedPath: null,
        ),
        isNull,
      );
    });
  });

  group('playlistEpisodeCount（卡片角标/单视频区分用）', () {
    test('null / 空串 → 0（单视频）', () {
      expect(playlistEpisodeCount(null), 0);
      expect(playlistEpisodeCount(''), 0);
    });

    test('多集 JSON → 集数', () {
      const String json = '[{"title":"E1","path":"/a.mkv","positionMs":0},'
          '{"title":"E2","path":"/b.mkv","positionMs":0},'
          '{"title":"E3","path":"/c.mkv","positionMs":0}]';
      expect(playlistEpisodeCount(json), 3);
    });

    test('单元素列表 → 1（不算播放列表，<2）', () {
      expect(playlistEpisodeCount('[{"title":"E1","path":"/a.mkv"}]'), 1);
    });

    test('坏 JSON → 0（当单视频，不抛）', () {
      expect(playlistEpisodeCount('{not a list}'), 0);
      expect(playlistEpisodeCount('garbage'), 0);
    });
  });

  group('HLS master playlist（parseM3u8Master / isHlsMasterPlaylist）', () {
    const String masterSample = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,AVERAGE-BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",FRAME-RATE=29.970
720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
https://cdn.example.com/1080p/index.m3u8
''';

    // 无 STREAM-INF 的 media playlist（分段列表），不是 master。
    const String mediaSample = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:9.009,
seg0.ts
#EXTINF:9.009,
seg1.ts
#EXT-X-ENDLIST
''';

    test('解析 master：3 个 variant，属性 + 相对 URL 按 URL 语义解析', () {
      final List<HlsVariant> variants = parseM3u8Master(
        content: masterSample,
        baseUrl: 'https://host.example/hls/master.m3u8',
      );
      expect(variants.length, 3);

      expect(variants[0].bandwidth, 1280000);
      expect(variants[0].resolution, '640x360');
      // 引号感知：CODECS 内部逗号不被当属性分隔符。
      expect(variants[0].codecs, 'avc1.4d401e,mp4a.40.2');
      expect(variants[0].height, 360);
      expect(variants[0].width, 640);
      expect(variants[0].url, 'https://host.example/hls/360p/index.m3u8');

      // BANDWIDTH 优先于 AVERAGE-BANDWIDTH；FRAME-RATE 解析。
      expect(variants[1].bandwidth, 2560000);
      expect(variants[1].resolution, '1280x720');
      expect(variants[1].frameRate, closeTo(29.970, 0.001));
      expect(variants[1].url, 'https://host.example/hls/720p/index.m3u8');

      // 绝对 URL 原样保留（不再相对 master 解析）。
      expect(variants[2].bandwidth, 5000000);
      expect(variants[2].height, 1080);
      expect(variants[2].codecs, isNull);
      expect(variants[2].url, 'https://cdn.example.com/1080p/index.m3u8');
    });

    test('qualityLabel：分辨率 + 码率标注', () {
      const HlsVariant v = HlsVariant(
        url: 'x',
        bandwidth: 5000000,
        resolution: '1920x1080',
      );
      expect(v.qualityLabel, '1080p · 5.0 Mbps');
      const HlsVariant lowBitrate =
          HlsVariant(url: 'x', bandwidth: 800000, resolution: '640x360');
      expect(lowBitrate.qualityLabel, '360p · 800 kbps');
      const HlsVariant noRes = HlsVariant(url: 'x', bandwidth: 3000000);
      expect(noRes.qualityLabel, '3.0 Mbps');
      const HlsVariant bare = HlsVariant(url: 'x');
      expect(bare.qualityLabel, 'HLS');
    });

    test('sortedHlsVariantsByQualityDesc：高度降序（1080/720/360）', () {
      final List<HlsVariant> variants = parseM3u8Master(
        content: masterSample,
        baseUrl: 'https://host.example/hls/master.m3u8',
      );
      final List<HlsVariant> sorted = sortedHlsVariantsByQualityDesc(variants);
      expect(sorted.map((HlsVariant v) => v.height).toList(),
          <int?>[1080, 720, 360]);
      // 纯函数不改入参顺序。
      expect(variants[0].height, 360);
    });

    test('media playlist（EXTINF 分段）→ 非 master、variant 为空', () {
      expect(isHlsMasterPlaylist(mediaSample), isFalse);
      expect(
        parseM3u8Master(content: mediaSample, baseUrl: 'https://h/x.m3u8'),
        isEmpty,
      );
    });

    test('本地多集文件清单（parseM3u8 的输入）绝不被当作 HLS master', () {
      // 红线：TODO-1237 的分集清单只有 #EXTINF，无 STREAM-INF，不得误判为 HLS。
      expect(isHlsMasterPlaylist(_dragonMaidSample), isFalse);
      expect(
        parseM3u8Master(content: _dragonMaidSample, baseUrl: '/base'),
        isEmpty,
      );
      // 且 parseM3u8（本地清单解析）对真 HLS master 仍走文件路径语义、与 master
      // 解析互不干扰（isHlsMasterPlaylist 在上层做分流，这里只验两函数互不误伤）。
      expect(isHlsMasterPlaylist(masterSample), isTrue);
    });
  });
  // TODO-1237: m3u8 entry path resolution — backslash / absolute / relative /
  // UNC handled by string shape, host-independent (windows + posix contexts).
  // Backslashes are built via String.fromCharCode(0x5c) so the source carries
  // no literal backslash char (dodges shell/heredoc/tooling mangling).
  group('resolveM3uEntryPath (TODO-1237)', () {
    final p.Context win = p.Context(style: p.Style.windows);
    final p.Context pos = p.Context(style: p.Style.posix);
    final String bs = String.fromCharCode(0x5c);

    test('windows: absolute drive path (backslashes) used as-is, not joined',
        () {
      final String entry = 'D:${bs}video${bs}Bocchi${bs}S01E01.mp4';
      expect(
          resolveM3uEntryPath(entry, 'D:${bs}playlists', context: win), entry,
          reason: 'absolute entry must NOT be joined onto the m3u8 dir');
    });

    test('windows: absolute drive path (forward slashes) normalizes', () {
      expect(
          resolveM3uEntryPath('D:/video/Bocchi/E01.mp4', 'D:${bs}pl',
              context: win),
          'D:${bs}video${bs}Bocchi${bs}E01.mp4');
    });

    test('windows: relative backslash path resolves against the m3u8 dir', () {
      expect(
          resolveM3uEntryPath('Season 01${bs}E01.mp4', 'D:${bs}video${bs}pl',
              context: win),
          'D:${bs}video${bs}pl${bs}Season 01${bs}E01.mp4');
    });

    test('windows: relative forward-slash path resolves against the m3u8 dir',
        () {
      expect(
          resolveM3uEntryPath('Season 01/E01.mp4', 'D:${bs}video${bs}pl',
              context: win),
          'D:${bs}video${bs}pl${bs}Season 01${bs}E01.mp4');
    });

    test('windows: UNC path preserved, never turned into a drive path', () {
      final String unc = '$bs${bs}NAS${bs}share${bs}E01.mp4';
      expect(resolveM3uEntryPath(unc, 'D:${bs}pl', context: win), unc,
          reason: 'the old p.join turned UNC into a bogus D: drive path');
    });

    test('posix: absolute path used as-is', () {
      expect(resolveM3uEntryPath('/mnt/media/E01.mp4', '/base', context: pos),
          '/mnt/media/E01.mp4');
    });

    test('posix: relative path resolves against the m3u8 dir', () {
      expect(resolveM3uEntryPath('sub/E01.mp4', '/base', context: pos),
          '/base/sub/E01.mp4');
    });

    test('posix host: a Windows-absolute entry is still absolute (by shape)',
        () {
      // Cross-device sync / non-Windows CI: D:\... must not be joined onto the
      // posix m3u8 dir. Absoluteness is judged by string shape, not host
      // p.isAbsolute (which would call it relative on posix).
      final String entry = 'D:${bs}video${bs}E01.mp4';
      expect(resolveM3uEntryPath(entry, '/base', context: pos), entry);
    });

    test('empty / whitespace entry returns empty', () {
      expect(resolveM3uEntryPath('   ', '/base', context: pos), '');
    });

    // 网络（WebDAV）视频来源的清单：URL 基底按 URL 语义解析，不经 p.Context
    // （它会把 https:// 的双斜杠折叠掉）。宿主平台无关——windows context 也得
    // 给出同样的 URL。
    group('URL 基底（网络视频来源）', () {
      const String base = 'https://dav.example.com/media/Lists';

      test('相对明文条目：正斜杠 join + 段按需百分号编码', () {
        expect(resolveM3uEntryPath('clip 1.mkv', base, context: win),
            'https://dav.example.com/media/Lists/clip%201.mkv');
        expect(resolveM3uEntryPath('Show A/E01 (BD).mkv', base, context: pos),
            'https://dav.example.com/media/Lists/Show%20A/E01%20(BD).mkv');
      });

      test('已编码段不二次编码（%20 不变 %2520）', () {
        expect(resolveM3uEntryPath('Show%20A/ep%201.mkv', base, context: win),
            'https://dav.example.com/media/Lists/Show%20A/ep%201.mkv');
      });

      test('`..` 上跳但钳制在 scheme://host 之下', () {
        expect(resolveM3uEntryPath('../Show A/E01.mkv', base, context: win),
            'https://dav.example.com/media/Show%20A/E01.mkv');
        expect(resolveM3uEntryPath('../../../../E01.mkv', base, context: win),
            'https://dav.example.com/E01.mkv',
            reason: '越过 host 根的 .. 全部钳制');
      });

      test('绝对 http(s) 条目直通（不 join、不改写）——本地基底同样成立', () {
        const String url = 'https://cdn.example.com/hls/stream.m3u8';
        expect(resolveM3uEntryPath(url, base, context: win), url);
        expect(resolveM3uEntryPath(url, 'D:${bs}pl', context: win), url,
            reason: '此前 URL 条目被误判为相对路径 join 到本地目录上');
      });

      test('parseM3u8 对 URL 基底产出可播 URL + 解码标题回退', () {
        const String manifest = '#EXTM3U\nclip 1.mkv\n';
        final List<PlaylistEntry> entries =
            parseM3u8(content: manifest, baseDir: base);
        expect(entries.single.path,
            'https://dav.example.com/media/Lists/clip%201.mkv');
        expect(entries.single.title, 'clip 1.mkv',
            reason: '标题回退必须是解码后的文件名，不能带 %20');
      });
    });

    test('parseM3u8 routes an absolute entry through the resolver (not joined)',
        () {
      // Forward-slash absolute entry so the manifest carries no backslash; on
      // any host it must resolve to an absolute path WITHOUT the m3u8 dir.
      const String manifest = '''
#EXTM3U
#EXTINF:-1,Ep1
D:/video/Bocchi/S01E01.mp4
''';
      final List<PlaylistEntry> entries =
          parseM3u8(content: manifest, baseDir: 'D:${bs}playlists');
      expect(entries, hasLength(1));
      expect(entries.single.path.contains('playlists'), isFalse,
          reason: 'absolute entry must not be joined onto the m3u8 dir');
    });
  });

  // TODO-1346：视频卡观看进度分数。无持久化总时长 → 多集按「看到第几集」到集粒度，
  // 单视频仅「已看完」满格；无可展示进度返回 null（不画进度条）。
  group('videoWatchFraction (TODO-1346 视频卡观看进度)', () {
    test('多集按 currentEpisode/episodeCount 算，clamp 到 [0,1]', () {
      // K-ON! 现场值：第 47 集 / 共 59 集 ≈ 0.797。
      expect(
        videoWatchFraction(
            completed: false, currentEpisode: 47, episodeCount: 59),
        closeTo(47 / 59, 1e-9),
      );
      // currentEpisode 越界也不炸、绝不 >1。
      expect(
        videoWatchFraction(
            completed: false, currentEpisode: 999, episodeCount: 12),
        1.0,
      );
    });

    test('已看完（completed）恒满格，压过集数', () {
      expect(
        videoWatchFraction(
            completed: true, currentEpisode: 0, episodeCount: 12),
        1.0,
      );
      expect(
        videoWatchFraction(completed: true, currentEpisode: 3, episodeCount: 0),
        1.0,
      );
    });

    test('多集停在第一集(0)且未看完 → null（不画空条）', () {
      expect(
        videoWatchFraction(
            completed: false, currentEpisode: 0, episodeCount: 24),
        isNull,
      );
    });

    test('单视频/流（episodeCount<2）未看完 → null（无总时长不误导）', () {
      // 单视频起播中：有 lastPositionMs 但没时长可算 → 不画。
      expect(
        videoWatchFraction(
            completed: false, currentEpisode: 0, episodeCount: 0),
        isNull,
      );
      expect(
        videoWatchFraction(
            completed: false, currentEpisode: 0, episodeCount: 1),
        isNull,
      );
    });
  });
}
