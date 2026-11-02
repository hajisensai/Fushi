/// 服务器条目里该挂哪份字幕：流式建书时自动挂上、下载单集时随附、选择对话框的
/// 排序共用。规则本体是文件名级的 [pickAudiobookSubtitle]（下载包分类与本机导入
/// 同一条），这里只把 Audiobookshelf 的 DTO 摊成文件名。
library;

import 'package:fushi_engine/media/audiobook/audiobook_subtitle_pick.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

/// 在 [detail] 的服务器字幕文件里挑出该自动挂上的那份；挑不准返回 null（交给用户选）。
///
/// - 播客单集（[episode] 非空）：只认文件名主干与这一集音频完全相同的。
/// - 书：主干与某个音轨同名 → 其次与条目标题同名 → 其次全部字幕（须同一个主干）。
///
/// 同一主干里：学习语言 [langCode]（含 `jpn` / `jp` 等别名）> 无标记；别的语言不自动
/// 挂；再按格式优先级。详见 [pickAudiobookSubtitle]。
AudiobookshelfLibraryFile? matchAudiobookshelfSubtitle(
  AudiobookshelfItemDetail detail, {
  AudiobookshelfEpisode? episode,
  required String langCode,
}) {
  final List<AudiobookshelfLibraryFile> candidates = detail.subtitleFiles;
  if (candidates.isEmpty) return null;
  final List<String> audioNames;
  if (episode != null) {
    final String? audio = episode.track.filename;
    if (audio == null) return null;
    audioNames = <String>[audio];
  } else {
    audioNames = <String>[
      for (final AudiobookshelfTrack track in detail.tracks)
        if (track.filename case final String name) name,
    ];
  }
  final int? index = pickAudiobookSubtitle(
    audioNames: audioNames,
    subtitleNames: <String>[
      for (final AudiobookshelfLibraryFile file in candidates) file.filename,
    ],
    title: episode == null ? detail.item.title : null,
    langCode: langCode,
    strictPerAudio: episode != null,
  );
  return index == null ? null : candidates[index];
}
