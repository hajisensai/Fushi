/// 有声书「内容版本」：host 上这本书的音频或字幕一变，值就变；其余（标题、封面、
/// 断点、调轴、对齐健康度）变了不算。
///
/// 两个消费者，同一个值：
/// - 互联有声书清单的 `RemoteAudiobookInfo.contentRevision`：client 记下下载时的
///   值，之后清单里的值不同 = host 上换过内容，提示「有更新」；
/// - host 的导出包缓存（`ExportPackageCache.obtain` 的 `version`）：缓存的包只在
///   版本相同时命中，换过内容的书下一次普通下载就重新打包，不必等 15 分钟 TTL。
///
/// 从已有数据推导，不落库、不加列：DB 里的路径（音频清单、对齐 / 字幕路径）加上这些
/// 文件的大小与修改时刻。所有改内容的写入路径（服务端库根重扫、app 换字幕 / 换音频、
/// 对端推送的有声书包）都会改其中至少一项，所以不需要每条写入路径各自通知谁。
///
/// 已知不覆盖：只改 DB 里 cue 而不碰字幕文件与音频的写入（目前没有这样的路径）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/sync/sync_asset_package_service.dart'
    show resolveAudiobookAudioFiles;

/// 一本有声书此刻的「音频是否完好」与「内容版本」，一次磁盘遍历同时得出。
typedef AudiobookContentState = ({bool hasAudio, String revision});

/// 算 [srtBook]（EPUB 有声书再加它的 [audiobook] 行）的 [AudiobookContentState]。
///
/// `hasAudio` 与 `audiobookAudioIsIntact` 同一判据（BUG-2551）：EPUB 有声书看
/// `audiobooks` 行的音频，独立字幕书看 `srt_books` 行的音频；至少一个文件且全部在盘上。
///
/// `revision` 是 `r1-` 加 32 位十六进制（SHA-256 前 16 字节），纯 ASCII。
Future<AudiobookContentState> audiobookContentState({
  required AudiobookRow? audiobook,
  required SrtBookRow srtBook,
}) async {
  final StringBuffer sig = StringBuffer('audiobook-content-v1\n');

  Future<bool> addAudio(String label, String? json, String? root) async {
    final List<String> paths = await resolveAudiobookAudioFiles(
      audioPathsJson: json,
      audioRoot: root,
    );
    sig.writeln('$label ${paths.length}');
    bool intact = paths.isNotEmpty;
    for (final String path in paths) {
      final String stat = await _fileSignature(path);
      if (stat == _missing) intact = false;
      sig.writeln('$path\t$stat');
    }
    return intact;
  }

  bool hasAudio;
  if (audiobook != null) {
    hasAudio = await addAudio(
      'audiobook-audio',
      audiobook.audioPathsJson,
      audiobook.audioRoot,
    );
    sig
      ..writeln('alignment ${audiobook.alignmentFormat}')
      ..writeln(
        '${audiobook.alignmentPath}\t'
        '${await _fileSignature(audiobook.alignmentPath)}',
      );
    // 配对 SrtBook 的音频也进包（`exportAudioDatabasePackage` 两行都读）。
    await addAudio('srt-audio', srtBook.audioPathsJson, srtBook.audioRoot);
  } else {
    hasAudio = await addAudio(
      'srt-audio',
      srtBook.audioPathsJson,
      srtBook.audioRoot,
    );
  }
  sig.writeln(
    'srt ${srtBook.srtPath}\t${await _fileSignature(srtBook.srtPath)}',
  );
  // 逐 token 时间 sidecar 跟着字幕进包（BUG-3248），换了也算换字幕。
  if (srtBook.srtPath.isNotEmpty) {
    final String sidecar = p.setExtension(srtBook.srtPath, '.tokens.jsonl');
    sig.writeln('tokens\t${await _fileSignature(sidecar)}');
  }

  final List<int> digest = sha256.convert(utf8.encode(sig.toString())).bytes;
  final StringBuffer hex = StringBuffer('r1-');
  for (int i = 0; i < 16; i++) {
    hex.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return (hasAudio: hasAudio, revision: hex.toString());
}

const String _missing = '-';

/// `<size>:<mtimeMs>`；不存在 / stat 失败为 [_missing]。
Future<String> _fileSignature(String path) async {
  if (path.isEmpty) return _missing;
  try {
    final FileStat stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file) return _missing;
    return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  } on FileSystemException {
    return _missing;
  }
}
