import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_music_library.dart';
import 'scan_wire.dart';

/// 一首在库曲目的专辑归属证据（native/fushi_music/src/album_merge.rs `Member`）：
/// [albumTitle] 是它当前所属专辑行的标题，[albumArtist] 是这首曲目**自己的**专辑艺人
/// 标签（署名表 `album_artist`）。
typedef MusicAlbumMember = ({
  String trackUid,
  String albumUid,
  String path,
  String albumTitle,
  String? albumArtist,
});

/// 要并成一张专辑的一组曲目（`Merge`）：[trackUids] 含已经挂在 [albumUid] 上的。
typedef MusicAlbumMerge = ({
  String albumUid,
  String title,
  String? albumArtist,
  List<String> trackUids,
});

typedef _PlanC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _PlanDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

class _AlbumMergeBindings {
  _AlbumMergeBindings(this._lib) {
    try {
      plan = _lib.library.lookupFunction<_PlanC, _PlanDart>(
        'ffm_album_merge_plan',
      );
    } on ArgumentError catch (e) {
      throw _lib.missingSymbols('album-merge', e);
    }
  }

  final FushiMusic _lib;
  late final _PlanDart plan;

  static _AlbumMergeBindings? _instance;
  static _AlbumMergeBindings get instance =>
      _instance ??= _AlbumMergeBindings(FushiMusic.instance);
}

/// `u32 count | (str track_uid | str album_uid | str path | str album_title |
/// opt_str album_artist)*count`（小端，`str := u32 len | utf8`，`opt_str` 的 None 是
/// `u32::MAX`）。
Uint8List encodeMusicAlbumMembers(List<MusicAlbumMember> members) {
  final BytesBuilder b = BytesBuilder(copy: false);
  void u32(int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void str(String s) {
    final List<int> bytes = utf8.encode(s);
    u32(bytes.length);
    b.add(bytes);
  }

  u32(members.length);
  for (final MusicAlbumMember m in members) {
    str(m.trackUid);
    str(m.albumUid);
    str(m.path);
    str(m.albumTitle);
    if (m.albumArtist == null) {
      u32(0xFFFFFFFF);
    } else {
      str(m.albumArtist!);
    }
  }
  return b.takeBytes();
}

/// `u32 count | (str album_uid | str title | opt_str album_artist | u32 n |
/// str track_uid*n)*count`。
List<MusicAlbumMerge> decodeMusicAlbumMerges(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  int pos = 0;
  int u32() {
    if (pos + 4 > bytes.length) {
      throw MusicScanWireError('truncated album merge plan at byte $pos');
    }
    final int v = data.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  String utf8Of(int n) {
    if (pos + n > bytes.length) {
      throw MusicScanWireError('truncated album merge plan at byte $pos');
    }
    final String s = utf8.decode(Uint8List.sublistView(bytes, pos, pos + n));
    pos += n;
    return s;
  }

  String str() => utf8Of(u32());
  String? optStr() {
    final int n = u32();
    return n == 0xFFFFFFFF ? null : utf8Of(n);
  }

  final int count = u32();
  final List<MusicAlbumMerge> out = <MusicAlbumMerge>[];
  for (int i = 0; i < count; i++) {
    final String albumUid = str();
    final String title = str();
    final String? albumArtist = optStr();
    final int n = u32();
    out.add((
      albumUid: albumUid,
      title: title,
      albumArtist: albumArtist,
      trackUids: <String>[for (int j = 0; j < n; j++) str()],
    ));
  }
  if (pos != bytes.length) {
    throw MusicScanWireError('trailing bytes in album merge plan at $pos');
  }
  return out;
}

Pointer<Uint8> _copyIn(Uint8List bytes, Allocator alloc) {
  final Pointer<Uint8> p = alloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
  return p;
}

/// 专辑对齐方案（判据见 native/fushi_music/src/album_merge.rs 模块文档）：同一目录里
/// 专辑名只差标点 / 宽度 / 大小写、专辑艺人缺省或一致的曲目并成一张，合并后的 uid 由
/// Rust 按组的规范标签派生。同步纯计算（一个来源几千首也是毫秒级），调用方在扫描收尾
/// 调用。库缺失抛 [FushiMusicUnavailableError]。
List<MusicAlbumMerge> planMusicAlbumMerges(List<MusicAlbumMember> members) {
  if (members.isEmpty) return const <MusicAlbumMerge>[];
  final _AlbumMergeBindings b = _AlbumMergeBindings.instance;
  return using((Arena arena) {
    final Uint8List input = encodeMusicAlbumMembers(members);
    final Pointer<Pointer<Uint8>> outPtr = arena<Pointer<Uint8>>();
    final Pointer<Size> outLen = arena<Size>();
    final int rc = b.plan(_copyIn(input, arena), input.length, outPtr, outLen);
    if (rc != FfmStatus.ok) {
      throw MusicScanWireError('ffm_album_merge_plan failed (status $rc)');
    }
    final int len = outLen.value;
    final Uint8List copy = Uint8List.fromList(
      outPtr.value.asTypedListOutOfLine(len),
    );
    b._lib.freeBytes(outPtr.value, len);
    return decodeMusicAlbumMerges(copy);
  });
}
