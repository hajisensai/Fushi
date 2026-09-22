import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/fmp4_rewriter.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';

/// 拼一个 MP4 box：`size(4) + type(4) + payload`。
Uint8List _box(String type, List<int> payload) {
  final int size = 8 + payload.length;
  final BytesBuilder builder = BytesBuilder()
    ..add(<int>[
      (size >> 24) & 0xff,
      (size >> 16) & 0xff,
      (size >> 8) & 0xff,
      size & 0xff,
    ])
    ..add(type.codeUnits)
    ..add(payload);
  return builder.toBytes();
}

List<int> _u32(int v) => <int>[
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

/// `tkhd` v0：version(1)+flags(3)+creation(4)+modification(4)+track_ID(4)+...
List<int> _tkhd(int trackId) => <int>[
  0, 0, 0, 0, // version 0 + flags
  ..._u32(0), // creation
  ..._u32(0), // modification
  ..._u32(trackId),
  ..._u32(0), // reserved
];

/// `mdhd` v0：version(1)+flags(3)+creation(4)+modification(4)+timescale(4)+duration(4)
List<int> _mdhd(int timescale) => <int>[
  0,
  0,
  0,
  0,
  ..._u32(0),
  ..._u32(0),
  ..._u32(timescale),
  ..._u32(0),
];

/// `tfdt` v0：version(1)+flags(3)+baseMediaDecodeTime(4)
List<int> _tfdt0(int base) => <int>[0, 0, 0, 0, ..._u32(base)];

/// `tfhd`：version(1)+flags(3)+track_ID(4)
List<int> _tfhd(int trackId) => <int>[0, 0, 0, 0, ..._u32(trackId)];

Uint8List _concat(List<Uint8List> parts) {
  final BytesBuilder builder = BytesBuilder();
  for (final Uint8List part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

/// 一个够用的 init 段：ftyp + moov(trak(tkhd,mdia(mdhd)) ×2)。
Uint8List _init({int videoTimescale = 15360, int audioTimescale = 44100}) {
  final Uint8List trak1 = _box('trak', <int>[
    ..._box('tkhd', _tkhd(1)),
    ..._box('mdia', <int>[..._box('mdhd', _mdhd(videoTimescale))]),
  ]);
  final Uint8List trak2 = _box('trak', <int>[
    ..._box('tkhd', _tkhd(2)),
    ..._box('mdia', <int>[..._box('mdhd', _mdhd(audioTimescale))]),
  ]);
  return _concat(<Uint8List>[
    _box('ftyp', <int>[1, 2, 3, 4]),
    _box('moov', <int>[...trak1, ...trak2]),
  ]);
}

/// init + 两个 fragment 的完整段（ffmpeg 的原始产物形状）。
Uint8List _fullSegment({int tfdt1 = 0, int tfdt2 = 0}) {
  final Uint8List moof = _box('moof', <int>[
    ..._box('traf', <int>[
      ..._box('tfhd', _tfhd(1)),
      ..._box('tfdt', _tfdt0(tfdt1)),
    ]),
    ..._box('traf', <int>[
      ..._box('tfhd', _tfhd(2)),
      ..._box('tfdt', _tfdt0(tfdt2)),
    ]),
  ]);
  return _concat(<Uint8List>[
    _init(),
    moof,
    _box('mdat', List<int>.filled(16, 7)),
  ]);
}

int _readTfdt(Uint8List data, int occurrence) {
  // 简易扫描：找第 occurrence 个 'tfdt'，读其后 4 字节 flags 再 4 字节值。
  int found = 0;
  for (int i = 0; i + 12 <= data.length; i++) {
    if (data[i] == 0x74 &&
        data[i + 1] == 0x66 &&
        data[i + 2] == 0x64 &&
        data[i + 3] == 0x74) {
      if (found == occurrence) {
        final ByteData view = ByteData.sublistView(data);
        return view.getUint32(i + 8);
      }
      found++;
    }
  }
  return -1;
}

void main() {
  group('VideoTranscodeProfile', () {
    test('两项都缺 / 非法 → null（= 不转码，走原文件直传）', () {
      expect(VideoTranscodeProfile.fromQuery(const <String, String>{}), isNull);
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxWidth': 'abc',
          'maxBitrate': '',
        }),
        isNull,
      );
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxWidth': '0',
          'maxBitrate': '0',
        }),
        isNull,
      );
    });

    test('单给一项也成立（只限宽度 / 只限码率）', () {
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxWidth': '1280',
        }),
        const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
      );
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxBitrate': '3000000',
        }),
        const VideoTranscodeProfile(maxWidth: 0, maxBitrate: 3000000),
      );
    });

    test('query 往返', () {
      const VideoTranscodeProfile profile = VideoTranscodeProfile(
        maxWidth: 1280,
        maxBitrate: 3000000,
      );
      expect(VideoTranscodeProfile.fromQuery(profile.toQuery()), profile);
    });
  });

  group('分段划分', () {
    test('不满一段的尾巴也算一段', () {
      expect(transcodeSegmentCount(0), 0);
      expect(transcodeSegmentCount(1), 1);
      expect(transcodeSegmentCount(6000), 1);
      expect(transcodeSegmentCount(6001), 2);
      expect(transcodeSegmentCount(18000), 3);
    });

    test('末段按真实时长收尾，不越过片尾', () {
      final ({Duration start, Duration end}) last = transcodeSegmentRange(
        2,
        15500,
      );
      expect(last.start, const Duration(seconds: 12));
      expect(last.end, const Duration(milliseconds: 15500));
    });
  });

  group('HLS playlist', () {
    test('VOD 头 + EXT-X-MAP + 每段 EXTINF + ENDLIST', () {
      final String playlist = buildTranscodeHlsPlaylist(
        durationMs: 15500,
        initUri: 'hlsinit.mp4?token=T',
        segmentUri: (int i) => '$kTranscodeSegmentPathSuffix?token=T&n=$i',
      );
      final List<String> lines = playlist
          .trim()
          .split('\n')
          .map((String l) => l.trim())
          .toList();
      expect(lines.first, '#EXTM3U');
      expect(lines, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      expect(lines, contains('#EXT-X-MAP:URI="hlsinit.mp4?token=T"'));
      expect(lines.last, '#EXT-X-ENDLIST');
      expect(
        lines
            .where((String l) => l.startsWith('$kTranscodeSegmentPathSuffix?'))
            .length,
        3,
      );
      // 末段 3.5 秒：EXTINF 必须是真实段长，播放器据此算总时长与 seek 落点。
      expect(lines, contains('#EXTINF:3.500000,'));
    });

    test('时长为 0 → 一个分段都不列（host 侧据此拒绝转码）', () {
      final String playlist = buildTranscodeHlsPlaylist(
        durationMs: 0,
        initUri: 'i',
        segmentUri: (int i) => 's$i',
      );
      expect(playlist, isNot(contains('#EXTINF')));
    });
  });

  group('ffmpeg 参数', () {
    test('-ss / -to 落在 -i 之前（输入 seek，别把跳过的部分也解码一遍）', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(
          maxWidth: 1280,
          maxBitrate: 3000000,
        ),
        start: const Duration(seconds: 12),
        end: const Duration(seconds: 18),
      );
      expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
      expect(args.indexOf('-to'), lessThan(args.indexOf('-i')));
      expect(args[args.indexOf('-ss') + 1], '12.000');
      expect(args[args.indexOf('-to') + 1], '18.000');
    });

    test('码率上限连带 maxrate/bufsize（单给 -b:v 箍不住瞬时码率）', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 0, maxBitrate: 800000),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(args[args.indexOf('-b:v') + 1], '800000');
      expect(args[args.indexOf('-maxrate') + 1], '800000');
      expect(args[args.indexOf('-bufsize') + 1], '1600000');
      expect(args, isNot(contains('-crf')));
      // 没给宽度上限就不该有 scale 滤镜（别白跑一遍缩放）。
      expect(args, isNot(contains('-vf')));
    });

    test('没有码率上限时走恒定质量', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 854, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(args, contains('-crf'));
      expect(args, isNot(contains('-b:v')));
    });

    test('scale 只缩不放、高度取偶（奇数边会被 libx264 直接拒绝）', () {
      expect(scaleFilterFor(1280), r'scale=min(1280\,iw):-2');
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(args[args.indexOf('-vf') + 1], r'scale=min(1280\,iw):-2');
    });

    test('字幕不进转码流；音轨可指定且越界不硬失败', () {
      final List<String> byDefault = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(byDefault, contains('-sn'));
      expect(byDefault, contains('0:a:0?'));
      final List<String> picked = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
        audioStreamIndex: 2,
      );
      expect(picked, contains('0:a:2?'));
    });

    test('输出是 fragmented MP4 到 stdout（随包 ffmpeg 没有 mpegts/hls muxer）', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(
        args[args.indexOf('-movflags') + 1],
        'frag_keyframe+empty_moov+default_base_moof',
      );
      expect(args[args.indexOf('-f') + 1], 'mp4');
      expect(args.last, 'pipe:1');
    });
  });

  group('fMP4 改写', () {
    test('初始化段切到 moov 结束', () {
      final Uint8List full = _fullSegment();
      final Uint8List? init = extractInitSegment(full);
      expect(init, isNotNull);
      expect(init!.length, _init().length);
      expect(String.fromCharCodes(init.sublist(4, 8)), 'ftyp');
    });

    test('分段剥掉 ftyp+moov，只留 moof/mdat', () {
      final Uint8List body = stripInitSegment(_fullSegment());
      expect(String.fromCharCodes(body.sublist(4, 8)), 'moof');
      expect(body.length, _fullSegment().length - _init().length);
    });

    test('没有 moov 的输入原样返回（进程被 kill 的截断产物）', () {
      final Uint8List partial = _box('ftyp', <int>[1, 2, 3, 4]);
      expect(stripInitSegment(partial), partial);
      expect(extractInitSegment(partial), isNull);
    });

    test('按 track 各自的 timescale 读取', () {
      expect(
        parseTrackTimescales(
          _init(videoTimescale: 15360, audioTimescale: 48000),
        ),
        <int, int>{1: 15360, 2: 48000},
      );
    });

    test('tfdt 按各自 timescale 平移到片中绝对位置', () {
      // 这是整条链路的命门：ffmpeg 的 fMP4 muxer 必然把每段的 tfdt 写成 0，不平移
      // 的话所有分段的时间戳都落在 0..段长 上互相重叠，播放器只认得第一段。
      final Uint8List body = stripInitSegment(_fullSegment());
      final Uint8List shifted = shiftFragmentDecodeTimes(
        body,
        timescales: const <int, int>{1: 15360, 2: 44100},
        offset: const Duration(seconds: 12),
      );
      expect(_readTfdt(shifted, 0), 12 * 15360);
      expect(_readTfdt(shifted, 1), 12 * 44100);
    });

    test('零偏移不动字节（第 0 段）', () {
      final Uint8List body = stripInitSegment(_fullSegment(tfdt1: 5, tfdt2: 7));
      final Uint8List same = shiftFragmentDecodeTimes(
        body,
        timescales: const <int, int>{1: 15360, 2: 44100},
        offset: Duration.zero,
      );
      expect(same, body);
    });

    test('未知 track 的 traf 原样放过，不写出大小对不上的 box', () {
      final Uint8List body = stripInitSegment(_fullSegment());
      final Uint8List shifted = shiftFragmentDecodeTimes(
        body,
        timescales: const <int, int>{1: 15360}, // 故意漏掉 track 2
        offset: const Duration(seconds: 6),
      );
      expect(shifted.length, body.length);
      expect(_readTfdt(shifted, 0), 6 * 15360);
      expect(_readTfdt(shifted, 1), 0);
    });
  });
}
