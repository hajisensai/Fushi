/// 音频 CD（CDDA）的纯数据层：TOC 解析、目录判定、光盘身份、WAV 头。无 IO。
///
/// Windows 把音频 CD 的每条音轨显示成 `TrackNN.cda`——那是 44 字节的快捷方式，
/// **不含任何音频**。真正的音频只能按扇区从光驱读出（见
/// `windows_audio_cd_drive.dart`），所以导入链路要先认出「这是一张音频 CD」，
/// 再抓轨成真实文件交给既有的扫描导入（BUG-3312）。
library;

import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show fnv1a32Hex;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// CD 快捷方式扩展名（Windows 资源管理器给音频轨生成的伪文件）。
const String kCdaExtension = '.cda';

/// 一个原始 CDDA 扇区：1/75 秒的 44.1 kHz / 16 bit / 立体声 PCM。
const int kCddaRawSectorBytes = 2352;

/// 每秒扇区数（MSF 的 F 进位）。
const int kCddaSectorsPerSecond = 75;

/// 增强型 CD：音频段末轨与后随数据段之间的 lead-out + lead-in 间隙扇区数。
const int kCddaSessionGapSectors = 11400;

/// 一条音频轨的扇区区间 `[startLba, endLba)`。
@immutable
class AudioCdTrack {
  const AudioCdTrack({
    required this.number,
    required this.startLba,
    required this.endLba,
  });

  final int number;
  final int startLba;
  final int endLba;

  int get sectorCount => endLba - startLba;

  Duration get duration => Duration(
    microseconds:
        sectorCount * Duration.microsecondsPerSecond ~/ kCddaSectorsPerSecond,
  );

  @override
  bool operator ==(Object other) =>
      other is AudioCdTrack &&
      other.number == number &&
      other.startLba == startLba &&
      other.endLba == endLba;

  @override
  int get hashCode => Object.hash(number, startLba, endLba);

  @override
  String toString() => 'AudioCdTrack($number, $startLba..$endLba)';
}

/// 路径是否是 `.cda` 快捷方式（大小写不敏感）。
bool isCdaPath(String path) => p.extension(path).toLowerCase() == kCdaExtension;

/// 一个目录的文件名清单是否就是一张音频 CD 的根：至少一条 `.cda`，
/// 且没有任何可直接导入的媒体文件（[isImportableMedia] 判定）。
///
/// 混合模式 / 增强型 CD 的数据轨里若带了真媒体文件，就照常走原导入，不抢。
bool isAudioCdListing(
  Iterable<String> fileNames, {
  required bool Function(String name) isImportableMedia,
}) {
  bool sawCda = false;
  for (final String name in fileNames) {
    if (isImportableMedia(name)) return false;
    sawCda = sawCda || isCdaPath(name);
  }
  return sawCda;
}

/// 解析 `IOCTL_CDROM_READ_TOC` 返回的 `CDROM_TOC`，只留音频轨。
///
/// 布局：`Length[2] FirstTrack LastTrack`，随后每条 8 字节 `TRACK_DATA`
/// （`Reserved, Control:4|Adr:4, TrackNumber, Reserved1, Address[4]=0,M,S,F`），
/// 最后一条是 lead-out（0xAA）。Control 的 bit 2 置位 = 数据轨。
/// 一张盘全是数据轨（无音频）时返回空表。
/// 音频轨紧接数据轨时（增强型 CD）末尾扣掉 [kCddaSessionGapSectors]。
List<AudioCdTrack> parseCdromToc(Uint8List raw) {
  if (raw.length < 4) {
    throw const FormatException('CDROM_TOC too short');
  }
  final int entryCount = raw[3] - raw[2] + 2; // 含 lead-out
  if (raw[3] < raw[2] || raw.length < 4 + entryCount * 8) {
    throw const FormatException('CDROM_TOC truncated');
  }
  final List<({int number, bool audio, int lba})> entries =
      <({int number, bool audio, int lba})>[
        for (int i = 0; i < entryCount; i++)
          (
            number: raw[4 + i * 8 + 2],
            // MSVC 位域自低位排：Control 是低 4 位、Adr 是高 4 位。
            audio: raw[4 + i * 8 + 1] & 0x04 == 0,
            lba: _msfToLba(
              raw[4 + i * 8 + 5],
              raw[4 + i * 8 + 6],
              raw[4 + i * 8 + 7],
            ),
          ),
      ];
  final List<AudioCdTrack> tracks = <AudioCdTrack>[];
  for (int i = 0; i + 1 < entries.length; i++) {
    if (!entries[i].audio) continue;
    final bool dataFollows = i + 2 < entries.length && !entries[i + 1].audio;
    tracks.add(
      AudioCdTrack(
        number: entries[i].number,
        startLba: entries[i].lba,
        endLba: entries[i + 1].lba - (dataFollows ? kCddaSessionGapSectors : 0),
      ),
    );
  }
  return tracks;
}

int _msfToLba(int m, int s, int f) =>
    (m * 60 + s) * kCddaSectorsPerSecond + f - 150;

/// 光盘身份：由音轨起止扇区派生，同一张盘重插得到同一个 id，
/// 抓轨目录因此可复用（已抓过的轨不重抓）。
String audioCdDiscId(List<AudioCdTrack> tracks) => fnv1a32Hex(
  <String>[
    for (final AudioCdTrack t in tracks)
      '${t.number}:${t.startLba}-${t.endLba}',
  ].join(',').codeUnits,
);

/// 第 [number] 轨的文件主名（不含扩展名）。
String audioCdTrackBaseName(int number) =>
    'Track ${number.toString().padLeft(2, '0')}';

/// CDDA PCM（44.1 kHz / 16 bit / 立体声）的 44 字节 WAV 头。
Uint8List cddaWavHeader(int dataBytes) {
  const int channels = 2;
  const int sampleRate = 44100;
  const int bitsPerSample = 16;
  const int blockAlign = channels * bitsPerSample ~/ 8;
  final ByteData h = ByteData(44);
  void ascii(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      h.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  h.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, channels, Endian.little);
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * blockAlign, Endian.little);
  h.setUint16(32, blockAlign, Endian.little);
  h.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  h.setUint32(40, dataBytes, Endian.little);
  return h.buffer.asUint8List();
}
