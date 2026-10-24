import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 音频 CD 域经真原生库：MMC 原始 TOC → MusicBrainz Disc ID / 轨长（Rust 侧算），以及
/// （设了 `FUSHI_TEST_CD_DRIVE` 时）读本机光驱里的真盘。原生库是硬依赖：找不到判红，不 skip。

/// MMC READ TOC 格式 0 原始响应（LBA 地址）。
Uint8List _rawToc(
  int first,
  int last,
  List<(int, bool, int)> tracks,
  int leadout,
) {
  final BytesBuilder b = BytesBuilder()..add(<int>[0, 0, first, last]);
  for (final (int n, bool data, int lba) in <(int, bool, int)>[
    ...tracks,
    (0xAA, false, leadout),
  ]) {
    b.add(<int>[0, 0x10 | (data ? 0x04 : 0), n, 0]);
    b.add(Uint8List(4)..buffer.asByteData().setUint32(0, lba, Endian.big));
  }
  final Uint8List raw = b.takeBytes();
  raw.buffer.asByteData().setUint16(0, raw.length - 2, Endian.big);
  return raw;
}

void main() {
  final AudioCdReader reader = AudioCdReader.instance;

  test('MusicBrainz 文档样例盘：Disc ID 与 toc 查询串', () {
    const List<int> offsets = <int>[
      150, 9700, 25887, 39297, 53795, 63735, 77517, 94877, 107270, 123552, //
      135522, 148422, 161197, 174790, 192022, 205545, 218010, 228700, //
      239590, 255470, 266932, 288750,
    ];
    final AudioCdInfo info = reader.fromRaw(
      _rawToc(1, 22, <(int, bool, int)>[
        for (int i = 0; i < offsets.length; i++)
          (i + 1, false, offsets[i] - 150),
      ], 303602 - 150),
    );
    expect(info.discId, 'xUp1F2NkfP8s8jaeFn_Av3jNEI4-');
    expect(info.tocQuery, startsWith('1 22 303602 150 9700 '));
    expect(info.audioTracks, hasLength(22));
    // 第 1 轨 9550 帧 = 127.333 s。
    expect(info.tracks.first.durationMs, 127333);
    expect(info.cdText, isEmpty);
  });

  test('Enhanced CD：数据轨不算歌，末首歌不含 session 间隙', () {
    final AudioCdInfo info = reader.fromRaw(
      _rawToc(1, 3, const <(int, bool, int)>[
        (1, false, 0),
        (2, false, 20000),
        (3, true, 60000),
      ], 90000),
    );
    expect(info.audioTracks.map((AudioCdTrack t) => t.number), <int>[1, 2]);
    expect(info.tracks[1].lengthFrames, 60000 - 11400 - 20000);
  });

  test('坏 TOC 明确报错', () {
    expect(
      () => reader.fromRaw(Uint8List.fromList(<int>[0, 2, 1, 1])),
      throwsFormatException,
    );
  });

  final String? drive = Platform.environment['FUSHI_TEST_CD_DRIVE'];
  test(
    '读本机光驱里的音频 CD（只读 TOC / CD-TEXT）',
    () {
      expect(reader.listDrives(), contains(drive));
      final AudioCdInfo info = reader.read(drive!);
      expect(info.audioTracks, isNotEmpty);
      expect(info.discId, hasLength(28));
      // ignore: avoid_print
      print(
        'disc ${info.discId} toc=${info.tocQuery} '
        'tracks=${info.tracks.map((AudioCdTrack t) => '${t.number}:${t.lba}+${t.lengthFrames}${t.isData ? 'D' : ''}').join(' ')} '
        'cdtext=${info.cdText.map((AudioCdTextEntry e) => '${e.track}/${e.field.toRadixString(16)}=${e.value}').join(' | ')}',
      );
    },
    skip: drive == null
        ? 'set FUSHI_TEST_CD_DRIVE (e.g. E:) with an audio CD in it'
        : null,
  );

  test('不存在的设备：读失败（不是部署缺陷）', () {
    expect(
      () => reader.read(Platform.isWindows ? 'Q:' : '/dev/fushi-no-such-cd'),
      throwsA(isA<AudioCdReadException>()),
    );
  });
}
