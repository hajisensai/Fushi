import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 支持「从 app 外用 Hibiki 打开」的视频扩展名（小写，不含点）。
///
/// 与 [VideoImportDialog] 的 `FileType.video` 大致对齐，覆盖常见容器格式。
/// libmpv（media_kit 底层）能解这些格式；不在表内的扩展名一律拒绝，避免把
/// 任意文件（如词典 zip、EPUB）误当视频打开。
const Set<String> _supportedVideoExtensions = <String>{
  'mkv',
  'mp4',
  'm4v',
  'avi',
  'webm',
  'mov',
  'ts',
  'm2ts',
  'mts',
  'flv',
  'wmv',
  'mpg',
  'mpeg',
  'ogv',
  '3gp',
};

/// 纯函数：判断 [path] 是否是受支持的视频文件（仅看扩展名，不碰文件系统）。
///
/// 大小写不敏感；无扩展名或扩展名不在白名单内返回 false。
bool isSupportedVideoFile(String path) {
  final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (ext.isEmpty) return false;
  return _supportedVideoExtensions.contains(ext);
}

/// 纯函数：归一化视频路径用于「同一物理文件」比对/派生唯一标识。
///
/// 统一分隔符（反斜杠转 `/`）、去掉冗余 `.`、`..` 段，保证 `D:/a/b.mkv` 与
/// `D:\a\b.mkv`、`D:/a/./c/../b.mkv` 归一到同一字符串。**不做大小写折叠**——
/// 与历史行为保持一致（Windows 盘符/路径大小写不一致仍视为不同，避免改动既有
/// uid 派生语义）。[externalVideoBookUid] 与 [VideoBookRepository.findByVideoPath]
/// 共用此单一真相，确保两侧归一语义完全一致（TODO-903）。
String normalizeVideoPath(String videoPath) =>
    p.normalize(videoPath).replaceAll('\\', '/');

/// 纯函数：从外部视频「绝对路径」派生稳定 bookUid：`video/ext/<sha1前12>`。
///
/// 用全路径的 sha1 前 12 位做唯一标识，保证同一文件每次打开命中同一条 VideoBook
/// （幂等复用，不会重复入库）。与导入对话框单视频的 `video/<basename>` 命名区分开
/// （前缀 `video/ext/`），避免外部打开与手动导入互相覆盖。
///
/// 路径先规范化（统一分隔符 / 去掉冗余 `.`、`..`），保证 `D:/a/b.mkv` 与
/// `D:\a\b.mkv` 派生同一 uid。
String externalVideoBookUid(String videoPath) {
  final String normalized = normalizeVideoPath(videoPath);
  final String digest =
      sha1.convert(utf8.encode(normalized)).toString().substring(0, 12);
  return 'video/ext/$digest';
}

/// 纯函数：从 Dart entrypoint 的命令行参数列表里挑出第一个受支持的视频路径。
///
/// Windows runner 经 `set_dart_entrypoint_arguments` 把 argv（去掉 binary 名）
/// 传进 `main(List<String> args)`。这里跳过以 `-` / `--` 开头的 flag（如调试器
/// 注入的参数），返回第一个看起来是视频文件的参数；没有则返回 null。
///
/// 注意：只做字符串判定，不验证文件是否真实存在（存在性检查留给调用方做 IO）。
String? firstExternalVideoArg(List<String> args) {
  for (final String arg in args) {
    if (arg.isEmpty) continue;
    if (arg.startsWith('-')) continue;
    if (isSupportedVideoFile(arg)) return arg;
  }
  return null;
}
