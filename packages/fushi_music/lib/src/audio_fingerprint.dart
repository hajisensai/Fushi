import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_music_library.dart';

/// 声纹内部采样率（chromaprint 固定值，native/fushi_music/src/fingerprint.rs
/// `SAMPLE_RATE`）。按它把音轨解成单声道 s16 交过来，Rust 侧就不必再重采样。
const int kAudioFingerprintSampleRate = 11025;

/// 一次对齐的结果（[AudioFingerprinter.align]）。needle 时间 t ↔ haystack 时间
/// `t + offset`。
final class AudioFingerprintMatch {
  const AudioFingerprintMatch({
    required this.offset,
    required this.haystackStart,
    required this.haystackEnd,
    required this.needleStart,
    required this.needleEnd,
    required this.startAtNeedleEdge,
    required this.endAtNeedleEdge,
    required this.meanBitError,
    required this.confidence,
    required this.matchedItems,
    required this.runItems,
  });

  /// needle 时间 0 在 haystack 里的位置（可负）。MV 偏移就是它；误差 ≤ 半个声纹项（≈ 62 ms）。
  final Duration offset;

  /// 命中段在 haystack 里的起止。
  final Duration haystackStart;
  final Duration haystackEnd;

  /// 命中段在 needle 里的起止。
  final Duration needleStart;
  final Duration needleEnd;

  /// 段首 / 段尾是否延伸到了 needle 的端点（true = 由偏移推出，精度同 [offset]；false =
  /// 端点落在 needle 中间，估计误差约 ±0.6 s）。
  final bool startAtNeedleEdge;
  final bool endAtNeedleEdge;

  /// 段内平均汉明距离（0..32，随机 ≈ 16）。
  final double meanBitError;

  /// 置信度 0..1。
  final double confidence;
  final int matchedItems;
  final int runItems;

  @override
  String toString() =>
      'AudioFingerprintMatch(offset: $offset, haystack: '
      '$haystackStart–$haystackEnd, needle: $needleStart–$needleEnd, '
      'edges: $startAtNeedleEdge/$endAtNeedleEdge, '
      'confidence: ${confidence.toStringAsFixed(3)})';
}

/// 声纹计算失败（采样率 / 声道非法）。业务层失败：调用方传错了格式。
final class AudioFingerprintFormatError implements Exception {
  const AudioFingerprintFormatError(this.status);

  final int status;

  @override
  String toString() => 'AudioFingerprintFormatError: status $status';
}

typedef _VersionC = Uint32 Function();
typedef _VersionDart = int Function();
typedef _ItemMsC = Double Function();
typedef _ItemMsDart = double Function();
typedef _ComputeC =
    Int32 Function(
      Pointer<Int16>,
      Size,
      Uint32,
      Uint32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ComputeDart =
    int Function(
      Pointer<Int16>,
      int,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _AlignC =
    Int32 Function(
      Pointer<Uint32>,
      Size,
      Pointer<Uint32>,
      Size,
      Uint32,
      Pointer<_FfmFpMatch>,
    );
typedef _AlignDart =
    int Function(
      Pointer<Uint32>,
      int,
      Pointer<Uint32>,
      int,
      int,
      Pointer<_FfmFpMatch>,
    );

typedef _EncodeC =
    Int32 Function(
      Pointer<Uint32>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _EncodeDart =
    int Function(Pointer<Uint32>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

/// 与 fingerprint.rs `FfmFpMatch` 同序同型（`#[repr(C)]`）。
final class _FfmFpMatch extends Struct {
  @Int64()
  external int offsetMs;
  @Int64()
  external int haystackStartMs;
  @Int64()
  external int haystackEndMs;
  @Int64()
  external int needleStartMs;
  @Int64()
  external int needleEndMs;
  @Double()
  external double meanBitError;
  @Double()
  external double confidence;
  @Uint32()
  external int matchedItems;
  @Uint32()
  external int runItems;
  @Uint8()
  external int found;
  @Uint8()
  external int edgeFlags;
}

/// native/fushi_music 的声纹域：整段 PCM → 声纹（[compute]）、声纹对齐（[align]）。
///
/// 两个调用都是**粗粒度**的：一集音轨一次 [compute]、一对声纹一次 [align]。24 分钟的
/// 一集 [compute] 在 release 库上约百毫秒级，调用方应放在后台 isolate（每个 isolate 各
/// 自 [instance] 一份绑定）。
class AudioFingerprinter {
  AudioFingerprinter._(FushiMusic lib) : _lib = lib {
    try {
      _version = lib.library.lookupFunction<_VersionC, _VersionDart>(
        'ffm_fp_version',
      );
      _itemMs = lib.library.lookupFunction<_ItemMsC, _ItemMsDart>(
        'ffm_fp_item_ms',
      );
      _compute = lib.library.lookupFunction<_ComputeC, _ComputeDart>(
        'ffm_fp_compute',
      );
      _align = lib.library.lookupFunction<_AlignC, _AlignDart>('ffm_fp_align');
      _encode = lib.library.lookupFunction<_EncodeC, _EncodeDart>(
        'ffm_fp_acoustid_encode',
      );
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('fingerprint', e);
    }
  }

  final FushiMusic _lib;
  late final _VersionDart _version;
  late final _ItemMsDart _itemMs;
  late final _ComputeDart _compute;
  late final _AlignDart _align;
  late final _EncodeDart _encode;

  static AudioFingerprinter? _instance;

  /// 按默认规则加载的绑定（每个 isolate 一份）。库缺失抛 [FushiMusicUnavailableError]。
  static AudioFingerprinter get instance =>
      _instance ??= AudioFingerprinter._(FushiMusic.instance);

  /// 显式库（测试 / harness）。
  factory AudioFingerprinter.forLibrary(FushiMusic lib) =>
      AudioFingerprinter._(lib);

  /// 声纹算法 / 对齐判据版本；缓存按它失效。
  int get version => _version();

  /// 一个声纹项的时长（毫秒）。
  double get itemMs => _itemMs();

  /// 交错 s16 PCM → 声纹（每项一个 32 位字）。
  Uint32List compute(
    Int16List pcm, {
    int sampleRate = kAudioFingerprintSampleRate,
    int channels = 1,
  }) {
    final Pointer<Int16> input = pcm.isEmpty
        ? nullptr
        : malloc<Int16>(pcm.length);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      if (pcm.isNotEmpty) input.asTypedListOutOfLine(pcm.length).setAll(0, pcm);
      final int rc = _compute(
        input,
        pcm.length,
        sampleRate,
        channels,
        outPtr,
        outLen,
      );
      if (rc != FfmStatus.ok) throw AudioFingerprintFormatError(rc);
      final int len = outLen.value;
      final Pointer<Uint8> bytes = outPtr.value;
      if (len == 0 || bytes == nullptr) return Uint32List(0);
      try {
        final Uint32List out = Uint32List(len ~/ 4);
        final ByteData view = ByteData.sublistView(
          bytes.asTypedListOutOfLine(len),
        );
        for (int i = 0; i < out.length; i++) {
          out[i] = view.getUint32(i * 4, Endian.little);
        }
        return out;
      } finally {
        _lib.freeBytes(bytes, len);
      }
    } finally {
      if (input != nullptr) malloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// 声纹 → AcoustID 查询串（chromaprint 压缩 + URL-safe base64，与 `fpcalc` 同形）。
  /// AcoustID 只收这个串与时长，PCM / 原始声纹不出本机。
  String acoustidEncode(Uint32List fingerprint) {
    final Pointer<Uint32> input = fingerprint.isEmpty
        ? nullptr
        : malloc<Uint32>(fingerprint.length);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      if (fingerprint.isNotEmpty) {
        input.asTypedListOutOfLine(fingerprint.length).setAll(0, fingerprint);
      }
      final int rc = _encode(input, fingerprint.length, outPtr, outLen);
      if (rc != FfmStatus.ok) throw AudioFingerprintFormatError(rc);
      final int len = outLen.value;
      final Pointer<Uint8> bytes = outPtr.value;
      if (len == 0 || bytes == nullptr) return '';
      try {
        return String.fromCharCodes(bytes.asTypedListOutOfLine(len));
      } finally {
        _lib.freeBytes(bytes, len);
      }
    } finally {
      if (input != nullptr) malloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// 读一个按 [kAudioFingerprintSampleRate] 单声道 s16le 解出的 raw PCM 文件并算声纹。
  /// 后台 isolate 里用：PCM（一集约 30 MB）不必跨 isolate 拷贝，只回传声纹。
  Uint32List computeRawPcmFile(String path) {
    final Uint8List bytes = File(path).readAsBytesSync();
    final int samples = bytes.lengthInBytes ~/ 2;
    final Int16List pcm = bytes.offsetInBytes.isEven
        ? bytes.buffer.asInt16List(bytes.offsetInBytes, samples)
        : Int16List.fromList(
            Uint8List.fromList(bytes).buffer.asInt16List(0, samples),
          );
    return compute(pcm);
  }

  /// [needle]（短：歌曲 / 本地音频）在 [haystack]（长：整集 / MV 音轨）上的最佳对齐。
  /// 命中时长低于 [minMatch] 视为没出现（返回 null）。
  AudioFingerprintMatch? align(
    Uint32List needle,
    Uint32List haystack, {
    Duration minMatch = const Duration(seconds: 10),
  }) {
    final Pointer<Uint32> n = needle.isEmpty
        ? nullptr
        : malloc<Uint32>(needle.length);
    final Pointer<Uint32> h = haystack.isEmpty
        ? nullptr
        : malloc<Uint32>(haystack.length);
    final Pointer<_FfmFpMatch> out = calloc<_FfmFpMatch>();
    try {
      if (needle.isNotEmpty)
        n.asTypedListOutOfLine(needle.length).setAll(0, needle);
      if (haystack.isNotEmpty) {
        h.asTypedListOutOfLine(haystack.length).setAll(0, haystack);
      }
      final int minItems = (minMatch.inMicroseconds / 1000 / itemMs).ceil();
      final int rc = _align(
        n,
        needle.length,
        h,
        haystack.length,
        minItems,
        out,
      );
      if (rc != FfmStatus.ok) throw AudioFingerprintFormatError(rc);
      final _FfmFpMatch m = out.ref;
      if (m.found == 0) return null;
      return AudioFingerprintMatch(
        offset: Duration(milliseconds: m.offsetMs),
        haystackStart: Duration(milliseconds: m.haystackStartMs),
        haystackEnd: Duration(milliseconds: m.haystackEndMs),
        needleStart: Duration(milliseconds: m.needleStartMs),
        needleEnd: Duration(milliseconds: m.needleEndMs),
        startAtNeedleEdge: m.edgeFlags & 1 != 0,
        endAtNeedleEdge: m.edgeFlags & 2 != 0,
        meanBitError: m.meanBitError,
        confidence: m.confidence,
        matchedItems: m.matchedItems,
        runItems: m.runItems,
      );
    } finally {
      if (n != nullptr) malloc.free(n);
      if (h != nullptr) malloc.free(h);
      calloc.free(out);
    }
  }
}
