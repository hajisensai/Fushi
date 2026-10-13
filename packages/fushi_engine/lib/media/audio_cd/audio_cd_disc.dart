/// 音频 CD（CDDA）的纯数据层：TOC 解析、目录形态判定、光盘身份、WAV 头。无 IO。
///
/// Windows 把音频 CD 的每条音轨显示成 `TrackNN.cda`——那是 44 字节的快捷方式，
/// **不含任何音频**，真正的音频只能按扇区从光驱读出（见
/// `windows_audio_cd_drive.dart`）；macOS 把它挂载成一组 `.aiff`，拔盘即消失。
/// 两种都不能直接入库，导入链路要先认出「这是一张音频 CD」，再抓成 FLAC 交给
/// 既有的扫描导入（BUG-3312）。
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

/// 抓轨失败（无盘、不是光驱、驱动拒读、弹盘、编码失败）。[message] 面向日志与提示。
class AudioCdException implements Exception {
  const AudioCdException(this.message);

  final String message;

  @override
  String toString() => 'AudioCdException: $message';
}

/// macOS cddafs 挂载点根上的目录表文件（音轨表的 plist）。
const String kMacCdTocFileName = '.TOC.plist';

/// 路径是否是 `.cda` 快捷方式（大小写不敏感）。
bool isCdaPath(String path) => p.extension(path).toLowerCase() == kCdaExtension;

/// 路径是否是 AIFF（macOS 把 CD 音轨挂载成 `N Audio Track.aiff`）。
bool isAiffPath(String path) {
  final String ext = p.extension(path).toLowerCase();
  return ext == '.aiff' || ext == '.aif';
}

/// 音频 CD 在文件系统里的两种样子。
enum AudioCdLayout {
  /// Windows 光驱根：只有 `TrackNN.cda` 快捷方式，音频要按扇区读（[parseCdromToc]）。
  windowsCda,

  /// macOS cddafs 挂载点：`.TOC.plist` + 每轨一个真实的 `.aiff`，拔盘即消失。
  macCddafs,
}

/// 一个目录的直接子文件名是不是一张音频 CD 的根；不是返回 null。
///
/// 只要有 AIFF 之外的可直接导入媒体（[isImportableMedia]）就不算：混合模式 /
/// 增强型 CD 的数据轨里带了真媒体，照常走原导入，不抢。AIFF 不在此列——它就是
/// cddafs 挂载点里的音轨本身；判据是旁边的 `.TOC.plist`。没有 `.TOC.plist` 的
/// AIFF 是普通音频文件：和 `.cda` 放在一起时同样按「旁边有真媒体」照常导入。
AudioCdLayout? audioCdLayoutOf(
  Iterable<String> fileNames, {
  required bool Function(String name) isImportableMedia,
}) {
  bool sawCda = false;
  bool sawAiff = false;
  bool sawToc = false;
  for (final String name in fileNames) {
    final bool aiff = isAiffPath(name);
    if (!aiff && isImportableMedia(name)) return null;
    sawCda = sawCda || isCdaPath(name);
    sawAiff = sawAiff || aiff;
    sawToc = sawToc || name == kMacCdTocFileName;
  }
  if (sawToc && sawAiff) return AudioCdLayout.macCddafs;
  if (sawCda && !sawAiff) return AudioCdLayout.windowsCda;
  return null;
}

/// macOS 挂载点的 AIFF 文件名按轨号排序：`2 Audio Track.aiff` 排在
/// `10 Audio Track.aiff` 前面（字符串排序会反过来）。轨号取文件名开头的数字，
/// 没有数字的按出现顺序接在后面编号。
List<({int number, String name})> macCdTracksOf(Iterable<String> fileNames) {
  final List<String> aiffs = fileNames.where(isAiffPath).toList();
  int? leading(String name) =>
      int.tryParse(RegExp(r'^\d+').firstMatch(name)?.group(0) ?? '');
  aiffs.sort((String a, String b) {
    final int? na = leading(a);
    final int? nb = leading(b);
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    if ((na == null) != (nb == null)) return na == null ? 1 : -1;
    return a.compareTo(b);
  });
  return <({int number, String name})>[
    for (int i = 0; i < aiffs.length; i++)
      (number: leading(aiffs[i]) ?? i + 1, name: aiffs[i]),
  ];
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

/// macOS 挂载点的光盘身份：每轨 AIFF 的轨号与字节数（= 扇区数的函数）派生，
/// 与 [audioCdDiscId] 同一用途。
String macCdDiscId(List<({int number, int bytes})> tracks) => fnv1a32Hex(
  <String>[
    for (final ({int number, int bytes}) t in tracks) '${t.number}:${t.bytes}',
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
