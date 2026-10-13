import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:path/path.dart' as p;

/// 按 `CDROM_TOC` 布局拼一份 TOC。[entries] 末项应是 lead-out（0xAA）。
Uint8List _toc(List<({int number, int control, int lba})> entries) {
  final Uint8List raw = Uint8List(4 + entries.length * 8);
  raw[2] = entries.first.number;
  raw[3] = entries[entries.length - 2].number;
  for (int i = 0; i < entries.length; i++) {
    final int msf = entries[i].lba + 150;
    final int o = 4 + i * 8;
    raw[o + 1] = 0x10 | entries[i].control; // Adr=1 在高 4 位，Control 在低 4 位
    raw[o + 2] = entries[i].number;
    raw[o + 5] = msf ~/ (75 * 60);
    raw[o + 6] = (msf ~/ 75) % 60;
    raw[o + 7] = msf % 75;
  }
  return raw;
}

void main() {
  group('parseCdromToc (BUG-3312)', () {
    test('pure audio disc: every track ends where the next begins', () {
      // 真机实测盘（E:\，12 轨）的前 3 轨 + lead-out 起点。
      final List<AudioCdTrack> tracks = parseCdromToc(
        _toc(<({int number, int control, int lba})>[
          (number: 1, control: 0, lba: 0),
          (number: 2, control: 0, lba: 17446),
          (number: 3, control: 0, lba: 36454),
          (number: 0xAA, control: 0, lba: 44675),
        ]),
      );
      expect(tracks, const <AudioCdTrack>[
        AudioCdTrack(number: 1, startLba: 0, endLba: 17446),
        AudioCdTrack(number: 2, startLba: 17446, endLba: 36454),
        AudioCdTrack(number: 3, startLba: 36454, endLba: 44675),
      ]);
      expect(tracks.first.duration.inMilliseconds, 232613);
    });

    test('enhanced CD: data track dropped, last audio track loses the gap', () {
      final List<AudioCdTrack> tracks = parseCdromToc(
        _toc(<({int number, int control, int lba})>[
          (number: 1, control: 0, lba: 0),
          (number: 2, control: 0, lba: 20000),
          (number: 3, control: 4, lba: 50000), // 数据轨：Control bit 2
          (number: 0xAA, control: 4, lba: 90000),
        ]),
      );
      expect(tracks.map((AudioCdTrack t) => t.number), <int>[1, 2]);
      expect(tracks.last.endLba, 50000 - kCddaSessionGapSectors);
    });

    test('Control lives in the low nibble, not the Adr nibble', () {
      // Adr=1 / Control=0（纯音频）字节是 0x10：若误读高 4 位会得到 1，
      // bit 2 仍为 0 判对；反过来 Adr=4 的音频轨（0x40）误读高 4 位就会错判成数据轨。
      final Uint8List raw = _toc(<({int number, int control, int lba})>[
        (number: 1, control: 0, lba: 0),
        (number: 0xAA, control: 0, lba: 1000),
      ]);
      raw[5] = 0x40;
      expect(parseCdromToc(raw), hasLength(1));
    });

    test('all-data disc yields no audio tracks', () {
      expect(
        parseCdromToc(
          _toc(<({int number, int control, int lba})>[
            (number: 1, control: 4, lba: 0),
            (number: 0xAA, control: 4, lba: 5000),
          ]),
        ),
        isEmpty,
      );
    });

    test('truncated TOC throws instead of reading past the buffer', () {
      final Uint8List raw = _toc(<({int number, int control, int lba})>[
        (number: 1, control: 0, lba: 0),
        (number: 2, control: 0, lba: 100),
        (number: 0xAA, control: 0, lba: 200),
      ]);
      expect(
        () => parseCdromToc(Uint8List.sublistView(raw, 0, 20)),
        throwsFormatException,
      );
      expect(() => parseCdromToc(Uint8List(2)), throwsFormatException);
    });
  });

  group('audioCdLayoutOf', () {
    // 与生产（audioCdLayoutOfDirectory）同一判据：视频库收的扩展名，含 .aiff / .aif。
    bool media(String name) =>
        kVideoLibraryMediaExtensions.contains(p.extension(name).toLowerCase());

    test('Windows: only .cda shortcuts', () {
      expect(
        audioCdLayoutOf(<String>[
          'Track01.cda',
          'TRACK02.CDA',
        ], isImportableMedia: media),
        AudioCdLayout.windowsCda,
      );
    });

    test('macOS cddafs mount: .TOC.plist plus AIFF tracks', () {
      expect(
        audioCdLayoutOf(<String>[
          '.TOC.plist',
          '1 Audio Track.aiff',
          '2 Audio Track.AIF',
        ], isImportableMedia: media),
        AudioCdLayout.macCddafs,
      );
      // 没有 .TOC.plist 的 AIFF 只是一个装着 AIFF 的普通文件夹，不是光盘。
      expect(
        audioCdLayoutOf(<String>[
          '1 Audio Track.aiff',
        ], isImportableMedia: media),
        isNull,
      );
    });

    test('any importable media wins: the folder imports as before', () {
      expect(
        audioCdLayoutOf(<String>[
          'Track01.cda',
          'a.flac',
        ], isImportableMedia: media),
        isNull,
      );
      // 普通 AIFF（没有 .TOC.plist）也是真媒体：和 .cda 放一起照常导入。
      expect(
        audioCdLayoutOf(<String>[
          'Track01.cda',
          'a.aiff',
        ], isImportableMedia: media),
        isNull,
      );
      expect(
        audioCdLayoutOf(<String>[
          '.TOC.plist',
          '1 Audio Track.aiff',
          'bonus.mp4',
        ], isImportableMedia: media),
        isNull,
      );
      expect(audioCdLayoutOf(<String>[], isImportableMedia: media), isNull);
    });
  });

  test('macOS tracks sort by track number, not by string', () {
    expect(
      macCdTracksOf(<String>[
        '.TOC.plist',
        '10 Audio Track.aiff',
        '2 Audio Track.aiff',
        '1 Audio Track.aiff',
      ]),
      <({int number, String name})>[
        (number: 1, name: '1 Audio Track.aiff'),
        (number: 2, name: '2 Audio Track.aiff'),
        (number: 10, name: '10 Audio Track.aiff'),
      ],
    );
    expect(
      macCdDiscId(<({int number, int bytes})>[(number: 1, bytes: 100)]),
      isNot(macCdDiscId(<({int number, int bytes})>[(number: 1, bytes: 101)])),
    );
  });

  test('disc id is stable per TOC and differs across discs', () {
    const List<AudioCdTrack> a = <AudioCdTrack>[
      AudioCdTrack(number: 1, startLba: 0, endLba: 17446),
    ];
    const List<AudioCdTrack> b = <AudioCdTrack>[
      AudioCdTrack(number: 1, startLba: 0, endLba: 17447),
    ];
    expect(audioCdDiscId(a), audioCdDiscId(<AudioCdTrack>[...a]));
    expect(audioCdDiscId(a), isNot(audioCdDiscId(b)));
    expect(audioCdTrackBaseName(3), 'Track 03');
  });

  test('WAV header describes 44.1 kHz / 16 bit / stereo PCM', () {
    const int data = 10 * kCddaRawSectorBytes;
    final ByteData h = ByteData.sublistView(cddaWavHeader(data));
    String ascii(int at) =>
        String.fromCharCodes(Uint8List.sublistView(h, at, at + 4));
    expect(h.lengthInBytes, 44);
    expect(ascii(0), 'RIFF');
    expect(h.getUint32(4, Endian.little), 36 + data);
    expect(ascii(8), 'WAVE');
    expect(h.getUint16(20, Endian.little), 1);
    expect(h.getUint16(22, Endian.little), 2);
    expect(h.getUint32(24, Endian.little), 44100);
    expect(h.getUint32(28, Endian.little), 44100 * 4);
    expect(h.getUint16(32, Endian.little), 4);
    expect(h.getUint16(34, Endian.little), 16);
    expect(ascii(36), 'data');
    expect(h.getUint32(40, Endian.little), data);
  });
}
