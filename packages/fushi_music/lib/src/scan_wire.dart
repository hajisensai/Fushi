import 'dart:convert';
import 'dart:typed_data';

/// 批次格式版本，与 native/fushi_music/src/wire.rs 的 `BATCH_FORMAT_VERSION` 一致。
const int kMusicScanBatchFormatVersion = 1;

/// 一条曲目署名。
final class MusicScanCredit {
  const MusicScanCredit({
    required this.role,
    required this.name,
    required this.artistUid,
  });

  /// `artist` / `album_artist` / `composer` / `lyricist` / `arranger`。
  final String role;
  final String name;
  final String artistUid;
}

/// 扫描记录（wire.rs 的 `Record`）。
sealed class MusicScanRecord {
  const MusicScanRecord(this.path);

  /// 音频文件路径（CUE 虚拟曲目是整轨文件的路径）。
  final String path;
}

/// 库里已有、（修改时刻, 大小）没变的文件：只说明「还在」，不带标签。
final class MusicScanUnchanged extends MusicScanRecord {
  const MusicScanUnchanged(super.path);
}

/// 这个文件 / 目录读不了（权限、坏文件）。
final class MusicScanError extends MusicScanRecord {
  const MusicScanError(super.path, this.message);

  final String message;
}

/// 一首曲目（普通文件或 CUE 虚拟曲目）。字段语义见 wire.rs 文件头。
final class MusicScannedTrack extends MusicScanRecord {
  const MusicScannedTrack({
    required String path,
    required this.trackUid,
    required this.cueStartMs,
    required this.cueEndMs,
    required this.durationMs,
    required this.codec,
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
    required this.bitrateKbps,
    required this.isLossless,
    required this.title,
    required this.titleSort,
    required this.artistCredit,
    required this.albumTitle,
    required this.albumTitleSort,
    required this.albumArtist,
    required this.albumUid,
    required this.discNo,
    required this.discTotal,
    required this.trackNo,
    required this.year,
    required this.releaseDate,
    required this.genre,
    required this.catalogNo,
    required this.rgTrackGain,
    required this.rgTrackPeak,
    required this.rgAlbumGain,
    required this.rgAlbumPeak,
    required this.mbRecordingId,
    required this.mbWorkId,
    required this.mbReleaseId,
    required this.mbReleaseGroupId,
    required this.fileMtimeMs,
    required this.fileSize,
    required this.hasEmbeddedCover,
    required this.folderCoverPath,
    required this.cueSheetPath,
    required this.credits,
  }) : super(path);

  final String trackUid;
  final int? cueStartMs;
  final int? cueEndMs;
  final int? durationMs;
  final String? codec;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final int? bitrateKbps;
  final bool isLossless;
  final String title;
  final String? titleSort;
  final String? artistCredit;
  final String? albumTitle;
  final String? albumTitleSort;
  final String? albumArtist;
  final String? albumUid;
  final int? discNo;
  final int? discTotal;
  final int? trackNo;
  final int? year;
  final String? releaseDate;
  final String? genre;
  final String? catalogNo;
  final double? rgTrackGain;
  final double? rgTrackPeak;
  final double? rgAlbumGain;
  final double? rgAlbumPeak;
  final String? mbRecordingId;
  final String? mbWorkId;
  final String? mbReleaseId;
  final String? mbReleaseGroupId;
  final int fileMtimeMs;
  final int fileSize;
  final bool hasEmbeddedCover;
  final String? folderCoverPath;
  final String? cueSheetPath;
  final List<MusicScanCredit> credits;
}

/// 一批扫描结果。[done] 为 true 时扫描已结束（本批仍可能带记录）。
final class MusicScanBatch {
  const MusicScanBatch({required this.done, required this.records});

  final bool done;
  final List<MusicScanRecord> records;
}

/// 批次字节格式不对（绑定与原生库版本不一致时会走到这里）。
final class MusicScanWireError extends FormatException {
  const MusicScanWireError(super.message);
}

class _Reader {
  _Reader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _pos = 0;

  bool get atEnd => _pos == _bytes.length;

  void _need(int n) {
    if (_pos + n > _bytes.length) {
      throw MusicScanWireError('truncated batch at byte $_pos (+$n)');
    }
  }

  int u8() {
    _need(1);
    return _bytes[_pos++];
  }

  int u32() {
    _need(4);
    final int v = _data.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int i64() {
    _need(8);
    final int v = _data.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double f64() {
    _need(8);
    final double v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  String _utf8(int n) {
    _need(n);
    final String s = utf8.decode(Uint8List.sublistView(_bytes, _pos, _pos + n));
    _pos += n;
    return s;
  }

  String str() => _utf8(u32());

  String? optStr() {
    final int n = u32();
    if (n == 0xFFFFFFFF) return null;
    return _utf8(n);
  }

  int? optI64() {
    final bool present = u8() != 0;
    final int v = i64();
    return present ? v : null;
  }

  double? optF64() {
    final bool present = u8() != 0;
    final double v = f64();
    return present ? v : null;
  }
}

/// 解码 `ffm_scan_next` 交回的批次字节。
MusicScanBatch decodeMusicScanBatch(Uint8List bytes) {
  final _Reader r = _Reader(bytes);
  final int version = r.u32();
  if (version != kMusicScanBatchFormatVersion) {
    throw MusicScanWireError(
      'batch format $version, bindings expect $kMusicScanBatchFormatVersion',
    );
  }
  final bool done = r.u8() != 0;
  final int count = r.u32();
  final List<MusicScanRecord> records = <MusicScanRecord>[];
  for (int i = 0; i < count; i++) {
    final int kind = r.u8();
    switch (kind) {
      case 0:
        records.add(_readTrack(r));
      case 1:
        records.add(MusicScanUnchanged(r.str()));
      case 2:
        records.add(MusicScanError(r.str(), r.str()));
      default:
        throw MusicScanWireError('unknown record kind $kind');
    }
  }
  if (!r.atEnd) throw const MusicScanWireError('trailing bytes after batch');
  return MusicScanBatch(done: done, records: records);
}

MusicScannedTrack _readTrack(_Reader r) {
  final String path = r.str();
  final String trackUid = r.str();
  final int? cueStartMs = r.optI64();
  final int? cueEndMs = r.optI64();
  final int? durationMs = r.optI64();
  final String? codec = r.optStr();
  final int? sampleRate = r.optI64();
  final int? bitDepth = r.optI64();
  final int? channels = r.optI64();
  final int? bitrateKbps = r.optI64();
  final bool isLossless = r.u8() != 0;
  final String title = r.str();
  final String? titleSort = r.optStr();
  final String? artistCredit = r.optStr();
  final String? albumTitle = r.optStr();
  final String? albumTitleSort = r.optStr();
  final String? albumArtist = r.optStr();
  final String? albumUid = r.optStr();
  final int? discNo = r.optI64();
  final int? discTotal = r.optI64();
  final int? trackNo = r.optI64();
  final int? year = r.optI64();
  final String? releaseDate = r.optStr();
  final String? genre = r.optStr();
  final String? catalogNo = r.optStr();
  final double? rgTrackGain = r.optF64();
  final double? rgTrackPeak = r.optF64();
  final double? rgAlbumGain = r.optF64();
  final double? rgAlbumPeak = r.optF64();
  final String? mbRecordingId = r.optStr();
  final String? mbWorkId = r.optStr();
  final String? mbReleaseId = r.optStr();
  final String? mbReleaseGroupId = r.optStr();
  final int fileMtimeMs = r.i64();
  final int fileSize = r.i64();
  final bool hasEmbeddedCover = r.u8() != 0;
  final String? folderCoverPath = r.optStr();
  final String? cueSheetPath = r.optStr();
  final int creditCount = r.u32();
  final List<MusicScanCredit> credits = <MusicScanCredit>[
    for (int i = 0; i < creditCount; i++)
      MusicScanCredit(role: r.str(), name: r.str(), artistUid: r.str()),
  ];
  return MusicScannedTrack(
    path: path,
    trackUid: trackUid,
    cueStartMs: cueStartMs,
    cueEndMs: cueEndMs,
    durationMs: durationMs,
    codec: codec,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    channels: channels,
    bitrateKbps: bitrateKbps,
    isLossless: isLossless,
    title: title,
    titleSort: titleSort,
    artistCredit: artistCredit,
    albumTitle: albumTitle,
    albumTitleSort: albumTitleSort,
    albumArtist: albumArtist,
    albumUid: albumUid,
    discNo: discNo,
    discTotal: discTotal,
    trackNo: trackNo,
    year: year,
    releaseDate: releaseDate,
    genre: genre,
    catalogNo: catalogNo,
    rgTrackGain: rgTrackGain,
    rgTrackPeak: rgTrackPeak,
    rgAlbumGain: rgAlbumGain,
    rgAlbumPeak: rgAlbumPeak,
    mbRecordingId: mbRecordingId,
    mbWorkId: mbWorkId,
    mbReleaseId: mbReleaseId,
    mbReleaseGroupId: mbReleaseGroupId,
    fileMtimeMs: fileMtimeMs,
    fileSize: fileSize,
    hasEmbeddedCover: hasEmbeddedCover,
    folderCoverPath: folderCoverPath,
    cueSheetPath: cueSheetPath,
    credits: credits,
  );
}

/// 库里已有文件（路径 → 修改时刻毫秒 + 大小）编码成 `ffm_scan_set_known` 的缓冲区。
Uint8List encodeMusicKnownFiles(Map<String, ({int mtimeMs, int size})> known) {
  final BytesBuilder out = BytesBuilder(copy: false);
  final ByteData head = ByteData(4)..setUint32(0, known.length, Endian.little);
  out.add(head.buffer.asUint8List());
  for (final MapEntry<String, ({int mtimeMs, int size})> e in known.entries) {
    final List<int> path = utf8.encode(e.key);
    final ByteData rec = ByteData(4)..setUint32(0, path.length, Endian.little);
    out.add(rec.buffer.asUint8List());
    out.add(path);
    final ByteData nums = ByteData(16)
      ..setInt64(0, e.value.mtimeMs, Endian.little)
      ..setInt64(8, e.value.size, Endian.little);
    out.add(nums.buffer.asUint8List());
  }
  return out.takeBytes();
}
