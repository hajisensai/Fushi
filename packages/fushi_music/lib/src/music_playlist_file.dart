import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_music_library.dart';
import 'scan_wire.dart';

typedef _ParseC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// 播放列表文件扩展名（小写，不带点）：与 native/fushi_music/src/playlist.rs 的
/// `PLAYLIST_EXTENSIONS` 一致。
const List<String> kMusicPlaylistFileExtensions = <String>['m3u', 'm3u8'];

class _PlaylistBindings {
  _PlaylistBindings(this._lib) {
    try {
      parse = _lib.library.lookupFunction<_ParseC, _ParseDart>(
        'ffm_playlist_parse',
      );
    } on ArgumentError catch (e) {
      throw _lib.missingSymbols('playlist', e);
    }
  }

  final FushiMusic _lib;
  late final _ParseDart parse;

  static _PlaylistBindings? _instance;
  static _PlaylistBindings get instance =>
      _instance ??= _PlaylistBindings(FushiMusic.instance);
}

Pointer<Uint8> _copyIn(Uint8List bytes, Allocator alloc) {
  final Pointer<Uint8> p = alloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
  return p;
}

/// 解析一份播放列表文件的原始字节（`.m3u` / `.m3u8`；编码判定、相对路径拼接都在 Rust）。
/// [baseDir] 是列表文件所在目录，相对条目按它拼成绝对路径；null 时相对条目原样交回。
/// 同步调用：列表文件很小，解析是纯文本处理，不碰文件系统。
MusicPlaylistFile parseMusicPlaylistFile(Uint8List bytes, {String? baseDir}) {
  final _PlaylistBindings b = _PlaylistBindings.instance;
  return using((Arena arena) {
    final Uint8List base = utf8.encode(baseDir ?? '');
    final Pointer<Pointer<Uint8>> outPtr = arena<Pointer<Uint8>>();
    final Pointer<Size> outLen = arena<Size>();
    final int rc = b.parse(
      _copyIn(bytes, arena),
      bytes.length,
      _copyIn(base, arena),
      base.length,
      outPtr,
      outLen,
    );
    if (rc != FfmStatus.ok) {
      throw MusicScanWireError('ffm_playlist_parse failed (status $rc)');
    }
    final int len = outLen.value;
    final Uint8List copy = Uint8List.fromList(
      outPtr.value.asTypedListOutOfLine(len),
    );
    b._lib.freeBytes(outPtr.value, len);
    return decodeMusicPlaylistFile(copy);
  });
}
