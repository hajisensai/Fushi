/// 自动对齐改动过的字幕，原始字节留一份，好让用户随时找回。
///
/// 按**对齐后内容**的 sha256 建索引：落在媒体目录里的 sidecar 名字会变、会被搬走，
/// 内容不会。只要用户手上这份字幕还是当时写下去的那份，就能反查到原稿。
///
/// 放在 app 字幕目录下的隐藏子目录，不放媒体目录——那里任何 `.srt/.ass` 都会被
/// sidecar 发现当成另一条字幕。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_paths.dart';

const String _backupDirName = '.reference_sync_originals';

Future<Directory> _backupDir() async => Directory(
  p.join((await enginePaths.videoSubtitlesDirectory()).path, _backupDirName),
);

String _keyOf(Uint8List bytes) => sha256.convert(bytes).toString();

/// 记下「[aligned] 是由 [original] 对齐来的」。
Future<void> saveSubtitleAlignmentOriginal({
  required Uint8List original,
  required Uint8List aligned,
}) async {
  final Directory dir = await _backupDir();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  await File(
    p.join(dir.path, _keyOf(aligned)),
  ).writeAsBytes(original, flush: true);
}

/// [current] 若是自动对齐写下的那份，返回对齐前的原稿；否则 null。
Future<Uint8List?> findSubtitleAlignmentOriginal(Uint8List current) async {
  final File f = File(p.join((await _backupDir()).path, _keyOf(current)));
  return f.existsSync() ? f.readAsBytes() : null;
}

/// [path] 这份字幕文件是不是按内嵌轨对齐写下的产物（自动路径与播放页手动入口都经
/// [saveSubtitleAlignmentOriginal] 登记）。读不了 / 不存在 → false。
///
/// 播放页据此让调轴归零：对齐产物的时间轴已经贴着视频，系列级 / 本集的旧调轴是
/// 给没对齐的字幕调的，叠上去只会再推歪。
Future<bool> isSubtitleAlignmentProduct(String path) async {
  try {
    final File file = File(path);
    if (!file.existsSync()) return false;
    return await findSubtitleAlignmentOriginal(await file.readAsBytes()) !=
        null;
  } catch (_) {
    return false;
  }
}
