import 'dart:io';

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as p;

/// 导入时在主文件同目录扫描到的同名 sidecar：字幕 + 音频（绝对路径）。
class SidecarMatch {
  const SidecarMatch({this.subtitlePath, this.audioPaths = const <String>[]});

  /// 同名字幕的绝对路径；未命中为 null。
  final String? subtitlePath;

  /// 同名（含同前缀多段）音频的绝对路径，已自然排序；未命中为空。
  final List<String> audioPaths;

  bool get isEmpty => subtitlePath == null && audioPaths.isEmpty;
}

/// 字幕扩展名优先级（靠前者优先），用于同目录有多个同名字幕时择一。
const List<String> _subtitleExtPriority = <String>[
  'srt',
  'vtt',
  'ass',
  'ssa',
  'lrc'
];

const Set<String> _subtitleExtSet = <String>{'srt', 'vtt', 'ass', 'ssa', 'lrc'};

/// 同前缀多段音频判定：stem 之后的余部以分隔符（空白/`.`/`_`/`-`）或数字开头，
/// 如 `book 01` / `book-02` / `book_03` / `book01`，借此收多段、排除 `bookkeeping`。
final RegExp _multipartSuffix = RegExp(r'^[\s._\-]|^\d');

/// 纯函数核心：从同目录的文件名列表中选出匹配的字幕/音频**文件名**（非路径）。
///
/// 无 IO、无 context，是 sidecar 自动挂载的可测核心。[siblingNames] 是同目录下
/// 所有文件的 basename。返回的 `subtitle` / `audio` 同为 basename，由 [findSidecars]
/// 拼回绝对路径。
///
/// 匹配规则见 `docs/superpowers/specs/2026-06-06-import-sidecar-auto-attach-design.md`：
/// - 字幕：去扩展名后完全等于主文件 stem，多命中按 [_subtitleExtPriority] 择一；
/// - 音频：完全同名，或同前缀多段（[_multipartSuffix]）。
({String? subtitle, List<String> audio}) selectSidecarNames({
  required String mainFileName,
  required List<String> siblingNames,
  bool wantAudio = true,
}) {
  final String stem = p.basenameWithoutExtension(mainFileName).toLowerCase();
  if (stem.isEmpty) return (subtitle: null, audio: const <String>[]);
  final String selfName = p.basename(mainFileName).toLowerCase();

  String? bestSubtitle;
  int bestSubtitleRank = 1 << 30;
  final List<String> audio = <String>[];

  for (final String name in siblingNames) {
    if (name.toLowerCase() == selfName) continue; // 跳过主文件自身
    final String ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    final String base = p.basenameWithoutExtension(name).toLowerCase();

    // 字幕：要求完全同名。
    if (_subtitleExtSet.contains(ext)) {
      if (base == stem) {
        final int rank = _subtitleExtPriority.indexOf(ext);
        if (rank >= 0 && rank < bestSubtitleRank) {
          bestSubtitleRank = rank;
          bestSubtitle = name;
        }
      }
      continue;
    }

    // 音频：完全同名 或 同前缀多段。
    if (wantAudio && AudiobookStorage.isAudioFile(name)) {
      if (base == stem) {
        audio.add(name);
      } else if (base.startsWith(stem) &&
          _multipartSuffix.hasMatch(base.substring(stem.length))) {
        audio.add(name);
      }
    }
  }

  audio.sort(compareAudioFilePath);
  return (subtitle: bestSubtitle, audio: audio);
}

/// 薄 IO 包装：列出 [mainFilePath] 所在目录 → [selectSidecarNames] → 拼回绝对路径。
///
/// 目录读不到（移动端缓存副本 / 权限不足）或任何 IO 异常时返回空 [SidecarMatch]，
/// **绝不抛**——自动挂载是锦上添花，失败应静默降级为"用户手动选"。
Future<SidecarMatch> findSidecars(
  String mainFilePath, {
  bool wantAudio = true,
}) async {
  try {
    final Directory dir = File(mainFilePath).parent;
    if (!await dir.exists()) return const SidecarMatch();

    final List<String> names = <String>[];
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is File) names.add(p.basename(e.path));
    }

    final ({String? subtitle, List<String> audio}) sel = selectSidecarNames(
      mainFileName: p.basename(mainFilePath),
      siblingNames: names,
      wantAudio: wantAudio,
    );

    return SidecarMatch(
      subtitlePath:
          sel.subtitle == null ? null : p.join(dir.path, sel.subtitle!),
      audioPaths: sel.audio.map((String n) => p.join(dir.path, n)).toList(),
    );
  } catch (_) {
    return const SidecarMatch();
  }
}
