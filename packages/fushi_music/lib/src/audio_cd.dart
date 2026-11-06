import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_music_library.dart';

/// 音频 CD 的帧率（1 帧 = 1/75 s = 588 个 44.1 kHz 样本）。
const int kAudioCdFramesPerSecond = 75;

/// CD-TEXT 字段（包类型，native/fushi_music/src/cd.rs `cdtext_field`）。
abstract final class AudioCdTextField {
  static const int title = 0x80;
  static const int performer = 0x81;
  static const int songwriter = 0x82;
  static const int composer = 0x83;
  static const int arranger = 0x84;
  static const int message = 0x85;
  static const int upcIsrc = 0x8E;
}

/// TOC 里的一轨。
final class AudioCdTrack {
  const AudioCdTrack({
    required this.number,
    required this.isData,
    required this.lba,
    required this.lengthFrames,
  });

  final int number;
  final bool isData;

  /// 起点 LBA（不含 150 帧前导间隙）。
  final int lba;

  /// 长度（帧）：到下一轨起点；音频部分的末轨不含 Enhanced CD 的 session 间隙。
  final int lengthFrames;

  /// 起点（毫秒，相对 LBA 0；四舍五入到毫秒）。
  int get startMs => (lba * 1000 / kAudioCdFramesPerSecond).round();

  int get durationMs => (lengthFrames * 1000 / kAudioCdFramesPerSecond).round();
}

/// 一条 CD-TEXT。
final class AudioCdTextEntry {
  const AudioCdTextEntry({
    required this.track,
    required this.field,
    required this.value,
  });

  /// 0 = 整张盘。
  final int track;
  final int field;
  final String value;
}

/// 一张音频 CD 的读取结果。
final class AudioCdInfo {
  const AudioCdInfo({
    required this.firstTrack,
    required this.lastTrack,
    required this.leadoutLba,
    required this.tracks,
    required this.cdText,
    this.discId,
    this.tocQuery,
  });

  final int firstTrack;
  final int lastTrack;
  final int leadoutLba;
  final List<AudioCdTrack> tracks;

  /// MusicBrainz Disc ID（28 字符）；没有音频轨时为 null。
  final String? discId;

  /// MusicBrainz ws/2 `toc=` 查询串（Disc ID 查不到时做模糊匹配）。
  final String? tocQuery;
  final List<AudioCdTextEntry> cdText;

  List<AudioCdTrack> get audioTracks => <AudioCdTrack>[
    for (final AudioCdTrack t in tracks)
      if (!t.isData) t,
  ];

  /// CD-TEXT 某轨（0 = 整张盘）的某字段；没有为 null。
  String? text(int track, int field) {
    for (final AudioCdTextEntry e in cdText) {
      if (e.track == track && e.field == field) return e.value;
    }
    return null;
  }

  String? get albumTitle => text(0, AudioCdTextField.title);
  String? get albumPerformer => text(0, AudioCdTextField.performer);
}

/// 读光驱失败（打不开 / 没有盘 / 不是音频 CD）。业务失败：给用户看原因、不当部署缺陷。
final class AudioCdReadException implements Exception {
  const AudioCdReadException(this.device, this.status);

  final String device;
  final int status;

  /// 本平台不支持读物理光驱（Android / iOS）。
  bool get unsupported => status == FfmStatus.unsupported;

  @override
  String toString() => 'AudioCdReadException($device, status $status)';
}

typedef _ListDrivesC = Int32 Function(Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _ListDrivesDart = int Function(Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _ReadC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ReadDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _FromRawC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _FromRawDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// [AudioCdReader] 线格式解码（cd.rs `encode_info`）。纯函数，单测直接喂字节。
AudioCdInfo decodeAudioCdInfo(Uint8List bytes) {
  final ByteData v = ByteData.sublistView(bytes);
  int at = 0;
  int u8() => v.getUint8(at++);
  int u32() {
    final int x = v.getUint32(at, Endian.little);
    at += 4;
    return x;
  }

  String str() {
    final int len = u32();
    final String s = utf8.decode(bytes.sublist(at, at + len));
    at += len;
    return s;
  }

  final int version = u32();
  if (version != 1) {
    throw FormatException('audio CD wire version $version, expected 1');
  }
  final int first = u8();
  final int last = u8();
  final int leadout = u32();
  final int trackCount = u32();
  final List<AudioCdTrack> tracks = <AudioCdTrack>[
    for (int i = 0; i < trackCount; i++)
      AudioCdTrack(
        number: u8(),
        isData: u8() != 0,
        lba: u32(),
        lengthFrames: u32(),
      ),
  ];
  final String discId = str();
  final String toc = str();
  final int textCount = u32();
  final List<AudioCdTextEntry> text = <AudioCdTextEntry>[
    for (int i = 0; i < textCount; i++)
      AudioCdTextEntry(track: u8(), field: u8(), value: str()),
  ];
  return AudioCdInfo(
    firstTrack: first,
    lastTrack: last,
    leadoutLba: leadout,
    tracks: tracks,
    discId: discId.isEmpty ? null : discId,
    tocQuery: toc.isEmpty ? null : toc,
    cdText: text,
  );
}

/// native/fushi_music 的音频 CD 域：列光驱、读 TOC / CD-TEXT（一次调用拿到整张盘，Disc ID 在
/// Rust 侧算好）。[read] 会阻塞到光驱转起来（数百毫秒），调用方放后台 isolate。
class AudioCdReader {
  AudioCdReader._(FushiMusic lib) : _lib = lib {
    try {
      _list = lib.library.lookupFunction<_ListDrivesC, _ListDrivesDart>(
        'ffm_cd_list_drives',
      );
      _read = lib.library.lookupFunction<_ReadC, _ReadDart>('ffm_cd_read');
      _fromRaw = lib.library.lookupFunction<_FromRawC, _FromRawDart>(
        'ffm_cd_info_from_raw',
      );
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('audio CD', e);
    }
  }

  final FushiMusic _lib;
  late final _ListDrivesDart _list;
  late final _ReadDart _read;
  late final _FromRawDart _fromRaw;

  static AudioCdReader? _instance;

  static AudioCdReader get instance =>
      _instance ??= AudioCdReader._(FushiMusic.instance);

  factory AudioCdReader.forLibrary(FushiMusic lib) => AudioCdReader._(lib);

  Uint8List _take(Pointer<Pointer<Uint8>> outPtr, Pointer<Size> outLen) {
    final int len = outLen.value;
    final Pointer<Uint8> bytes = outPtr.value;
    if (len == 0 || bytes == nullptr) return Uint8List(0);
    try {
      return Uint8List.fromList(bytes.asTypedListOutOfLine(len));
    } finally {
      _lib.freeBytes(bytes, len);
    }
  }

  /// 本机光驱（Windows `E:` / Linux `/dev/srN` / macOS 装着盘的 `/dev/rdiskN`）；移动端为空。
  List<String> listDrives() {
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      final int rc = _list(outPtr, outLen);
      if (rc != FfmStatus.ok) return const <String>[];
      final Uint8List bytes = _take(outPtr, outLen);
      final ByteData v = ByteData.sublistView(bytes);
      int at = 0;
      final int count = v.getUint32(0, Endian.little);
      at = 4;
      final List<String> out = <String>[];
      for (int i = 0; i < count; i++) {
        final int len = v.getUint32(at, Endian.little);
        at += 4;
        out.add(utf8.decode(bytes.sublist(at, at + len)));
        at += len;
      }
      return out;
    } finally {
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// 读 [device] 里的盘。失败抛 [AudioCdReadException]。
  AudioCdInfo read(String device) {
    final List<int> path = utf8.encode(device);
    final Pointer<Uint8> input = malloc<Uint8>(path.length);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      input.asTypedListOutOfLine(path.length).setAll(0, path);
      final int rc = _read(input, path.length, outPtr, outLen);
      if (rc != FfmStatus.ok) throw AudioCdReadException(device, rc);
      return decodeAudioCdInfo(_take(outPtr, outLen));
    } finally {
      malloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// MMC READ TOC 格式 0 / 格式 5 的原始响应 → 盘信息（不碰设备；测试与离线样本用）。
  /// TOC 不合法抛 [FormatException]。
  AudioCdInfo fromRaw(Uint8List toc, [Uint8List? cdText]) {
    final Uint8List text = cdText ?? Uint8List(0);
    final Pointer<Uint8> a = malloc<Uint8>(toc.isEmpty ? 1 : toc.length);
    final Pointer<Uint8> b = malloc<Uint8>(text.isEmpty ? 1 : text.length);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      a.asTypedListOutOfLine(toc.length).setAll(0, toc);
      b.asTypedListOutOfLine(text.length).setAll(0, text);
      final int rc = _fromRaw(a, toc.length, b, text.length, outPtr, outLen);
      if (rc != FfmStatus.ok) {
        throw FormatException('not a valid CD TOC (status $rc)');
      }
      return decodeAudioCdInfo(_take(outPtr, outLen));
    } finally {
      malloc.free(a);
      malloc.free(b);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }
}
