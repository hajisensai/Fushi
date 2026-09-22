import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_clip_info.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';

import 'bluray_fixture.dart';

void main() {
  group('parseBlurayPlaylist', () {
    test('读出片段序列与总时长', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 180000, // 4s
            outTimeTicks: 180000 + 45000 * 600, // 10 分钟
          ),
          FixturePlayItem(
            clipId: '00002',
            inTimeTicks: 90000,
            outTimeTicks: 90000 + 45000 * 300, // 5 分钟
          ),
        ],
      );

      final BlurayPlaylist? playlist = parseBlurayPlaylist(bytes, id: '00001');

      expect(playlist, isNotNull);
      expect(playlist!.clipIds, <String>['00001', '00002']);
      expect(playlist.clips.first.streamFileName, '00001.m2ts');
      expect(playlist.clips.first.clipInfoFileName, '00001.clpi');
      expect(playlist.duration, const Duration(minutes: 15));
      expect(playlist.playbackType, 1);
    });

    test('STN table 只读第一个 PlayItem，多段不会把轨重复堆一遍', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(clipId: '00001', inTimeTicks: 0, outTimeTicks: 45000),
          FixturePlayItem(clipId: '00002', inTimeTicks: 0, outTimeTicks: 45000),
          FixturePlayItem(clipId: '00003', inTimeTicks: 0, outTimeTicks: 45000),
        ],
        streams: const <FixtureStream>[
          FixtureStream.video(codingType: 0x1B, videoFormat: 6, frameRate: 1),
          FixtureStream.audio(codingType: 0x83, language: 'jpn'),
        ],
      );

      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      expect(playlist.clips, hasLength(3));
      expect(playlist.videoStreams, hasLength(1));
      expect(playlist.audioStreams, hasLength(1));
    });

    test('解出视频规格、音轨与字幕语言', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 0,
            outTimeTicks: 45000 * 60,
          ),
        ],
        streams: const <FixtureStream>[
          // video_format 6 = 1080p，frame_rate 1 = 23.976
          FixtureStream.video(codingType: 0x1B, videoFormat: 6, frameRate: 1),
          FixtureStream.audio(codingType: 0x83, language: 'jpn'),
          FixtureStream.audio(codingType: 0x81, language: 'eng'),
          FixtureStream.subtitle(codingType: 0x90, language: 'chi'),
          FixtureStream.subtitle(codingType: 0x90, language: 'jpn'),
        ],
      );

      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      final BlurayStream video = playlist.videoStreams.single;
      expect(video.codecName, 'H.264');
      expect(video.videoHeight, 1080);
      expect(video.isInterlaced, isFalse);
      expect(video.framesPerSecond, closeTo(23.976, 0.001));

      expect(
        playlist.audioStreams.map(
          (BlurayStream s) => '${s.codecName}/${s.languageCode}',
        ),
        <String>['TrueHD/jpn', 'AC-3/eng'],
      );
      expect(
        playlist.subtitleStreams.map((BlurayStream s) => s.languageCode),
        <String>['chi', 'jpn'],
      );
      expect(playlist.subtitleStreams.first.codecName, 'PGS');
    });

    test('1080i 与 480i 判成隔行', () {
      Uint8List withFormat(int format) => buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(clipId: '00001', inTimeTicks: 0, outTimeTicks: 45000),
        ],
        streams: <FixtureStream>[
          FixtureStream.video(
            codingType: 0x02,
            videoFormat: format,
            frameRate: 4,
          ),
        ],
      );

      final BlurayStream interlaced1080 = parseBlurayPlaylist(
        withFormat(4),
        id: 'x',
      )!.videoStreams.single;
      expect(interlaced1080.videoHeight, 1080);
      expect(interlaced1080.isInterlaced, isTrue);

      final BlurayStream progressive1080 = parseBlurayPlaylist(
        withFormat(6),
        id: 'x',
      )!.videoStreams.single;
      expect(progressive1080.isInterlaced, isFalse);
    });

    test('未识别的编码类型给十六进制原值，不猜', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(clipId: '00001', inTimeTicks: 0, outTimeTicks: 45000),
        ],
        streams: const <FixtureStream>[
          FixtureStream.video(codingType: 0x7F, videoFormat: 9, frameRate: 9),
        ],
      );

      final BlurayStream video = parseBlurayPlaylist(
        bytes,
        id: 'x',
      )!.videoStreams.single;
      expect(video.codecName, '0x7f');
      expect(video.videoHeight, isNull);
      expect(video.framesPerSecond, isNull);
    });

    test('跳过多角度块后仍能找到 STN table', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 0,
            outTimeTicks: 45000 * 120,
            angleCount: 4,
          ),
        ],
        streams: const <FixtureStream>[
          FixtureStream.video(codingType: 0x24, videoFormat: 8, frameRate: 2),
          FixtureStream.audio(codingType: 0x86, language: 'jpn'),
        ],
      );

      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      expect(playlist.videoStreams.single.codecName, 'HEVC');
      expect(playlist.videoStreams.single.videoHeight, 2160);
      expect(playlist.audioStreams.single.codecName, 'DTS-HD MA');
    });

    test('章节按播放列表时间轴换算，IN 不为零也对', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          // 第一段：IN=4s，长 10 分钟
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 45000 * 4,
            outTimeTicks: 45000 * 604,
          ),
          // 第二段：IN=100s，长 5 分钟
          FixturePlayItem(
            clipId: '00002',
            inTimeTicks: 45000 * 100,
            outTimeTicks: 45000 * 400,
          ),
        ],
        marks: const <FixtureMark>[
          // 第一段开头
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 4),
          // 第一段 +2 分钟
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 124),
          // 第二段 +1 分钟 → 全局 10 分钟 + 1 分钟
          FixtureMark(playItemIndex: 1, timestampTicks: 45000 * 160),
          // link point，不是章节
          FixtureMark(
            playItemIndex: 1,
            timestampTicks: 45000 * 200,
            markType: 0x02,
          ),
        ],
      );

      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      expect(playlist.chapters.map((BlurayChapter c) => c.start), <Duration>[
        Duration.zero,
        const Duration(minutes: 2),
        const Duration(minutes: 11),
      ]);
      expect(playlist.chapters.last.playItemIndex, 1);
    });

    test('落在片段区间外的标记被丢弃', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 45000 * 10,
            outTimeTicks: 45000 * 70,
          ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 5), // IN 之前
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 40),
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 900), // OUT 之后
          FixtureMark(playItemIndex: 7, timestampTicks: 45000 * 40), // 段号越界
        ],
      );

      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      expect(playlist.chapters, hasLength(1));
      expect(playlist.chapters.single.start, const Duration(seconds: 30));
    });

    test('不认识的 clip_codec_identifier 不整条判死（对齐 libbluray）', () {
      // 真盘上除 M2TS 外还见过 FMTS；这个字段不参与任何判断，拿它当幻数会让一条本
      // 可正常播放的播放列表整条作废。
      for (final String codec in <String>['FMTS', 'XXXX']) {
        final Uint8List bytes = buildMplsFixture(
          playItems: <FixturePlayItem>[
            FixturePlayItem(
              clipId: '00001',
              inTimeTicks: 0,
              outTimeTicks: 45000 * 60,
              codecId: codec,
            ),
          ],
        );
        final BlurayPlaylist? playlist = parseBlurayPlaylist(bytes, id: 'x');
        expect(playlist, isNotNull, reason: codec);
        expect(playlist!.duration, const Duration(minutes: 1));
      }
    });

    test('playback_type 原样读出', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(clipId: '00001', inTimeTicks: 0, outTimeTicks: 45000),
        ],
        playbackType: 3,
      );
      expect(parseBlurayPlaylist(bytes, id: 'x')!.playbackType, 3);
    });

    group('坏输入一律返回 null', () {
      test('幻数不对', () {
        final Uint8List bytes = buildMplsFixture(
          playItems: const <FixturePlayItem>[
            FixturePlayItem(
              clipId: '00001',
              inTimeTicks: 0,
              outTimeTicks: 45000,
            ),
          ],
          magic: 'MPLZ',
        );
        expect(parseBlurayPlaylist(bytes, id: 'x'), isNull);
      });

      test('空文件', () {
        expect(parseBlurayPlaylist(Uint8List(0), id: 'x'), isNull);
      });

      test('被截断', () {
        final Uint8List full = buildMplsFixture(
          playItems: const <FixturePlayItem>[
            FixturePlayItem(
              clipId: '00001',
              inTimeTicks: 0,
              outTimeTicks: 45000 * 60,
            ),
          ],
        );
        for (final int cut in <int>[0x30, 0x3C, full.length - 10]) {
          expect(
            parseBlurayPlaylist(Uint8List.sublistView(full, 0, cut), id: 'x'),
            isNull,
            reason: '截到 $cut 字节应判坏数据',
          );
        }
      });

      test('OUT 不大于 IN', () {
        final Uint8List bytes = buildMplsFixture(
          playItems: const <FixturePlayItem>[
            FixturePlayItem(
              clipId: '00001',
              inTimeTicks: 45000 * 10,
              outTimeTicks: 45000 * 10,
            ),
          ],
        );
        expect(parseBlurayPlaylist(bytes, id: 'x'), isNull);
      });
    });
  });

  group('parseBlurayClipTimebase', () {
    test('读第一个 STC 序列的呈现区间', () {
      final Uint8List bytes = buildClpiFixture(
        presentationStartTicks: 45000 * 4,
        presentationEndTicks: 45000 * 1804,
      );

      final BlurayClipTimebase timebase = parseBlurayClipTimebase(bytes)!;

      expect(timebase.presentationStartTicks, 45000 * 4);
      expect(timebase.presentationEndTicks, 45000 * 1804);
      expect(timebase.duration, const Duration(minutes: 30));
    });

    test('多 ATC/STC 时仍以第一个为准', () {
      final Uint8List bytes = buildClpiFixture(
        presentationStartTicks: 90000,
        presentationEndTicks: 90000 + 45000 * 60,
        atcSequences: 2,
        stcSequences: 2,
      );

      final BlurayClipTimebase timebase = parseBlurayClipTimebase(bytes)!;

      expect(timebase.presentationStartTicks, 90000);
      expect(timebase.duration, const Duration(minutes: 1));
    });

    test('幻数不对或被截断返回 null', () {
      expect(
        parseBlurayClipTimebase(
          buildClpiFixture(
            presentationStartTicks: 0,
            presentationEndTicks: 45000,
            magic: 'XXXX',
          ),
        ),
        isNull,
      );
      final Uint8List full = buildClpiFixture(
        presentationStartTicks: 0,
        presentationEndTicks: 45000,
      );
      expect(
        parseBlurayClipTimebase(Uint8List.sublistView(full, 0, 0x30)),
        isNull,
      );
    });
  });
}
