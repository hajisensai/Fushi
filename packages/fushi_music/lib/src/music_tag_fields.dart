import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_music_library.dart';

/// 「写回文件标签」白名单字段（native/fushi_music/src/tag_write.rs `FIELDS`）。
/// [wire] 即 FFI 线格式里的键名，**冻结**：改名 = 旧版本写不进 / 读不出。
enum MusicTagField {
  title('title'),
  artist('artist'),
  album('album'),
  albumArtist('album_artist'),
  date('date'),
  trackNo('track_no'),
  discNo('disc_no'),
  catalogNo('catalog_no'),
  mbRecordingId('mb_recording_id'),
  mbReleaseId('mb_release_id'),
  mbReleaseGroupId('mb_release_group_id'),
  mbWorkId('mb_work_id'),
  mbArtistId('mb_artist_id');

  const MusicTagField(this.wire);

  final String wire;

  static MusicTagField? fromWire(String wire) {
    for (final MusicTagField f in values) {
      if (f.wire == wire) return f;
    }
    return null;
  }
}

/// 读 / 写标签失败。[status] 是 `FfmStatus` 码：`badInput` = 文件读不了，
/// `invalidArgument` = 字段值非法（文件没动），`writeFailed` = 写盘失败。
final class MusicTagWriteException implements Exception {
  const MusicTagWriteException(this.path, this.status);

  final String path;
  final int status;

  @override
  String toString() => 'MusicTagWriteException($path): status $status';
}

typedef _ReadC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ReadDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _WriteC = Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef _WriteDart = int Function(Pointer<Uint8>, int, Pointer<Uint8>, int);

/// `u32 count | (str key | str value)*count`，`str := u32 len | utf8`（小端）。
Uint8List encodeMusicTagFields(Map<MusicTagField, String> fields) {
  final BytesBuilder b = BytesBuilder(copy: false);
  final ByteData head = ByteData(4)..setUint32(0, fields.length, Endian.little);
  b.add(head.buffer.asUint8List());
  void str(String s) {
    final List<int> bytes = utf8.encode(s);
    b.add(
      (ByteData(
        4,
      )..setUint32(0, bytes.length, Endian.little)).buffer.asUint8List(),
    );
    b.add(bytes);
  }

  for (final MapEntry<MusicTagField, String> e in fields.entries) {
    str(e.key.wire);
    str(e.value);
  }
  return b.takeBytes();
}

/// [encodeMusicTagFields] 的逆。不认识的键丢掉（新版本库多给的字段不让旧绑定崩）。
Map<MusicTagField, String> decodeMusicTagFields(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);
  int pos = 0;
  String str() {
    final int len = view.getUint32(pos, Endian.little);
    pos += 4;
    final String s = utf8.decode(bytes.sublist(pos, pos + len));
    pos += len;
    return s;
  }

  final int count = view.getUint32(0, Endian.little);
  pos = 4;
  final Map<MusicTagField, String> out = <MusicTagField, String>{};
  for (int i = 0; i < count; i++) {
    final String key = str();
    final String value = str();
    final MusicTagField? f = MusicTagField.fromWire(key);
    if (f != null) out[f] = value;
  }
  return out;
}

/// native/fushi_music 的标签读写域。两个调用都是**同步**的文件 IO（一次几毫秒），调用方
/// 放后台 isolate（每个 isolate 各自 [instance] 一份绑定）。
class MusicTagFieldsIo {
  MusicTagFieldsIo._(FushiMusic lib) : _lib = lib {
    try {
      _read = lib.library.lookupFunction<_ReadC, _ReadDart>(
        'ffm_tags_read_fields',
      );
      _write = lib.library.lookupFunction<_WriteC, _WriteDart>(
        'ffm_tags_write_fields',
      );
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('tag-write', e);
    }
  }

  final FushiMusic _lib;
  late final _ReadDart _read;
  late final _WriteDart _write;

  static MusicTagFieldsIo? _instance;

  /// 按默认规则加载的绑定。库缺失抛 [FushiMusicUnavailableError]。
  static MusicTagFieldsIo get instance =>
      _instance ??= MusicTagFieldsIo._(FushiMusic.instance);

  /// 显式库（测试 / harness）。
  factory MusicTagFieldsIo.forLibrary(FushiMusic lib) =>
      MusicTagFieldsIo._(lib);

  /// 读出文件主标签的白名单字段（没有的字段不出现）。
  Map<MusicTagField, String> read(String path) {
    final Uint8List p = utf8.encode(path);
    final Pointer<Uint8> pathPtr = malloc<Uint8>(p.isEmpty ? 1 : p.length);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      pathPtr.asTypedListOutOfLine(p.length).setAll(0, p);
      final int rc = _read(pathPtr, p.length, outPtr, outLen);
      if (rc != FfmStatus.ok) throw MusicTagWriteException(path, rc);
      final int len = outLen.value;
      final Pointer<Uint8> bytes = outPtr.value;
      if (len == 0 || bytes == nullptr) return <MusicTagField, String>{};
      try {
        return decodeMusicTagFields(
          Uint8List.fromList(bytes.asTypedListOutOfLine(len)),
        );
      } finally {
        _lib.freeBytes(bytes, len);
      }
    } finally {
      malloc.free(pathPtr);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// 把 [fields] 写进文件主标签（值为空串 = 删除该字段）。整组先校验再动文件。
  void write(String path, Map<MusicTagField, String> fields) {
    final Uint8List p = utf8.encode(path);
    final Uint8List kv = encodeMusicTagFields(fields);
    final Pointer<Uint8> pathPtr = malloc<Uint8>(p.isEmpty ? 1 : p.length);
    final Pointer<Uint8> kvPtr = malloc<Uint8>(kv.isEmpty ? 1 : kv.length);
    try {
      pathPtr.asTypedListOutOfLine(p.length).setAll(0, p);
      kvPtr.asTypedListOutOfLine(kv.length).setAll(0, kv);
      final int rc = _write(pathPtr, p.length, kvPtr, kv.length);
      if (rc != FfmStatus.ok) throw MusicTagWriteException(path, rc);
    } finally {
      malloc.free(pathPtr);
      malloc.free(kvPtr);
    }
  }
}
