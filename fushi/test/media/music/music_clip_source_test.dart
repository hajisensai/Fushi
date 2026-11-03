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
}
