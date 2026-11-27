import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/utils/misc/safe_file_name.dart';

const int _maxScreenshotSourceRunes = 80;

/// Builds the default basename for a video screenshot.
///
/// [extension] 默认 `jpg`（[VideoPlayerController.screenshot] 的原始格式）；带字幕的
/// 截图要在 Dart 侧合成，产物恒为 PNG（`ui.Image.toByteData` 只出 png/rawRgba，且
/// PNG 不会在字幕描边周围留 JPEG 振铃），调用方传 `png`。
///
/// TODO-564: 旧名 `hibiki_<视频名>_at_<HHhMMmSSsmmm>_<YYYYMMDD_HHMMSS_mmm>.jpg`
/// 三段时间戳叠加（播放位置毫秒 + 截图墙钟日期/时分秒/毫秒）冗长难读。改成
/// 「视频名 + 播放时刻」更语义化：`<视频名>_<HH-MM-SS>.jpg`，时间取这一帧在视频里
/// 的播放位置（截图记录的本就是「视频的哪一刻」，比截图墙钟时间更有意义）。去掉
/// `hibiki_` 前缀（文件已落在用户选的目录 / 分享面板里，前缀只占长度无信息）。
///
/// 去重契约：同一视频同一播放秒连续两次截图会得到同名 → 完全由
/// [uniqueVideoScreenshotBaseName] / [uniqueVideoScreenshotPath] 的 ` (n)` 计数后缀
/// 保证唯一（临时目录 existsSync + 桌面保存路径两处都过这层），与旧实现一致。
///
/// The source segment keeps Unicode titles readable while replacing characters
/// that are invalid in common desktop file systems.
String videoScreenshotBaseName({
  required String? sourcePathOrTitle,
  required int positionMs,
  String extension = 'jpg',
}) {
  final String source = _safeScreenshotSourceStem(sourcePathOrTitle);
  return '${source}_${_playbackTimeToken(positionMs)}.$extension';
}

/// Returns [desiredName] or appends ` (n)` before the extension until a name
/// can be claimed.
///
/// [claim] 原子地「占下」一个名字：占到返回 true（名字从此归本次调用），已被占返回
/// false。真实实现是 `File.create(exclusive: true)`（[claimVideoScreenshotFile]）。
/// 不用「先判存在、再写」：判存在是异步的（BUG-5605：截图目录可以在网络盘上，同步
/// stat 会冻住 UI），连按两次截图时两次判定会在 await 之间交错，拿到同一个名字、
/// 后写的覆盖先写的。原子占名让两次调用各得一个名字。
Future<String> uniqueVideoScreenshotBaseName(
  String desiredName, {
  required FutureOr<bool> Function(String name) claim,
}) async {
  if (await claim(desiredName)) return desiredName;
  final String stem = p.basenameWithoutExtension(desiredName);
  final String ext = p.extension(desiredName);
  for (int counter = 2; counter < 10000; counter++) {
    final String candidate = '$stem ($counter)$ext';
    if (await claim(candidate)) return candidate;
  }
  final int fallback = DateTime.now().millisecondsSinceEpoch;
  return '${stem}_$fallback$ext';
}

/// Returns [desiredPath] or a sibling path with a count suffix, claimed via
/// [claim]（语义见 [uniqueVideoScreenshotBaseName]）.
Future<String> uniqueVideoScreenshotPath(
  String desiredPath, {
  required FutureOr<bool> Function(String path) claim,
}) async {
  final String dir = p.dirname(desiredPath);
  final String desiredName = p.basename(desiredPath);
  final String uniqueName = await uniqueVideoScreenshotBaseName(
    desiredName,
    claim: (String name) => claim(p.join(dir, name)),
  );
  return p.join(dir, uniqueName);
}

/// [uniqueVideoScreenshotBaseName] 的真实占名：以独占方式新建空文件 [path]。建成返回
/// true（调用方随后往里写字节）；同名已存在返回 false；其它错误（目录不可写等）照常
/// 抛出，由调用方报截图失败。异步，不在 UI isolate 上同步碰文件系统。
Future<bool> claimVideoScreenshotFile(String path) async {
  try {
    await File(path).create(exclusive: true);
    return true;
  } on PathExistsException {
    return false;
  }
}

String _safeScreenshotSourceStem(String? sourcePathOrTitle) {
  final String raw = (sourcePathOrTitle ?? '').trim();
  final String leaf = raw.isEmpty
      ? ''
      : p.posix.basename(raw.replaceAll(r'\', '/'));
  final String stem = p.posix.basenameWithoutExtension(leaf);
  // G1 收敛：黑名单替换走共享 helper（逐字符 → `_`），紧随的 `_+` 折叠使输出与
  // 旧手写 `[...]+ → _`（整段 → 单个 `_`）对全部输入逐字节一致。
  final String cleaned = safeWindowsFileName(stem)
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[_. ]+|[_. ]+$'), '');
  final String safe = _avoidReservedWindowsName(cleaned);
  final String fallback = safe.isEmpty ? 'video' : safe;
  return _takeRunes(fallback, _maxScreenshotSourceRunes);
}

String _avoidReservedWindowsName(String value) {
  const Set<String> reserved = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  return reserved.contains(value.toUpperCase()) ? '_$value' : value;
}

String _takeRunes(String value, int maxRunes) {
  final Runes runes = value.runes;
  if (runes.length <= maxRunes) return value;
  return String.fromCharCodes(runes.take(maxRunes));
}

String _playbackTimeToken(int positionMs) {
  final int safeMs = positionMs < 0 ? 0 : positionMs;
  final int hours = safeMs ~/ Duration.millisecondsPerHour;
  final int minutes =
      (safeMs % Duration.millisecondsPerHour) ~/ Duration.millisecondsPerMinute;
  final int seconds =
      (safeMs % Duration.millisecondsPerMinute) ~/
      Duration.millisecondsPerSecond;
  return '${_two(hours)}-${_two(minutes)}-${_two(seconds)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
