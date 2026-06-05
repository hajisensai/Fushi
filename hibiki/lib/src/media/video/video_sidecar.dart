import 'dart:io';

import 'package:path/path.dart' as p;

/// sidecar 字幕的「无语言标记」基础扩展名优先级（查词主语言用的是带语言标记版）。
///
/// `.srt` > `.ass` > `.ssa` > `.vtt`。
const List<String> _baseSubtitleExtensions = <String>[
  '.srt',
  '.ass',
  '.ssa',
  '.vtt',
];

/// 按 app 目标学习语言为 [langCode] 构造 sidecar 字幕优先级后缀列表。
///
/// 规则：先找带语言标记 `.<langCode>.<ext>`（如学日语 → `.ja.srt`、`.ja.ass`…），
/// 再回退无语言标记 `.<ext>`（如 `.srt`、`.ass`…）。每组内格式优先级见
/// [_baseSubtitleExtensions]。
///
/// 例（langCode='ja'）：
/// `.ja.srt > .ja.ass > .ja.ssa > .ja.vtt > .srt > .ass > .ssa > .vtt`。
List<String> _sidecarSuffixPriority(String langCode) {
  final String lang = langCode.toLowerCase();
  final List<String> suffixes = <String>[];
  for (final String ext in _baseSubtitleExtensions) {
    suffixes.add('.$lang$ext');
  }
  suffixes.addAll(_baseSubtitleExtensions);
  return suffixes;
}

/// 纯函数：给「去掉视频扩展名的 basename」与「同目录文件名列表」，按 app 学习语言
/// [langCode] 的优先级挑出第一个匹配的 sidecar 字幕文件名；无则返回 null。
///
/// 优先级（以 langCode='ja' 为例）：
/// `.ja.srt > .ja.ass > .ja.ssa > .ja.vtt > .srt > .ass > .ssa > .vtt`，即先找
/// 带学习语言标记的同前缀字幕，再回退无语言标记的字幕。
///
/// 匹配规则：候选文件名（不区分大小写比较）等于 `<videoBaseNameNoExt><suffix>`，
/// 其中 suffix 取自 [_sidecarSuffixPriority]。返回的是 [dirFiles] 中的原始文件名
/// （保留原始大小写），便于调用方直接拼回目录得到绝对路径。
///
/// 抽成纯函数是为可测：不碰文件系统，只做字符串优先级匹配。
String? pickSidecar(
  String videoBaseNameNoExt,
  List<String> dirFiles, {
  required String langCode,
}) {
  final String baseLower = videoBaseNameNoExt.toLowerCase();
  for (final String suffix in _sidecarSuffixPriority(langCode)) {
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
/// [langCode] 是 app 目标学习语言代码（如 `'ja'`/`'ko'`），优先选带该语言标记的
/// 字幕。返回第一个存在的字幕绝对路径（优先级见 [pickSidecar]），无则 null。
/// 目录不存在 / 读取失败时静默返回 null。
String? findSidecarSubtitle(String videoPath, {required String langCode}) {
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

  final String? picked =
      pickSidecar(baseNameNoExt, dirFiles, langCode: langCode);
  if (picked == null) return null;
  return p.normalize(p.join(dir, picked));
}
