import 'dart:io';

import 'package:path/path.dart' as p;

/// sidecar 字幕优先级：日文外挂优先（这是日语查词要用的字幕）。
///
/// `.ja.srt` > `.ja.ass` > `.srt` > `.ass`。
const List<String> _sidecarSuffixPriority = <String>[
  '.ja.srt',
  '.ja.ass',
  '.srt',
  '.ass',
];

/// 纯函数：给「去掉视频扩展名的 basename」与「同目录文件名列表」，按优先级挑出
/// 第一个匹配的 sidecar 字幕文件名；无则返回 null。
///
/// 匹配规则：候选文件名（不区分大小写比较）等于 `<videoBaseNameNoExt><suffix>`，
/// 其中 suffix 取自 [_sidecarSuffixPriority]。返回的是 [dirFiles] 中的原始文件名
/// （保留原始大小写），便于调用方直接拼回目录得到绝对路径。
///
/// 抽成纯函数是为可测：不碰文件系统，只做字符串优先级匹配。
String? pickSidecar(String videoBaseNameNoExt, List<String> dirFiles) {
  final String baseLower = videoBaseNameNoExt.toLowerCase();
  for (final String suffix in _sidecarSuffixPriority) {
    final String wantLower = '$baseLower$suffix';
    for (final String name in dirFiles) {
      if (name.toLowerCase() == wantLower) {
        return name;
      }
    }
  }
  return null;
}

/// 在 [videoPath] 同目录查找同名 sidecar 字幕（IO 版，包装 [pickSidecar]）。
///
/// 返回第一个存在的字幕绝对路径（优先级见 [_sidecarSuffixPriority]），无则 null。
/// 目录不存在 / 读取失败时静默返回 null。
String? findSidecarSubtitle(String videoPath) {
  final String dir = p.dirname(videoPath);
  final String baseNameNoExt = p.basenameWithoutExtension(videoPath);

  final Directory directory = Directory(dir);
  if (!directory.existsSync()) return null;

  final List<String> dirFiles;
  try {
    dirFiles = directory
        .listSync(followLinks: false)
        .whereType<File>()
        .map((File f) => p.basename(f.path))
        .toList();
  } on FileSystemException {
    return null;
  }

  final String? picked = pickSidecar(baseNameNoExt, dirFiles);
  if (picked == null) return null;
  return p.normalize(p.join(dir, picked));
}
