import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show kLearningLanguageCode;
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_pick.dart';
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

/// 默认字幕扩展集（书籍导入用，含 lrc）。视频导入传入不含 lrc 的子集，与视频
/// 手选字幕白名单（srt/vtt/ass/ssa）保持一致——避免"自动挂载接受手选拒绝的格式"。
const Set<String> defaultSubtitleExts = kAudiobookSubtitleExtensions;

/// 同名字幕怎么认：有声书与视频是两条规则，按调用域显式选，不混用。
enum SidecarSubtitleRule {
  /// 有声书 / 书籍：有声书字幕唯一规则 [pickAudiobookSubtitle]（严格同主干，认
  /// `book.ja.srt` / `book.jpn.srt` 这类学习语言标记，别的语言的不挂）。
  audiobook,

  /// 视频：只认去扩展名后与主文件**完全同名**的（`Movie.Eng.mkv` 配
  /// `Movie.Eng.srt`），多份按格式优先级择一。视频字幕的语言判别另有一套
  /// （`media/video/subtitle/`），这里不把有声书的语言规则套到视频上。
  exactName,
}

/// 同前缀多段音频判定：stem 之后的余部以分隔符（空白/`.`/`_`/`-`）或数字开头，
/// 如 `book 01` / `book-02` / `book_03` / `book01`，借此收多段、排除 `bookkeeping`。
final RegExp _multipartSuffix = RegExp(r'^[\s._\-]|^\d');

/// sidecar 专用音频扩展集中要排除的"视频容器"扩展名。
///
/// [AudiobookStorage.audioExtensions] 含 `.mp4`（有声书允许纯音频 mp4），但自动挂载
/// 场景下，书目录里同名的 `book.mp4` 多半是视频版而非音轨——若当音频挂上去会把视频
/// 误当有声书。故 sidecar 自动识别**排除 `.mp4`**；用户仍可在导入对话框手动选 mp4 音频。
const Set<String> _sidecarAudioExcludeExts = <String>{'.mp4'};

/// sidecar 音频判定：复用 [AudiobookStorage.isAudioFile] 的音频扩展集，但剔除
/// [_sidecarAudioExcludeExts]（视频容器）。
bool _isSidecarAudio(String name) {
  if (_sidecarAudioExcludeExts.contains(p.extension(name).toLowerCase())) {
    return false;
  }
  return AudiobookStorage.isAudioFile(name);
}

/// 纯函数核心：从同目录的文件名列表中选出匹配的字幕/音频**文件名**（非路径）。
///
/// 无 IO、无 context，是 sidecar 自动挂载的可测核心。[siblingNames] 是同目录下
/// 所有文件的 basename。返回的 `subtitle` / `audio` 同为 basename，由 [findSidecars]
/// 拼回绝对路径。
///
/// 匹配规则见 `docs/superpowers/specs/2026-06-06-import-sidecar-auto-attach-design.md`：
/// - 字幕按 [subtitleRule]：
///   - [SidecarSubtitleRule.audiobook]（缺省，书籍导入）：与主文件同主干（`book.srt`，
///     或带语言标记的 `book.ja.srt` / `book.jpn.srt`），按有声书字幕唯一规则
///     [pickAudiobookSubtitle] 择一：学习语言 [kLearningLanguageCode] 标记的 > 无标记
///     的，别的语言的不挂；同名次按格式优先级（srt > vtt > ass > ssa > lrc）；
///   - [SidecarSubtitleRule.exactName]（视频）：去扩展名后完全等于主文件 stem，多命中
///     按同一格式优先级择一；
/// - 音频：完全同名，或同前缀多段（[_multipartSuffix]）。
({String? subtitle, List<String> audio}) selectSidecarNames({
  required String mainFileName,
  required List<String> siblingNames,
  bool wantAudio = true,
  Set<String> subtitleExts = defaultSubtitleExts,
  SidecarSubtitleRule subtitleRule = SidecarSubtitleRule.audiobook,
}) {
  final String stem = p.basenameWithoutExtension(mainFileName).toLowerCase();
  if (stem.isEmpty) return (subtitle: null, audio: const <String>[]);
  final String selfName = p.basename(mainFileName).toLowerCase();

  final List<String> subtitles = <String>[];
  final List<String> audio = <String>[];

  for (final String name in siblingNames) {
    if (name.toLowerCase() == selfName) continue; // 跳过主文件自身
    final String ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    final String base = p.basenameWithoutExtension(name).toLowerCase();

    if (subtitleExts.contains(ext)) {
      subtitles.add(name);
      continue;
    }

    // 音频：完全同名 或 同前缀多段。
    if (wantAudio && _isSidecarAudio(name)) {
      if (base == stem) {
        audio.add(name);
      } else if (base.startsWith(stem) &&
          _multipartSuffix.hasMatch(base.substring(stem.length))) {
        audio.add(name);
      }
    }
  }

  audio.sort(compareAudioFilePath);
  return (
    subtitle: switch (subtitleRule) {
      SidecarSubtitleRule.audiobook => _pickAudiobookSidecar(
        mainFileName,
        subtitles,
      ),
      SidecarSubtitleRule.exactName => _pickExactNameSidecar(stem, subtitles),
    },
    audio: audio,
  );
}

String? _pickAudiobookSidecar(String mainFileName, List<String> subtitles) {
  final AudiobookSubtitlePick? pick = pickAudiobookSubtitle(
    audioNames: <String>[mainFileName],
    subtitleNames: subtitles,
    langCode: kLearningLanguageCode,
    strictPerAudio: true,
  );
  return pick == null ? null : subtitles[pick.index];
}

/// 视频的同名字幕：去扩展名后与 [stem] 完全相同，多命中按
/// [kAudiobookSubtitleExtensions] 的格式优先级择一（不认语言标记）。
String? _pickExactNameSidecar(String stem, List<String> subtitles) {
  final List<String> priority = kAudiobookSubtitleExtensions.toList();
  String? best;
  int bestRank = 1 << 30;
  for (final String name in subtitles) {
    if (p.basenameWithoutExtension(name).toLowerCase() != stem) continue;
    final int rank = priority.indexOf(
      p.extension(name).toLowerCase().replaceFirst('.', ''),
    );
    if (rank >= 0 && rank < bestRank) {
      bestRank = rank;
      best = name;
    }
  }
  return best;
}

/// 薄 IO 包装：列出 [mainFilePath] 所在目录 → [selectSidecarNames] → 拼回绝对路径。
///
/// 目录读不到（移动端缓存副本 / 权限不足）或任何 IO 异常时返回空 [SidecarMatch]，
/// **绝不抛**——自动挂载是锦上添花，失败应静默降级为"用户手动选"。
Future<SidecarMatch> findSidecars(
  String mainFilePath, {
  bool wantAudio = true,
  Set<String> subtitleExts = defaultSubtitleExts,
  SidecarSubtitleRule subtitleRule = SidecarSubtitleRule.audiobook,
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
      subtitleExts: subtitleExts,
      subtitleRule: subtitleRule,
    );

    return SidecarMatch(
      subtitlePath: sel.subtitle == null
          ? null
          : p.join(dir.path, sel.subtitle!),
      audioPaths: sel.audio.map((String n) => p.join(dir.path, n)).toList(),
    );
  } catch (_) {
    return const SidecarMatch();
  }
}
