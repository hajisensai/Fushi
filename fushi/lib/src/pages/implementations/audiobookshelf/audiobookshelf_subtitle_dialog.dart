/// 「给这本书挂字幕」的选择：服务器条目里的字幕文件（推荐的排第一），或本机文件。
///
/// 只拼现成的组件：[showFushiChoiceDialog] 选来源，选「本机」再走系统文件选择器。
/// 返回 null = 用户取消（或选了不支持的格式，已提示）。
library;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_stream_service.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:path/path.dart' as p;

/// 能解析成 cue 的字幕格式（与导入对话框一致）。
const Set<String> kAudiobookshelfSubtitleExtensions = <String>{
  'srt',
  'lrc',
  'vtt',
  'ass',
  'ssa',
};

/// 「从本机选」的哨兵值（选项值类型是 [Object]，服务器文件用 [ServerSubtitleChoice]）。
const Object _kPickFromDevice = Object();

/// 选项的排列：推荐的服务器字幕在最前，其余服务器字幕按原序，最后是「从本机选」。
@visibleForTesting
List<AudiobookshelfLibraryFile> orderedServerSubtitles(
  AudiobookshelfItemDetail detail, {
  AudiobookshelfEpisode? episode,
}) {
  final AudiobookshelfLibraryFile? suggested = suggestServerSubtitle(
    detail,
    episode: episode,
  );
  return <AudiobookshelfLibraryFile>[
    if (suggested != null) suggested,
    for (final AudiobookshelfLibraryFile file in detail.subtitleFiles)
      if (file.ino != suggested?.ino) file,
  ];
}

Future<AudiobookshelfSubtitleChoice?> chooseAudiobookshelfSubtitle({
  required BuildContext context,
  required AudiobookshelfItemDetail detail,
  AudiobookshelfEpisode? episode,
}) async {
  final List<AudiobookshelfLibraryFile> serverFiles = orderedServerSubtitles(
    detail,
    episode: episode,
  );
  final List<FushiChoiceOption<Object>> options = <FushiChoiceOption<Object>>[
    for (final AudiobookshelfLibraryFile file in serverFiles)
      FushiChoiceOption<Object>(
        value: ServerSubtitleChoice(file),
        label: file.filename,
        subtitle: t.audiobookshelf_subtitle_on_server,
        icon: FushiIcons.subtitles,
      ),
    FushiChoiceOption<Object>(
      value: _kPickFromDevice,
      label: t.audiobookshelf_subtitle_from_device,
      icon: FushiIcons.folderOpen,
    ),
  ];
  final Object? picked = await showFushiChoiceDialog<Object>(
    context: context,
    title: t.audiobookshelf_subtitle_title,
    message: serverFiles.isEmpty
        ? '${t.audiobookshelf_subtitle_message}\n'
              '${t.audiobookshelf_subtitle_none_on_server}'
        : t.audiobookshelf_subtitle_message,
    icon: FushiIcons.subtitles,
    options: options,
  );
  if (picked == null) return null;
  if (picked is ServerSubtitleChoice) return picked;
  if (!context.mounted) return null;

  final String? path = await pickSystemFilePath(
    context: context,
    allowedExtensions: kAudiobookshelfSubtitleExtensions,
  );
  if (path == null) return null;
  final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
  if (!kAudiobookshelfSubtitleExtensions.contains(ext)) {
    FushiToast.show(
      msg: t.import_unsupported_file_format(ext: '.$ext'),
      severity: ToastSeverity.error,
    );
    return null;
  }
  return LocalSubtitleChoice(path);
}
