import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_stage_plan.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:image/image.dart' as img;

/// 卡拉 OK 字幕页（音乐 P3）的纯判据：默认叠加（特效检测 × 设置项）、`sub-delay` 符号、
/// 画布比例、mpv 指令形状、CD+G / UltraStar / `.kar` 配对。真 libmpv 上的逐帧一致与
/// `\k` `\kf` `\ko` 擦色语义见 `music_karaoke_stage_real_test.dart`。
void main() {
  group('默认叠加', () {
    MusicKaraokeOverlay pick({
      bool raw = true,
      bool effects = false,
      bool timeline = true,
      MusicAssRenderPreference pref = MusicAssRenderPreference.auto,
      MusicKaraokePicture picture = MusicKaraokePicture.canvas,
    }) => musicKaraokeDefaultOverlay(
      hasRawAss: raw,
      hasEffects: effects,
      hasTimeline: timeline,
      preference: pref,
      picture: picture,
    );

    test('自动：带特效走原样，纯 \\k 走结构化', () {
      expect(pick(effects: true), MusicKaraokeOverlay.original);
      expect(pick(), MusicKaraokeOverlay.structured);
    });

    test('设置项「总是 …」压过特效检测', () {
      expect(
        pick(pref: MusicAssRenderPreference.original),
        MusicKaraokeOverlay.original,
      );
      expect(
        pick(effects: true, pref: MusicAssRenderPreference.structured),
        MusicKaraokeOverlay.structured,
      );
    });

    test('没有 ASS 原文：有时间轴走结构化，否则关闭', () {
      expect(
        pick(
          raw: false,
          effects: true,
          pref: MusicAssRenderPreference.original,
        ),
        MusicKaraokeOverlay.structured,
      );
      expect(pick(raw: false, timeline: false), MusicKaraokeOverlay.off);
    });

    test('CD+G 画面自带歌词：默认不叠', () {
      expect(
        pick(effects: true, picture: MusicKaraokePicture.cdg),
        MusicKaraokeOverlay.off,
      );
    });

    test('可选叠加只列出有料的', () {
      expect(
        musicKaraokeAvailableOverlays(hasRawAss: false, hasTimeline: true),
        <MusicKaraokeOverlay>[
          MusicKaraokeOverlay.structured,
          MusicKaraokeOverlay.off,
        ],
      );
      expect(
        musicKaraokeAvailableOverlays(hasRawAss: true, hasTimeline: true),
        MusicKaraokeOverlay.values,
      );
    });

    test('偏好值往返，未知值回落自动', () {
      for (final MusicAssRenderPreference p
          in MusicAssRenderPreference.values) {
        expect(MusicAssRenderPreference.fromPref(p.prefValue), p);
      }
      expect(
        MusicAssRenderPreference.fromPref('bogus'),
        MusicAssRenderPreference.auto,
      );
      expect(
        MusicAssRenderPreference.fromPref(null),
        MusicAssRenderPreference.auto,
      );
    });
  });

  group('时间轴', () {
    test('sub-delay = MV 偏移 − 歌词偏移', () {
      // MV 有 2 s 前奏：脚本 10 s 的事件在 MV 12 s 出现。
      expect(
        musicKaraokeSubDelaySeconds(mvOffsetMs: 2000, lyricsOffsetMs: 0),
        2,
      );
      // 歌词提前 300 ms（正偏移）：事件提前 0.3 s 出现。
      expect(
        musicKaraokeSubDelaySeconds(lyricsOffsetMs: 300),
        closeTo(-0.3, 1e-9),
      );
      expect(
        musicKaraokeSubDelaySeconds(mvOffsetMs: 1500, lyricsOffsetMs: -250),
        closeTo(1.75, 1e-9),
      );
    });
  });

  group('mpv 指令', () {
    test('原样渲染打开 libass 且不改写 ASS 样式', () {
      final Map<String, String> on = musicKaraokeSubtitleProperties(
        visible: true,
      );
      expect(on['sub-ass'], 'yes');
      expect(on['sub-visibility'], 'yes');
      expect(on['sub-ass-override'], 'no');
      expect(on['sub-auto'], 'no');
      expect(
        musicKaraokeSubtitleProperties(visible: false)['sub-visibility'],
        'no',
      );
    });

    test('画布按封面轨挂、CD+G 按视频轨挂、ASS 选中', () {
      expect(musicKaraokeCanvasCommand('c.png'), <String>[
        'video-add',
        'c.png',
        'select',
        'canvas',
        'und',
        'yes',
      ]);
      expect(musicKaraokeCdgCommand('s.cdg'), <String>[
        'video-add',
        's.cdg',
        'select',
      ]);
      expect(musicKaraokeAssCommand('k.ass'), <String>[
        'sub-add',
        'k.ass',
        'select',
      ]);
    });
  });

  group('画布', () {
    test('比例取 PlayRes，高 720、宽偶数；没有 ASS 时 16:9', () {
      expect(musicKaraokeCanvasSize(playResX: 1920, playResY: 1080), (
        width: 1280,
        height: 720,
      ));
      expect(musicKaraokeCanvasSize(playResX: 384, playResY: 288), (
        width: 960,
        height: 720,
      ));
      expect(musicKaraokeCanvasSize(playResX: 1000, playResY: 720), (
        width: 1000,
        height: 720,
      ));
      expect(musicKaraokeCanvasSize(), (width: 1280, height: 720));
    });

    test('封面 contain 居中在纯色底上；坏封面只出纯色', () {
      final img.Image cover = img.Image(width: 100, height: 100)
        ..clear(img.ColorRgb8(255, 0, 0));
      final Uint8List png = renderMusicKaraokeCanvasPng(
        width: 320,
        height: 180,
        coverBytes: img.encodePng(cover),
      );
      final img.Image out = img.decodePng(png)!;
      expect((out.width, out.height), (320, 180));
      final img.Pixel center = out.getPixel(160, 90);
      expect((center.r, center.g, center.b), (255, 0, 0));
      final img.Pixel side = out.getPixel(5, 90);
      expect((side.r, side.g, side.b), (0x10, 0x10, 0x10));

      final img.Image plain = img.decodePng(
        renderMusicKaraokeCanvasPng(
          width: 64,
          height: 36,
          coverBytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      )!;
      final img.Pixel p = plain.getPixel(32, 18);
      expect((p.r, p.g, p.b), (0x10, 0x10, 0x10));
    });

    test('缓存文件按内容哈希命名', () {
      final String a = musicKaraokeCacheFile('d', <int>[1, 2], 'ass');
      expect(a, startsWith('d${Platform.pathSeparator}'));
      expect(a, endsWith('.ass'));
      expect(musicKaraokeCacheFile('d', <int>[1, 2], 'ass'), a);
      expect(musicKaraokeCacheFile('d', <int>[1, 3], 'ass'), isNot(a));
    });
  });

  group('配对', () {
    test('CD+G：同主名 .cdg（大小写不敏感）', () {
      expect(
        pickCdgCompanion('/k/Song.mp3', <String>['/k/song.CDG', '/k/x.cdg']),
        '/k/song.CDG',
      );
      expect(pickCdgCompanion('/k/Song.mp3', <String>['/k/Song2.cdg']), isNull);
      expect(pickCdgCompanion('/k/Song.cdg', <String>['/k/Song.cdg']), isNull);
    });

    test('UltraStar：#MP3 / #AUDIO 指向的文件名（#AUDIO 优先）', () {
      expect(
        ultraStarAudioReference(
          '#TITLE:Yoru\r\n#ARTIST:A\r\n#MP3:sub/Yoru.mp3\r\n#BPM:300\r\n: 0 4 60 夜\n',
        ),
        'Yoru.mp3',
      );
      expect(
        ultraStarAudioReference('#AUDIO:new.ogg\n#MP3:old.mp3\n#BPM:120\n'),
        'new.ogg',
      );
      // 没有 #BPM 不是 UltraStar。
      expect(ultraStarAudioReference('#MP3:a.mp3\nhello'), isNull);
      // 头部之后的行不算。
      expect(
        ultraStarAudioReference('#BPM:120\n: 0 4 60 a\n#MP3:late.mp3\n'),
        isNull,
      );
    });

    test('UltraStar 候选：主名不同的 .txt', () {
      expect(
        ultraStarCandidates('/u/Yoru.mp3', <String>[
          '/u/Artist - Yoru.txt',
          '/u/Yoru.txt',
          '/u/cover.jpg',
        ]),
        <String>['/u/Artist - Yoru.txt'],
      );
    });

    test('.kar / .mid sidecar 排在逐字格式之后、LRC 之前', () {
      expect(
        pickLyricSidecars('/m/a.mp3', <String>[
          '/m/a.lrc',
          '/m/a.kar',
        ]).primary!.ext,
        'kar',
      );
      expect(
        pickLyricSidecars('/m/a.mp3', <String>[
          '/m/a.krc',
          '/m/a.mid',
        ]).primary!.ext,
        'krc',
      );
    });
  });
}
