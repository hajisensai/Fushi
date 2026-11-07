import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/music_clip_source.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// 制卡截句子音频的源解析（反馈 jrT0LdK8ax：歌词页制卡把 `fushi-music-plugin://` 逻辑
/// 路径直接交给 ffmpeg，必然「sentence audio export failed」）。
void main() {
  MusicPlayItem pluginItem() => musicPluginPlayItem(
    'p',
    const MusicPluginTrack(id: 't', title: 'T', artists: []),
  );

  test('插件曲目：向插件取流，交给 ffmpeg 的是流 URL + 插件给的请求头，起点 0', () async {
    final List<String> asked = <String>[];
    final MusicClipSource s = await resolveMusicClipSource(
      pluginItem(),
      pluginResolver: (String path) async {
        asked.add(path);
        return const MusicPluginStream(
          url: 'https://cdn.example/t.flac',
          headers: <String, String>{'Referer': 'https://example/'},
        );
      },
    );
    expect(asked, <String>['fushi-music-plugin://p/t']);
    expect(s.inputPath, 'https://cdn.example/t.flac');
    expect(s.httpHeaders, <String, String>{'Referer': 'https://example/'});
    expect(s.fileOffsetMs, 0);
  });

  test('YouTube 内置音源曲目：交给 ffmpeg 的是 audio-only 流 + 回放头，起点 0', () async {
    final MusicClipSource s = await resolveMusicClipSource(
      const MusicPlayItem(
        trackUid: 'y',
        path: 'fushi-music-youtube://video/dQw4w9WgXcQ',
        title: 'Y',
      ),
      youtubeResolver: (String id) async => (
        url: 'https://rr1.googlevideo.com/videoplayback?id=$id',
        headers: <String, String>{'User-Agent': 'UA'},
        expiresAt: null,
      ),
    );
    expect(
      s.inputPath,
      'https://rr1.googlevideo.com/videoplayback?id=dQw4w9WgXcQ',
    );
    expect(s.httpHeaders, <String, String>{'User-Agent': 'UA'});
    expect(s.fileOffsetMs, 0);

    await expectLater(
      resolveMusicClipSource(
        const MusicPlayItem(
          trackUid: 'y',
          path: 'fushi-music-youtube://video/dQw4w9WgXcQ',
          title: 'Y',
        ),
        youtubeResolver: (String _) async =>
            throw const MusicPluginStreamUnavailable('private video'),
      ),
      throwsA(
        isA<MusicClipSourceUnavailable>().having(
          (MusicClipSourceUnavailable e) => e.message,
          'message',
          contains('private video'),
        ),
      ),
    );
  });

  test('插件取流失败：抛带原因的 MusicClipSourceUnavailable（不悄悄降级）', () async {
    await expectLater(
      resolveMusicClipSource(
        pluginItem(),
        pluginResolver: (String _) async =>
            throw const MusicPluginStreamUnavailable('该曲目只能试听片段'),
      ),
      throwsA(
        isA<MusicClipSourceUnavailable>().having(
          (MusicClipSourceUnavailable e) => e.message,
          'message',
          contains('该曲目只能试听片段'),
        ),
      ),
    );
  });

  test('本机文件原样交出；CUE 虚拟曲目带文件内起点', () async {
    const MusicPlayItem file = MusicPlayItem(
      trackUid: 'a',
      path: r'C:\music\a.flac',
      title: 'A',
    );
    final MusicClipSource a = await resolveMusicClipSource(file);
    expect(a.inputPath, r'C:\music\a.flac');
    expect(a.httpHeaders, isEmpty);
    expect(a.fileOffsetMs, 0);

    const MusicPlayItem cue = MusicPlayItem(
      trackUid: 'b',
      path: r'C:\music\album.flac',
      title: 'B',
      startMs: 183000,
      endMs: 400000,
    );
    final MusicClipSource b = await resolveMusicClipSource(cue);
    expect(b.inputPath, r'C:\music\album.flac');
    expect(b.fileOffsetMs, 183000);
  });

  test('ffmpeg 读不了的虚拟路径（音频 CD / 光盘章节）明确报不支持', () async {
    for (final String path in <String>[
      'cdda://',
      r'D:\BDMV\PLAYLIST\00001.mpls',
    ]) {
      await expectLater(
        resolveMusicClipSource(
          MusicPlayItem(trackUid: path, path: path, title: 'x', startMs: 0),
        ),
        throwsA(isA<MusicClipSourceUnavailable>()),
        reason: path,
      );
    }
  });

  test('Apple Music 整曲：resolver 统一判为 DRM 保护（调用方降级成纯文本卡），不交给 ffmpeg', () async {
    const String path = 'fushi-apple-music://song/1440857781';
    await expectLater(
      resolveMusicClipSource(
        const MusicPlayItem(trackUid: path, path: path, title: 'x'),
      ),
      throwsA(isA<MusicClipSourceProtected>()),
    );
  });
}
